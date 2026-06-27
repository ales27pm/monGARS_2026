import AVFoundation
import Foundation
import Speech

enum SpeechServiceError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case audioInputUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech permission was not granted or is unavailable."
        case .recognizerUnavailable:
            "Speech recognition is unavailable right now."
        case .audioInputUnavailable:
            "The microphone input could not be started."
        }
    }
}

protocol SpeechService: Sendable {
    var status: String { get async }
    func requestAuthorization() async -> Bool
    func startTranscription(onPartial: @escaping @Sendable (String) -> Void) async throws
    func stopTranscription()
}

final class AppleSpeechService: SpeechService, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var status: String {
        get async {
            let status = SFSpeechRecognizer.authorizationStatus()
            switch status {
            case .authorized:
                return recognizer?.isAvailable == true ? "Speech recognition authorized" : "Speech recognition unavailable"
            case .denied:
                return "Speech recognition denied"
            case .restricted:
                return "Speech recognition restricted on this device"
            case .notDetermined:
                return "Speech recognition permission not requested"
            @unknown default:
                return "Speech recognition status unknown"
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func startTranscription(onPartial: @escaping @Sendable (String) -> Void) async throws {
        guard await requestAuthorization() else {
            throw SpeechServiceError.permissionDenied
        }
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechServiceError.recognizerUnavailable
        }

        stopTranscription()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.channelCount > 0 else {
            throw SpeechServiceError.audioInputUnavailable
        }

        try configureAudioSession()
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                onPartial(text)
            }
            if error != nil || result?.isFinal == true {
                self?.stopTranscription()
            }
        }

        lock.withLock {
            recognitionRequest = request
            recognitionTask = task
        }
    }

    func stopTranscription() {
        lock.withLock {
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            recognitionRequest = nil
            recognitionTask = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
