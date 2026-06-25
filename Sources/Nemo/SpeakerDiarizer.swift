import Foundation
import Accelerate
import AVFoundation

/// A compact, on-device acoustic signature of a voice. Built from the audio behind a single
/// transcript segment (a mean MFCC vector capturing vocal-tract timbre plus a pitch term),
/// it's the raw material the diarizer clusters into distinct speakers. Nothing here leaves
/// the Mac — it's derived from the same mic audio the recognizer already hears.
struct VoiceFingerprint: Codable, Sendable, Hashable {
    /// Standardizable feature vector: 12 MFCC means (c1…c12) + 1 pitch term.
    var features: [Float]
    /// How much *voiced* audio backed this fingerprint — short snippets are less trustworthy.
    var voicedSeconds: Double
}

// MARK: - Audio accumulation (realtime-thread safe)

/// Buffers mono microphone samples on the realtime audio thread so that, when a segment is
/// committed on the main actor, the audio behind it can be distilled into a `VoiceFingerprint`.
/// The audio tap appends; the main actor drains. A lock keeps the two threads honest, and a
/// rolling cap bounds memory if a segment runs long.
final class VoiceProfiler: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var nativeRate: Double = 48_000
    private let maxSeconds = 70.0

    /// Append a buffer's audio, down-mixed to mono. Safe to call from the realtime tap thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let chans = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate

        var mono = [Float](repeating: 0, count: frames)
        if channelCount <= 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: chans[0], count: frames)
            }
        } else {
            // Average channels into mono.
            for c in 0..<channelCount {
                vDSP_vadd(mono, 1, chans[c], 1, &mono, 1, vDSP_Length(frames))
            }
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
        }

        lock.lock()
        nativeRate = rate
        samples.append(contentsOf: mono)
        let cap = Int(maxSeconds * rate)
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
        lock.unlock()
    }

    /// Take everything buffered so far and clear it, ready for the next segment.
    func drain() -> (samples: [Float], rate: Double) {
        lock.lock()
        let s = samples, r = nativeRate
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return (s, r)
    }

    func reset() {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
    }
}

// MARK: - Feature extraction (MFCC + pitch)

/// Turns a window of raw audio into a `VoiceFingerprint`. Computes mel-frequency cepstral
/// coefficients (the standard speaker/timbre features) frame-by-frame over voiced audio, plus a
/// median pitch term, and averages them. Audio is first resampled to a fixed 16 kHz so the
/// feature space is identical regardless of the input device's sample rate.
final class VoiceAnalyzer {
    private let targetRate: Double = 16_000
    private let frameLength = 400          // 25 ms @ 16 kHz
    private let hop = 160                  // 10 ms @ 16 kHz
    private let fftSize = 512
    private let log2n: vDSP_Length = 9     // 2^9 = 512
    private let melCount = 26
    private let mfccCount = 12             // keep c1…c12 (drop c0 / energy)
    private let bins = 257                 // fftSize/2 + 1

    private let fftSetup: FFTSetup
    private let window: [Float]            // Hamming
    private let melBank: [[Float]]         // melCount × bins triangular filters
    private let dct: [[Float]]             // mfccCount × melCount DCT-II basis

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Hamming window over a frame.
        var w = [Float](repeating: 0, count: frameLength)
        vDSP_hamm_window(&w, vDSP_Length(frameLength), 0)
        window = w

        // Triangular mel filterbank across [0, targetRate/2].
        melBank = Self.makeMelBank(melCount: melCount, bins: bins,
                                   fftSize: fftSize, rate: targetRate)

