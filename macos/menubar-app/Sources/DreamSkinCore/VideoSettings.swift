import Foundation

public enum VideoSettingsError: Error, Equatable {
  case notDirectory
  case symlink
  case networkPath
  case invalidSettings
}

/// Local default-theme video settings. Kept separate from
/// `video-playlist.json` because the injector rewrites playlist state from a
/// fixed field list, which would erase settings.
public struct VideoSettings: Codable, Equatable, Sendable {
  public static let pollIntervalOptions = [1, 2, 5, 10, 30]
  public static let defaultPollIntervalSeconds = 2
  public static let defaultVeil = 100
  public static let maxBytes = 65_536

  public var schemaVersion: Int
  public var autoDiscover: Bool
  public var pollIntervalSeconds: Int
  public var videoDirectory: String?
  public var veil: Int
  public var updatedAt: String

  public init(
    schemaVersion: Int = 1,
    autoDiscover: Bool = true,
    pollIntervalSeconds: Int = VideoSettings.defaultPollIntervalSeconds,
    videoDirectory: String? = nil,
    veil: Int = VideoSettings.defaultVeil,
    updatedAt: String = ""
  ) {
    self.schemaVersion = schemaVersion
    self.autoDiscover = autoDiscover
    self.pollIntervalSeconds = pollIntervalSeconds
    self.videoDirectory = videoDirectory
    self.veil = veil
    self.updatedAt = updatedAt
  }

  public static let `default` = VideoSettings()

  public static func normalized(_ value: VideoSettings) -> VideoSettings {
    var result = value
    result.schemaVersion = 1
    if !pollIntervalOptions.contains(result.pollIntervalSeconds) {
      result.pollIntervalSeconds = defaultPollIntervalSeconds
    }
    result.veil = min(100, max(0, result.veil))
    if let directory = result.videoDirectory {
      if !isAcceptableDirectoryString(directory) {
        result.videoDirectory = nil
      }
    }
    result.updatedAt = String(result.updatedAt.prefix(40))
    return result
  }

  private static func isAcceptableDirectoryString(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf16.count <= 1024 else { return false }
    guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else { return false }
    guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      return false
    }
    return true
  }
}

public enum VideoSettingsStore {
  private struct RawSettings: Decodable {
    var schemaVersion: Int?
    var autoDiscover: Bool?
    var pollIntervalSeconds: Int?
    var videoDirectory: String?
    var veil: Int?
    var updatedAt: String?
  }

  private struct RawPlaylistState: Decodable {
    var softVeil: Bool?
  }

  public static func fileURL(stateRoot: URL) -> URL {
    stateRoot.appendingPathComponent("video-settings.json")
  }

  public static func load(stateRoot: URL) -> VideoSettings {
    let legacy = legacySoftVeil(stateRoot: stateRoot)
    let url = fileURL(stateRoot: stateRoot)
    guard let raw = decodeSettings(url) else {
      var fallback = VideoSettings()
      if legacy == false { fallback.veil = 0 }
      return fallback
    }
    var value = VideoSettings(
      autoDiscover: raw.autoDiscover ?? true,
      pollIntervalSeconds: raw.pollIntervalSeconds ?? VideoSettings.defaultPollIntervalSeconds,
      videoDirectory: raw.videoDirectory,
      veil: raw.veil ?? (legacy == false ? 0 : VideoSettings.defaultVeil),
      updatedAt: raw.updatedAt ?? ""
    )
    value = VideoSettings.normalized(value)
    return value
  }

  public static func save(_ settings: VideoSettings, stateRoot: URL) throws {
    var value = VideoSettings.normalized(settings)
    value.updatedAt = ISO8601DateFormatter().string(from: Date())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    let url = fileURL(stateRoot: stateRoot)
    // A malformed existing file must be repaired by the user, not silently
    // replaced with defaults.
    if FileManager.default.fileExists(atPath: url.path), decodeSettings(url) == nil {
      throw VideoSettingsError.invalidSettings
    }
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateRoot.path)
  }

  public static func effectiveDirectory(_ settings: VideoSettings, stateRoot: URL) -> URL {
    if let value = settings.videoDirectory, !value.isEmpty {
      return URL(fileURLWithPath: value, isDirectory: true)
    }
    return stateRoot.appendingPathComponent("videos", isDirectory: true)
  }

  /// Rejects network paths and linked directories. Files inside the folder are
  /// scanned non-recursively by the injector, which already skips symlinked
  /// entries.
  public static func validateDirectory(_ url: URL) throws -> URL {
    let standardized = url.standardizedFileURL
    guard !standardized.path.hasPrefix("//") else { throw VideoSettingsError.networkPath }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw VideoSettingsError.notDirectory
    }
    let values = try standardized.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true { throw VideoSettingsError.symlink }
    return standardized
  }

  private static func decodeSettings(_ url: URL) -> RawSettings? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count <= VideoSettings.maxBytes,
          let raw = try? JSONDecoder().decode(RawSettings.self, from: data),
          (raw.schemaVersion ?? 1) == 1 else {
      return nil
    }
    return raw
  }

  private static func legacySoftVeil(stateRoot: URL) -> Bool? {
    let url = stateRoot.appendingPathComponent("video-playlist.json")
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count <= VideoSettings.maxBytes,
          let raw = try? JSONDecoder().decode(RawPlaylistState.self, from: data) else {
      return nil
    }
    return raw.softVeil
  }
}