import Foundation
import Speech
import AVFoundation

// MARK: - VoiceSearchController

/// Streams microphone audio through SFSpeechRecognizer and publishes live
/// interim transcripts that populate the Quick Action search field.
///
/// Permissions required (declared in Info.plist):
///   NSMicrophoneUsageDescription
///   NSSpeechRecognitionUsageDescription
@MainActor
final class VoiceSearchController: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var isListening      = false
    @Published var interimText      = ""          // live partial result
    @Published var authStatus       = SFSpeechRecognizerAuthorizationStatus.notDetermined
    @Published var micAuthStatus    = AVAuthorizationStatus.notDetermined
    @Published var errorMessage: String?

    // MARK: - Private

    private let recognizer          = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
    private var request:  SFSpeechAudioBufferRecognitionRequest?
    private var task:     SFSpeechRecognitionTask?
    private let engine              = AVAudioEngine()

    override init() {
        super.init()
        authStatus    = SFSpeechRecognizer.authorizationStatus()
        micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Permission

    var isAvailable: Bool {
        authStatus    == .authorized &&
        micAuthStatus == .authorized &&
        recognizer?.isAvailable == true
    }

    /// Returns true if both permissions are granted (shows actionable error if not).
    func requestPermissions() async -> Bool {
        // Speech recognition
        if authStatus != .authorized {
            authStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        }
        // Microphone
        if micAuthStatus != .authorized {
            micAuthStatus = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted ? .authorized : .denied)
                }
            }
        }
        if !isAvailable {
            errorMessage = buildPermissionError()
            return false
        }
        return true
    }

    // MARK: - Start / Stop

    /// Starts streaming mic input into the recogniser.
    /// Call `onTranscript` whenever a new interim result arrives.
    func start(onTranscript: @escaping (String) -> Void) async {
        guard await requestPermissions() else { return }
        guard !isListening else { return }

        isListening   = true
        interimText   = ""
        errorMessage  = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .search
        request = req

        let node   = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in
            req?.append(buf)
        }

        do { try engine.start() } catch {
            await stopInternal(error: "Microphone could not start: \(error.localizedDescription)")
            return
        }

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    self.interimText = text
                    onTranscript(text)
                }
                if error != nil || result?.isFinal == true {
                    await self.stopInternal(error: nil)
                }
            }
        }
    }

    func stop() {
        Task { await stopInternal(error: nil) }
    }

    private func stopInternal(error: String?) async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request    = nil
        task       = nil
        isListening = false
        if let error { errorMessage = error }
    }

    // MARK: - Helpers

    private func buildPermissionError() -> String {
        var parts: [String] = []
        if authStatus != .authorized {
            parts.append("Speech Recognition: go to System Settings → Privacy → Speech Recognition → enable Halo")
        }
        if micAuthStatus != .authorized {
            parts.append("Microphone: go to System Settings → Privacy → Microphone → enable Halo")
        }
        return parts.joined(separator: "\n")
    }
}