        // DCT-II basis mapping melCount log-energies → mfccCount cepstral coefficients.
        var basis = [[Float]]()
        for k in 1...mfccCount {
            var row = [Float](repeating: 0, count: melCount)
            for n in 0..<melCount {
                row[n] = cosf(Float.pi * Float(k) * (Float(n) + 0.5) / Float(melCount))
            }
            basis.append(row)
        }
        dct = basis
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Distill a window of audio into a fingerprint, or nil if there isn't enough voiced
    /// speech to characterize a speaker reliably.
    func fingerprint(samples raw: [Float], rate: Double) -> VoiceFingerprint? {
        guard raw.count > Int(rate * 0.3) else { return nil }
        let signal = resample(raw, from: rate, to: targetRate)
        guard signal.count >= frameLength else { return nil }

        // Per-frame energy, so we can keep only voiced frames.
        var frames: [[Float]] = []
        var energies: [Float] = []
        var i = 0
        while i + frameLength <= signal.count {
            let frame = Array(signal[i..<i + frameLength])
            var e: Float = 0
            vDSP_measqv(frame, 1, &e, vDSP_Length(frameLength))   // mean square
            frames.append(frame)
            energies.append(e)
            i += hop
        }
        guard !frames.isEmpty else { return nil }

        // Voiced = frames above a fraction of the peak energy (drops silence / room tone).
        let peak = energies.max() ?? 0
        guard peak > 1e-7 else { return nil }
        let floor = peak * 0.04

        var mfccSum = [Float](repeating: 0, count: mfccCount)
        var pitches: [Float] = []
        var voiced = 0
        for (idx, frame) in frames.enumerated() where energies[idx] >= floor {
            let coeffs = mfcc(frame)
            vDSP_vadd(mfccSum, 1, coeffs, 1, &mfccSum, 1, vDSP_Length(mfccCount))
            if let f0 = pitch(frame) { pitches.append(f0) }
            voiced += 1
        }
        guard voiced >= 15 else { return nil }   // < ~150 ms voiced — too little to trust

        var inv = 1 / Float(voiced)
        vDSP_vsmul(mfccSum, 1, &inv, &mfccSum, 1, vDSP_Length(mfccCount))

        // Pitch term: log of the median voiced F0 (0 when unvoiced/whispered).
        let pitchTerm: Float
        if pitches.count >= 5 {
            let sorted = pitches.sorted()
            pitchTerm = log2f(sorted[sorted.count / 2])
        } else {
            pitchTerm = 0
        }

        let features = mfccSum + [pitchTerm]
        return VoiceFingerprint(features: features, voicedSeconds: Double(voiced) * 0.01)
    }

    // MARK: MFCC for one frame

    private func mfcc(_ frame: [Float]) -> [Float] {
        // Window into a zero-padded (to fftSize) real buffer.
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(frameLength))

        let half = fftSize / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: bins)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cmplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cmplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // |X|^2 for bins 0…half-1. (zrip packs Nyquist into imagp[0]; the slight
                // approximation at the band edges is immaterial to filterbank energies.)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        power[bins - 1] = power[bins - 2]

        // Mel filterbank → log energies.
        var logMel = [Float](repeating: 0, count: melCount)
        for m in 0..<melCount {
            var e: Float = 0
            vDSP_dotpr(power, 1, melBank[m], 1, &e, vDSP_Length(bins))
            logMel[m] = logf(max(e, 1e-10))
        }

        // DCT-II → cepstral coefficients c1…c12.
        var out = [Float](repeating: 0, count: mfccCount)
        for k in 0..<mfccCount {
            var c: Float = 0
            vDSP_dotpr(logMel, 1, dct[k], 1, &c, vDSP_Length(melCount))
            out[k] = c
        }
        return out
    }

    // MARK: Pitch via autocorrelation

    /// Estimate fundamental frequency (Hz) in the 80–350 Hz range, or nil if the frame looks
    /// unvoiced (no clear periodicity).
    private func pitch(_ frame: [Float]) -> Float? {
        let minLag = Int(targetRate / 350)   // ~45
        let maxLag = Int(targetRate / 80)    // 200
        guard frame.count > maxLag else { return nil }

        var r0: Float = 0
        vDSP_dotpr(frame, 1, frame, 1, &r0, vDSP_Length(frame.count))
        guard r0 > 1e-6 else { return nil }

        var bestLag = 0
        var bestVal: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            vDSP_dotpr(frame, 1, Array(frame[lag...]), 1, &sum, vDSP_Length(frame.count - lag))
            if sum > bestVal { bestVal = sum; bestLag = lag }
        }
        // Require a reasonably strong peak relative to zero-lag energy → voiced.
        guard bestLag > 0, bestVal / r0 > 0.3 else { return nil }
        return Float(targetRate) / Float(bestLag)
    }

    // MARK: Helpers

    private func resample(_ x: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        if abs(inRate - outRate) < 1 { return x }
        let ratio = outRate / inRate
        let outCount = Int(Double(x.count) * ratio)
        guard outCount > 1 else { return x }
        var out = [Float](repeating: 0, count: outCount)
        for n in 0..<outCount {
            let src = Double(n) / ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, x.count - 1)
            let frac = Float(src - Double(i0))
            out[n] = x[i0] * (1 - frac) + x[i1] * frac
        }
        return out
    }

    private static func makeMelBank(melCount: Int, bins: Int, fftSize: Int, rate: Double) -> [[Float]] {
        func hzToMel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func melToHz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }

        let lowMel = hzToMel(0), highMel = hzToMel(rate / 2)
        let points = (0...melCount + 1).map { i -> Double in
            melToHz(lowMel + (highMel - lowMel) * Double(i) / Double(melCount + 1))
        }
        // Map each mel point to an FFT bin index.
        let binIdx = points.map { Int(floor(Double(fftSize + 1) * $0 / rate)) }

        var bank = [[Float]](repeating: [Float](repeating: 0, count: bins), count: melCount)
        for m in 1...melCount {
            let left = binIdx[m - 1], center = binIdx[m], right = binIdx[m + 1]
            if center > left {
                for k in left..<center where k >= 0 && k < bins {
                    bank[m - 1][k] = Float(k - left) / Float(center - left)
                }
            }
            if right > center {
                for k in center..<right where k >= 0 && k < bins {
                    bank[m - 1][k] = Float(right - k) / Float(right - center)
                }
            }
        }
        return bank
    }
}

