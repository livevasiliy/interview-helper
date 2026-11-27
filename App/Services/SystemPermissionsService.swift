import AVFoundation
import AppKit
import CoreGraphics
import InterviewCore

/// Real macOS permission checks behind the `PermissionsService` protocol.
struct SystemPermissionsService: PermissionsService {
    func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

enum SystemSettingsPane {
    case microphone
    case screenRecording

    var url: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    func open() { NSWorkspace.shared.open(url) }
}
