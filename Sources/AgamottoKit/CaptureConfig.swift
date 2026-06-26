import Foundation

/// Capture quality knobs. The resolution presets and per-preset bitrates mirror the
/// option set we want to expose to users (menu-bar submenu + settings), and match the
/// shape ShadowPlay-style tools converge on.
public struct CaptureConfig: Sendable {
    public enum Resolution: Int, Sendable, CaseIterable {
        case p360 = 360
        case p480 = 480
        case p720 = 720
        case p1080 = 1080

        /// 16:9 pixel dimensions SCK downscales the display into.
        public var dimensions: (width: Int, height: Int) {
            switch self {
            case .p360: (640, 360)
            case .p480: (854, 480)
            case .p720: (1280, 720)
            case .p1080: (1920, 1080)
            }
        }

        /// Target average video bitrate for this preset.
        public var videoBitrateKbps: Int {
            switch self {
            case .p360: 1_800
            case .p480: 2_800
            case .p720: 5_500
            case .p1080: 10_000
            }
        }
    }

    public var resolution: Resolution
    public var fps: Int
    public var audioSampleRate: Int
    public var audioChannels: Int
    public var capturesSystemAudio: Bool
    public var captureMicrophone: Bool
    /// Gain applied to the mic when mixed into the system audio, in dB.
    public var micGainDb: Float

    public init(
        resolution: Resolution,
        fps: Int,
        audioSampleRate: Int = 48_000,
        audioChannels: Int = 2,
        capturesSystemAudio: Bool = true,
        captureMicrophone: Bool = false,
        micGainDb: Float = 6
    ) {
        self.resolution = resolution
        self.fps = max(fps, 1)
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.capturesSystemAudio = capturesSystemAudio
        self.captureMicrophone = captureMicrophone
        self.micGainDb = micGainDb
    }

    public static let default1080p60 = CaptureConfig(resolution: .p1080, fps: 60)
    public static let default1080p60SystemAndMic = CaptureConfig(
        resolution: .p1080,
        fps: 60,
        capturesSystemAudio: true,
        captureMicrophone: true
    )
}
