import Foundation
import Speech

protocol SpeechService: Sendable {
    var status: String { get async }
    func requestAuthorization() async -> Bool
}

struct AppleSpeechService: SpeechService {
    var status: String {
        get async {
            let status = SFSpeechRecognizer.authorizationStatus()
            switch status {
            case .authorized:
                return "Speech recognition authorized"
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
}

