// What the app does from the command line, for the avatar maker, and the data folder's upkeep.
import Foundation

/// A generated avatar in its folder: sheet.png and avatar.json. Answers the config
/// and the sprite, or every reason it would not work in the overlay.
func checkAvatar(_ folder: URL, _ images: ImageLoader) -> (entry: [String: Any], sprite: Sprite?, problems: [String]) {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("avatar.json")),
          var entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return ([:], nil, ["avatar.json is missing, or is not a JSON object"])
    }
    entry["sheet"] = "sheet.png"
    guard let fixed = try? JSONSerialization.data(withJSONObject: entry),
          let config = try? JSONDecoder().decode(AvatarConfig.self, from: fixed) else {
        return (entry, nil, ["avatar.json needs frameWidth and frameHeight, and each animation a row"])
    }
    guard let sprite = Sprite("candidate", config, base: folder, images: images) else {
        return (entry, nil, ["sheet.png cannot be read, or a \(config.frameWidth)x\(config.frameHeight) frame does not fit it"])
    }
    var problems: [String] = []
    let wanted = config.animations ?? [:]
    for name in animationNames {
        guard wanted[name] != nil else { problems.append("\(name): no animation"); continue }
        guard let a = sprite.animations[name] else { problems.append("\(name): outside the sheet"); continue }
        for i in 0..<a.frames {
            let cell = sprite.frame(a, tick: i)
            guard let seen = sprite.image.visibleBounds(in: cell) else {
                problems.append("\(name): frame \(i) is blank")
                continue
            }
            if seen.minX == 0 && seen.maxX == cell.width - 1 && seen.minY == 0 && seen.maxY == cell.height - 1 {
                problems.append("\(name): frame \(i) fills its cell: is the background still there?")
            }
        }
    }
    if let a = sprite.animations["idle"] {
        let cell = sprite.frame(a, tick: 0)
        if let seen = sprite.image.visibleBounds(in: cell), seen.maxY != cell.height - 1 {
            problems.append("idle: the character must stand on the bottom edge of its cell")
        }
    }
    return (entry, sprite, problems)
}

func fail(_ lines: [String]) -> Never {
    lines.forEach { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    exit(1)
}

/// Copies a checked avatar in and adds it to avatars.json, which goes last: the
/// overlay notices the JSON changing, and by then the sheet is in place.
func installAvatar(_ name: String, from folder: URL, displayName: String?, _ paths: Paths, _ images: ImageLoader) {
    guard name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil,
          !bundledAvatars.contains(name), name != retiredAvatar else {
        fail(["\"\(name)\" cannot be an avatar's name"])
    }
    let (candidate, _, problems) = checkAvatar(folder, images)
    if !problems.isEmpty { fail(problems) }

    let avatarsFile = paths.avatarsFile
    var config: [String: Any] = [:]
    if let data = try? Data(contentsOf: avatarsFile) {
        guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail(["\(avatarsFile.path) is not valid JSON: fix it, then install again"])
        }
        config = read
    }
    var avatars = config["avatars"] as? [String: Any] ?? [:]
    if avatars[name] != nil { fail(["an avatar named \(name) is already configured"]) }

    do {
        let manager = FileManager.default
        let spritesDir = paths.dataDir.appendingPathComponent("sprites")
        try manager.createDirectory(at: spritesDir, withIntermediateDirectories: true)
        let sheet = spritesDir.appendingPathComponent("\(name).png")
        try? manager.removeItem(at: sheet)
        try manager.copyItem(at: folder.appendingPathComponent("sheet.png"), to: sheet)
        var entry = candidate
        entry["sheet"] = "sprites/\(name).png"
        if let displayName { entry["name"] = displayName }
        avatars[name] = entry
        config["avatars"] = avatars
        let json = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: avatarsFile, options: .atomic)
    } catch {
        fail(["could not install: \(error.localizedDescription)"])
    }
    print("Installed \(name). Pick it with /desk-buddy avatar \(name).")
}

/// Makes the data folder, private to this user, and brings over what lived in the old
/// one. Anything already here stays. avatars.json goes last, once its sheets are in place.
public func prepareDataFolder(_ paths: Paths) {
    let manager = FileManager.default
    do {
        try manager.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        #if !os(Windows) // under %LOCALAPPDATA% it is this user's already
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.dataDir.path)
        #endif
    } catch {
        logLine("could not make the data folder: \(error)")
        return
    }
    guard let oldDir = paths.legacyDir else { return }
    for name in ["sprites", "jobs", "avatars.json"] {
        let old = oldDir.appendingPathComponent(name), new = paths.dataDir.appendingPathComponent(name)
        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else { continue }
        do { try manager.moveItem(at: old, to: new) } catch {
            logLine("could not move \(name): \(error)")
        }
    }
    try? manager.removeItem(at: oldDir.appendingPathComponent("sessions"))
}

/// Runs a command-line tool if the arguments name one, and exits; returns if they don't.
/// `writePreview` draws every animation of a sprite to a PNG, as `previewLooks` lays them out.
///
///   DeskBuddy --sheet out.png [avatar]                       any avatar, kyle if none is named, in every mood
///   DeskBuddy --check-avatar <folder> <preview.png>          is this generated avatar ready, and how does it look?
///   DeskBuddy --install-avatar <name> <folder> [display name]  add a generated avatar to avatars.json
public func runTool(_ arguments: [String], _ paths: Paths, _ images: ImageLoader,
                    writePreview: (Sprite?, String) throws -> Void) {
    if (3...4).contains(arguments.count), arguments[1] == "--sheet" {
        let library = AvatarLibrary(paths, images)
        library.refresh()
        if arguments.count == 4, !library.has(arguments[3]) { fail(["no avatar named \(arguments[3])"]) }
        do { try writePreview(library.sprite(arguments.count == 4 ? arguments[3] : defaultAvatar), arguments[2]) } catch { fail([String(describing: error)]) }
        exit(0)
    }
    if arguments.count == 4, arguments[1] == "--check-avatar" {
        let (_, sprite, problems) = checkAvatar(URL(fileURLWithPath: arguments[2]), images)
        if let sprite { do { try writePreview(sprite, arguments[3]) } catch { fail([String(describing: error)]) } }
        if !problems.isEmpty { fail(problems) }
        print("Ready to install. Preview: \(arguments[3])")
        exit(0)
    }
    if (4...5).contains(arguments.count), arguments[1] == "--install-avatar" {
        installAvatar(arguments[2], from: URL(fileURLWithPath: arguments[3]), displayName: arguments.count == 5 ? arguments[4] : nil, paths, images)
        exit(0)
    }
}
