import AgamottoKit
import Foundation

/// User-configurable settings, persisted in UserDefaults.
struct AppSettings: Equatable, Codable {
    var resolution: Int = 1080      // 360 / 480 / 720 / 1080
    var fps: Int = 60               // 30 / 60
    var replaySeconds: Int = 30
    var bufferSeconds: Int = 120
    var includeMicrophone: Bool = true
    var micGainDb: Double = 6
    var outputDirectoryPath: String = ""   // empty → default ~/Movies/Agamotto

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
    /// (replay length, mic gain, output folder) are read fresh at save time.
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
