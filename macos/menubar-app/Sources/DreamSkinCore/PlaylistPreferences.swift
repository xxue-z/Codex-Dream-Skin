import Foundation

public struct PlaylistPreferences: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var index: Int
  public var positionSeconds: Double
  public var muted: Bool
  public var paused: Bool
  public var softVeil: Bool
  public var updatedAt: String

  public init(
    schemaVersion: Int = 1,
    index: Int = 0,
    positionSeconds: Double = 0,
    muted: Bool = true,
    paused: Bool = false,
    softVeil: Bool = true,
    updatedAt: String = ""
  ) {
    self.schemaVersion = schemaVersion
    self.index = index
    self.positionSeconds = positionSeconds
    self.muted = muted
    self.paused = paused
    self.softVeil = softVeil
    self.updatedAt = updatedAt
  }

  public static let `default` = PlaylistPreferences()
}

public enum PlaylistPreferencesStore {
  public static func fileURL(stateRoot: URL) -> URL {
    stateRoot.appendingPathComponent("video-playlist.json")
  }

  public static func load(stateRoot: URL) -> PlaylistPreferences {
    let url = fileURL(stateRoot: stateRoot)
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count <= 65_536,
          let value = try? JSONDecoder().decode(PlaylistPreferences.self, from: data),
          value.schemaVersion == 1 else {
      return .default
    }
    return value
  }

  public static func save(_ preferences: PlaylistPreferences, stateRoot: URL) throws {
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    var value = preferences
    value.schemaVersion = 1
    value.updatedAt = ISO8601DateFormatter().string(from: Date())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let url = fileURL(stateRoot: stateRoot)
    try data.write(to: url, options: .atomic)
  }
}
