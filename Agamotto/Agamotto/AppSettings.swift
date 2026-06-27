import AgamottoKit
import Foundation

/// An app whose DRM-protected playback should auto-pause capture (Apple TV, Netflix, …).
/// macOS blanks protected video while the screen is being captured, so we step aside.
struct ProtectedApp: Codable, Equatable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    static let defaults: [ProtectedApp] = [
        .init(bundleID: "com.apple.TV", name: "Apple TV"),
        .init(bundleID: "com.netflix.Netflix", name: "Netflix"),
        .init(bundleID: "com.disney.disneyplus", name: "Disney+"),
        .init(bundleID: "com.amazon.aiv.AIVApp", name: "Prime Video"),
    ]
}

/// User-configurable settings, persisted in UserDefaults.
struct AppSettings: Equatable, Codable {
    var resolution: Int = 1080      // 360 / 480 / 720 / 1080
    var fps: Int = 60               // 30 / 60
    var replaySeconds: Int = 30
    var bufferSeconds: Int = 120
    var includeMicrophone: Bool = true
    var micGainDb: Double = 6
    var outputDirectoryPath: String = ""   // empty → default ~/Movies/Agamotto
    var autoPauseForProtectedApps: Bool = true
    var protectedApps: [ProtectedApp] = ProtectedApp.defaults

    enum CodingKeys: String, CodingKey {
        case resolution, fps, replaySeconds, bufferSeconds, includeMicrophone
        case micGainDb, outputDirectoryPath, autoPauseForProtectedApps, protectedApps
    }

    private static let storageKey = "agamotto.settings.v1"

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Capture-affecting fields. When this changes, the engine must restart; other fields
    /// (replay length, mic gain, output folder, protected-app list) are read fresh on demand.
    var captureSignature: String {
        "\(resolution)|\(fps)|\(includeMicrophone)|\(bufferSeconds)"
    }

    var captureConfig: CaptureConfig {
        let preset = CaptureConfig.Resolution(rawValue: resolution) ?? .p1080
        return CaptureConfig(
            resolution: preset,
            fps: fps,
            capturesSystemAudio: true,
            captureMicrophone: includeMicrophone,
            micGainDb: Float(micGainDb)
        )
    }

    var outputDirectory: URL {
        if !outputDirectoryPath.isEmpty {
            return URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Agamotto", isDirectory: true)
    }
}

// Tolerant decoding: missing keys fall back to defaults, so adding new settings in a
// future build never wipes a user's existing saved configuration. (Declared in an
// extension so the memberwise and no-arg initializers are still synthesized.)
extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? 1080
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        replaySeconds = try c.decodeIfPresent(Int.self, forKey: .replaySeconds) ?? 30
        bufferSeconds = try c.decodeIfPresent(Int.self, forKey: .bufferSeconds) ?? 120
        includeMicrophone = try c.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? true
        micGainDb = try c.decodeIfPresent(Double.self, forKey: .micGainDb) ?? 6
        outputDirectoryPath = try c.decodeIfPresent(String.self, forKey: .outputDirectoryPath) ?? ""
        autoPauseForProtectedApps = try c.decodeIfPresent(Bool.self, forKey: .autoPauseForProtectedApps) ?? true
        protectedApps = try c.decodeIfPresent([ProtectedApp].self, forKey: .protectedApps) ?? ProtectedApp.defaults
    }
}
