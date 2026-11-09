// The default buddy, which is always out, kept in avatars.json as `default`. Buddies added
// from the menu last for this launch only, so nothing else about them is saved.
import Foundation

/// The saved default, made usable: `builtin` is kyle, and a name nobody knows is kyle too.
func chosenDefault(saved: String?, known: (String) -> Bool) -> String {
    let renamed = saved.map { $0 == retiredAvatar ? defaultAvatar : $0 }
    return renamed.flatMap { known($0) ? $0 : nil } ?? defaultAvatar
}

/// avatars.json as a plain object, so every key survives a rewrite; empty if there is none.
func readAvatarsConfig(_ file: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return config
}

/// Writes avatars.json whole: the app reads it at any moment.
func saveAvatarsConfig(_ config: [String: Any], to file: URL) throws {
    var config = config
    if config["avatars"] == nil { config["avatars"] = [String: Any]() } // the one key the app needs
    let json = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try json.write(to: file, options: .atomic)
}
