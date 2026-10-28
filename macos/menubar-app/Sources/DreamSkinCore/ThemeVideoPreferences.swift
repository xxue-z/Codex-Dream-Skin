import Foundation

public enum DynamicThemeMode: Equatable, Sendable {
  case playlist
  case video
}

public struct ActiveDynamicTheme: Equatable, Sendable {
  public let id: String
  public let name: String
  public let mode: DynamicThemeMode

  public init(id: String, name: String, mode: DynamicThemeMode) {
    self.id = id
    self.name = name
    self.mode = mode
  }
}

/// Resolves the active theme's dynamic-background capability from the active
/// theme snapshot. The bundled playlist theme is gated by its id (its public
/// theme.json stays hash-stable), while Skin API 2 themes declare
/// `video.file = background.mp4`.
public enum DynamicThemeResolver {
  public static func resolve(
    stateRoot: URL,
    themeID: String,
    playlistThemeID: String
  ) -> ActiveDynamicTheme? {
    let url = stateRoot.appendingPathComponent("theme/theme.json")
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count <= 1_048_576,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? String, !id.isEmpty else {
      return nil
    }
    let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName = name?.isEmpty == false ? name! : id
    if id == playlistThemeID || themeID == playlistThemeID {
      return ActiveDynamicTheme(id: id, name: resolvedName, mode: .playlist)
    }
    let video = object["video"] as? [String: Any]
    guard (video?["file"] as? String) == "background.mp4" else { return nil }
    return ActiveDynamicTheme(id: id, name: resolvedName, mode: .video)
  }
}

public struct ThemeVideoPreferenceEntry: Codable, Equatable, Sendable {
  public var paused: Bool?
  public var muted: Bool?

  public init(paused: Bool? = nil, muted: Bool? = nil) {
    self.paused = paused
    self.muted = muted
  }
}

public struct ThemeVideoPreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var videoBackground: Bool
  public var themes: [String: ThemeVideoPreferenceEntry]

  public init(
    schemaVersion: Int = 1,
    videoBackground: Bool = true,
    themes: [String: ThemeVideoPreferenceEntry] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.videoBackground = videoBackground
    self.themes = themes
  }

  public static let `default` = ThemeVideoPreferences()
}

/// Skin API 2 per-theme mute/pause preferences. Mirrors
/// `theme-video-preferences.json` read by the injector.
public enum ThemeVideoPreferencesStore {
  public static let maxBytes = 256 * 1024

  public static func fileURL(stateRoot: URL) -> URL {
    stateRoot.appendingPathComponent("theme-video-preferences.json")
  }

  public static func load(themeID: String, stateRoot: URL) -> (muted: Bool, paused: Bool) {
    guard let value = decode(fileURL(stateRoot: stateRoot)) else {
      return (muted: true, paused: false)
    }
    let entry = value.themes[themeID]
    return (
      muted: entry?.muted ?? true,
      paused: entry?.paused ?? false
    )
  }

  public static func set(
    themeID: String,
    stateRoot: URL,
    muted: Bool? = nil,
    paused: Bool? = nil
  ) throws {
    let url = fileURL(stateRoot: stateRoot)
    var value: ThemeVideoPreferences
    if FileManager.default.fileExists(atPath: url.path) {
      guard let existing = decode(url) else { throw VideoSettingsError.invalidSettings }
      value = existing
    } else {
      value = .default
    }
    value.schemaVersion = 1
    var entry = value.themes[themeID] ?? ThemeVideoPreferenceEntry()
    if let muted { entry.muted = muted }
    if let paused { entry.paused = paused }
    value.themes[themeID] = entry
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func decode(_ url: URL) -> ThemeVideoPreferences? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count <= maxBytes,
          let value = try? JSONDecoder().decode(ThemeVideoPreferences.self, from: data),
          value.schemaVersion == 1 else {
      return nil
    }
    return value
  }
}