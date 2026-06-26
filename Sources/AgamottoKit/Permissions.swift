import AVFoundation
import CoreGraphics
import Foundation

public enum MicrophonePermission: Sendable, CustomStringConvertible {
    case granted
    case denied
    case restricted
    case notDetermined

    public var description: String {
        switch self {
        case .granted: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        }
    }
}

/// macOS TCC helpers. Screen Recording is a runtime grant (no entitlement); microphone
/// uses the standard AVCaptureDevice flow. Deep-link openers come in the onboarding phase.
public enum Permissions {
    /// True if Screen Recording is currently granted.
    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Preflight, and if not granted trigger the system prompt. Returns the *current* grant
    /// state. Note: a fresh grant often only takes effect after the app relaunches, and when
    /// run as a CLI the grant is attributed to the host app (Terminal/Xcode).
    @discardableResult
    public static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    public static func microphoneStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Request mic access if undetermined; otherwise report the current status.
    public static func ensureMicrophone() async -> MicrophonePermission {
        switch microphoneStatus() {
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case let current:
            return current
        }
    }
}