// MARK: - Online speaker clustering

/// Groups voice fingerprints into distinct speakers as they arrive, with no model training and
/// no prior knowledge of how many people are talking. Each speaker is a running centroid in the
/// fingerprint feature space; a new fingerprint joins the nearest speaker if it's close enough,
/// otherwise it founds a new one. Distances are computed in a standardized space (running
/// per-dimension variance) so heterogeneous features — cepstral coefficients and a pitch term —
/// contribute on comparable footing.
final class SpeakerDiarizer {
    struct Profile {
        var id: Int
        var centroid: [Float]
        var count: Int
    }

    private(set) var profiles: [Profile] = []
    private var nextId = 0

    // Welford running mean / M2 for per-dimension standardization.
    private var mean: [Float] = []
    private var m2: [Float] = []
    private var n = 0

    /// How far (standardized, per-dimension RMS) a fingerprint may sit from a speaker's centroid
    /// and still be considered the same person. Higher = more lenient (fewer speakers).
    var threshold: Float

    /// Pitch is a strong speaker cue; weight its standardized contribution up a little.
    private let pitchWeight: Float = 1.6

    init(threshold: Float = 1.5) {
        self.threshold = threshold
    }

    /// Restore previously learned speakers so identities (and their names) persist across launches
    /// and a returning voice re-matches its existing speaker.
    func seed(_ saved: [(id: Int, centroid: [Float], count: Int)]) {
        profiles = saved.compactMap { s in
            s.centroid.isEmpty ? nil : Profile(id: s.id, centroid: s.centroid, count: max(1, s.count))
        }
        nextId = (profiles.map(\.id).max() ?? -1) + 1
        // Seed running stats from the saved centroids so standardization isn't cold on launch.
        for p in profiles { observe(p.centroid) }
    }

    /// Assign a fingerprint to a speaker, updating that speaker's centroid. Returns the speaker id.
    func assign(_ fp: VoiceFingerprint) -> Int {
        observe(fp.features)

        var bestId = -1
        var bestDist = Float.greatestFiniteMagnitude
        for p in profiles {
            let d = distance(fp.features, p.centroid)
            if d < bestDist { bestDist = d; bestId = p.id }
        }

        if bestId >= 0, bestDist <= threshold, let idx = profiles.firstIndex(where: { $0.id == bestId }) {
            // Fold into the existing speaker (running mean of the centroid).
            let c = Float(profiles[idx].count)
            let w = 1 / (c + 1)
            for k in 0..<profiles[idx].centroid.count {
                profiles[idx].centroid[k] = (profiles[idx].centroid[k] * c + fp.features[k]) * w
            }
            profiles[idx].count += 1
            return bestId
        }

        let id = nextId; nextId += 1
        profiles.append(Profile(id: id, centroid: fp.features, count: 1))
        return id
    }

    // MARK: Standardized distance

    private func observe(_ x: [Float]) {
        if mean.isEmpty { mean = [Float](repeating: 0, count: x.count); m2 = mean }
        guard x.count == mean.count else { return }
        n += 1
        for k in 0..<x.count {
            let delta = x[k] - mean[k]
            mean[k] += delta / Float(n)
            m2[k] += delta * (x[k] - mean[k])
        }
    }

    private func std(_ k: Int) -> Float {
        guard n > 1 else { return 1 }
        return max(sqrtf(m2[k] / Float(n - 1)), 1e-3)
    }

    /// Per-dimension standardized RMS distance — comparable across feature types and roughly
    /// scale-free, so one threshold works regardless of how many dimensions there are.
    private func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        let pitchIdx = a.count - 1
        for k in 0..<a.count {
            let z = (a[k] - b[k]) / std(k)
            let w = (k == pitchIdx) ? pitchWeight : 1
            sum += (z * w) * (z * w)
        }
        return sqrtf(sum / Float(a.count))
    }
}
