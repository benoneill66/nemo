import Foundation
import AVFoundation
import Speech

/// Continuously transcribes microphone audio on-device, emitting time-stamped segments.
///
/// SFSpeechRecognizer caps a single recognition task at roughly a minute, so the engine
/// runs in rolling windows: it keeps one task alive, commits a segment whenever the
/// recognizer finalizes (or a pause/length threshold is hit), and immediately starts a
/// fresh task — so to the caller it looks like one never-ending transcription.
@MainActor
final class TranscriptionEngine: NSObject, SpeechEngine {
    /// Live, not-yet-committed text for the current window (drives the UI's "hearing now").
    var onPartial: ((String) -> Void)?
    /// A finalized chunk of speech with timing and (optionally) a voice fingerprint.
    var onSegment: ((_ text: String, _ start: Date, _ end: Date, _ voice: VoiceFingerprint?) -> Void)?
    var onStatus: ((SpeechEngineStatus) -> Void)?
    let displayName = "Standard recognition"

    // Voice fingerprinting for speaker diarization (nil when disabled in config).
    private let profiler: VoiceProfiler? = Config.diarizationEnabled ? VoiceProfiler() : nil
    private let analyzer: VoiceAnalyzer? = Config.diarizationEnabled ? VoiceAnalyzer() : nil

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private var running = false
    private var windowStart = Date()
    private var lastCommitted = ""        // last text emitted for the current window
    private var rollTimer: Timer?
    private var pauseTimer: Timer?

    /// Hard cap on a single recognition window before we roll to a fresh task.
    private let windowSeconds: TimeInterval = 50
    /// Silence after which we commit the current sentence and roll early.
    private let pauseSeconds: TimeInterval = 2.0

    private(set) var status: SpeechEngineStatus = .stopped {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    // MARK: - Control

    func start() {
        guard !running else { return }
        requestAuthorization { [weak self] granted, message in
            guard let self else { return }
            if granted {
                self.running = true
                self.beginWindow()
            } else {
                self.status = .needsAuth(message)
            }
        }
    }

    func stop() {
        running = false
        teardown()
        status = .stopped
    }

    // MARK: - Authorization

    private func requestAuthorization(_ completion: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = speechStatus == .authorized
            func finish(_ micOK: Bool) {
                DispatchQueue.main.async {
                    if speechOK && micOK { completion(true, "") }
                    else {
                        completion(false, "Grant Microphone + Speech Recognition access in System Settings, then start again.")
                    }
                }
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    finish(true)
            case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { finish($0) }
            default:             finish(false)
            }
        }
    }

    // MARK: - Rolling recognition windows

    private func beginWindow() {
        guard running else { return }
        teardownTask()

        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable("Speech recognizer unavailable. Retrying…")
            scheduleRetry()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // privacy: nothing leaves the Mac
        }
        self.request = request

        if !audioEngine.isRunning {
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let profiler = self.profiler
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
                profiler?.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            do { try audioEngine.start() }
            catch {
                status = .unavailable("Microphone error: \(error.localizedDescription)")
                scheduleRetry()
                return
            }
        }

        windowStart = Date()
        lastCommitted = ""
        status = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                if let transcript, !transcript.isEmpty {
                    self.lastCommitted = transcript
                    self.onPartial?(transcript)
                    self.armPauseTimer()
                }
                if isFinal || error != nil { self.rollWindow() }
            }
        }

        // Roll the window before the recognizer hits its internal ceiling.
        rollTimer?.invalidate()
        rollTimer = Timer.scheduledTimer(withTimeInterval: windowSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rollWindow() }
        }
    }

    /// Commits whatever was recognized in this window and starts a fresh one without
    /// tearing down the audio engine, so capture stays gapless.
    private func rollWindow() {
        guard running else { return }
        commitCurrent()
        // Cancel just the recognition task/request; keep the audio tap alive.
        teardownTask()
        beginWindow()
    }

    private func commitCurrent() {
        let text = lastCommitted.trimmingCharacters(in: .whitespacesAndNewlines)
        lastCommitted = ""
        onPartial?("")
        guard !text.isEmpty else { profiler?.reset(); return }
        let voice = fingerprintForCommit()
        onSegment?(text, windowStart, Date(), voice)
    }

    /// Distill the audio accumulated for this window into a voice fingerprint (and clear it).
    private func fingerprintForCommit() -> VoiceFingerprint? {
        guard let profiler, let analyzer else { return nil }
        let (samples, rate) = profiler.drain()
        return analyzer.fingerprint(samples: samples, rate: rate)
    }

    /// If the speaker pauses mid-window, commit early so segments track natural breaks.
    private func armPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: pauseSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, !self.lastCommitted.isEmpty else { return }
                self.rollWindow()
            }
        }
    }

    private func scheduleRetry() {
        rollTimer?.invalidate()
        rollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginWindow() }
        }
    }

    // MARK: - Teardown

    private func teardownTask() {
        rollTimer?.invalidate(); rollTimer = nil
        pauseTimer?.invalidate(); pauseTimer = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func teardown() {
        teardownTask()
        profiler?.reset()
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
