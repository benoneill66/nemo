import Foundation
import AVFoundation
import Speech

/// Continuous transcription built on macOS 26's `SpeechAnalyzer` + `SpeechTranscriber` — the
/// same on-device models that power the system's enhanced dictation. Unlike the older
/// `SFSpeechRecognizer`, it's designed for unbounded long-form audio (no rolling-window
/// restarts), adds punctuation, and is markedly more accurate.
@available(macOS 26.0, *)
@MainActor
final class DictationEngine: NSObject, SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onSegment: ((_ text: String, _ start: Date, _ end: Date, _ voice: VoiceFingerprint?) -> Void)?
    var onStatus: ((SpeechEngineStatus) -> Void)?
    let displayName = "Enhanced dictation"

    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    // Voice fingerprinting for speaker diarization (nil when disabled in config).
    private let profiler: VoiceProfiler? = Config.diarizationEnabled ? VoiceProfiler() : nil
    private let voiceAnalyzer: VoiceAnalyzer? = Config.diarizationEnabled ? VoiceAnalyzer() : nil

    private let audioEngine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var tapInstalled = false
    private var running = false

    // Finalized text is accumulated and flushed into a segment on a brief pause so
    // segments track natural sentences rather than every micro-finalization.
    private var streamStart = Date()
    private var pendingText = ""
    private var pendingStart: Date?
    private var pendingEnd = Date()
    private var flushTimer: Timer?
    private let flushPause: TimeInterval = 1.6

    private var status: SpeechEngineStatus = .stopped {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    // MARK: - Control

    func start() {
        guard !running else { return }
        requestAuthorization { [weak self] granted, message in
            guard let self else { return }
            if granted { self.running = true; self.launch() }
            else { self.status = .needsAuth(message) }
        }
    }

    func stop() {
        running = false
        flushTimer?.invalidate(); flushTimer = nil
        flushPending()
        teardownAudio()
        let cont = inputContinuation
        let an = analyzer
        inputContinuation = nil
        resultsTask?.cancel(); resultsTask = nil
        analyzer = nil; transcriber = nil
        cont?.finish()
        Task { try? await an?.finalizeAndFinishThroughEndOfInput() }
        status = .stopped
    }

    // MARK: - Setup

    private func launch() {
        let locale = Config.locale ?? Locale.current
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureModel(for: transcriber, locale: locale)
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()

                await MainActor.run {
                    self.analyzerFormat = format
                    self.analyzer = analyzer
                    self.inputContinuation = cont
                    self.consumeResults(from: transcriber)
                }
                try await analyzer.start(inputSequence: stream)
                await MainActor.run { self.startAudio() }
            } catch {
                await MainActor.run {
                    self.status = .unavailable("Dictation setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Ensures the on-device model for `locale` is installed, downloading it once if needed.
    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let id = locale.identifier(.bcp47)
        let have = installed.contains { $0.identifier(.bcp47) == id }
        if !have {
            await MainActor.run { self.status = .unavailable("Downloading speech model…") }
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        }
    }

    private func startAudio() {
        guard running, let analyzerFormat, let continuation = inputContinuation else { return }
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            status = .unavailable("Couldn't bridge the mic to the dictation format.")
            return
        }
        let outFormat = analyzerFormat
        let profiler = self.profiler

        // The tap fires on a realtime audio thread, so it captures everything it needs as
        // plain locals — it must never touch main-actor state (doing so traps the process).
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            profiler?.append(buffer)
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, st in
                if consumed { st.pointee = .noDataNow; return nil }
                consumed = true
                st.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
        tapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
            streamStart = Date()
            status = .listening
        } catch {
            status = .unavailable("Microphone error: \(error.localizedDescription)")
        }
    }

    // MARK: - Results

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal { self.appendFinal(text, result.range) }
                        else { self.onPartial?(self.previewText(volatile: text)) }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.running else { return }
                    self.status = .unavailable("Dictation stream ended: \(error.localizedDescription)")
                }
            }
        }
    }

    private func previewText(volatile: String) -> String {
        let v = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return [p, v].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func appendFinal(_ text: String, _ range: CMTimeRange) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if pendingStart == nil {
            pendingStart = streamStart.addingTimeInterval(range.start.seconds.isFinite ? range.start.seconds : 0)
        }
        pendingText = pendingText.isEmpty ? piece : pendingText + " " + piece
        pendingEnd = streamStart.addingTimeInterval(range.end.seconds.isFinite ? range.end.seconds : 0)
        onPartial?(pendingText)

        // Flush on a pause, or immediately when a long, sentence-ended chunk has built up.
        flushTimer?.invalidate()
        if pendingText.count > 220, ".!?".contains(pendingText.last ?? " ") {
            flushPending()
        } else {
            flushTimer = Timer.scheduledTimer(withTimeInterval: flushPause, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.flushPending() }
            }
        }
    }

    private func flushPending() {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = pendingStart ?? Date()
        pendingText = ""; pendingStart = nil
        onPartial?("")
        guard !text.isEmpty else { profiler?.reset(); return }
        let voice = fingerprintForCommit()
        onSegment?(text, start, pendingEnd, voice)
    }

    /// Distill the audio accumulated since the last flush into a voice fingerprint (and clear it).
    private func fingerprintForCommit() -> VoiceFingerprint? {
        guard let profiler, let voiceAnalyzer else { return nil }
        let (samples, rate) = profiler.drain()
        return voiceAnalyzer.fingerprint(samples: samples, rate: rate)
    }

    // MARK: - Authorization

    private func requestAuthorization(_ completion: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = speechStatus == .authorized
            func finish(_ micOK: Bool) {
                DispatchQueue.main.async {
                    if speechOK && micOK { completion(true, "") }
                    else { completion(false, "Grant Microphone + Speech Recognition access in System Settings, then start again.") }
                }
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    finish(true)
            case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { finish($0) }
            default:             finish(false)
            }
        }
    }

    // MARK: - Teardown

    private func teardownAudio() {
        profiler?.reset()
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
