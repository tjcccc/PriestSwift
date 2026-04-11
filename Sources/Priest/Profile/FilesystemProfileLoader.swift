import Foundation

/// Loads profiles from a directory on the filesystem.
///
/// Profile directory layout:
/// ```
/// {profilesRoot}/
///   {name}/
///     PROFILE.md    — required
///     RULES.md      — optional
///     CUSTOM.md     — optional
///     profile.toml  — optional (reserved, not consumed by engine)
///     memories/     — optional directory of .md/.txt files
/// ```
///
/// If `profilesRoot` is nil or the named profile is not found, falls back to the
/// built-in default profile when `name == "default"`.
public struct FilesystemProfileLoader: ProfileLoader {
    public let profilesRoot: URL?

    public init(profilesRoot: URL? = nil) {
        self.profilesRoot = profilesRoot
    }

    public func load(_ name: String) throws -> Profile {
        if let root = profilesRoot {
            let profileDir = root.appendingPathComponent(name)
            let profileMd = profileDir.appendingPathComponent("PROFILE.md")
            if FileManager.default.fileExists(atPath: profileMd.path) {
                return try loadFromDirectory(name: name, dir: profileDir)
            }
        }
        if name == "default" {
            return DefaultProfile.profile
        }
        throw PriestError.profileNotFound(name)
    }

    private func loadFromDirectory(name: String, dir: URL) throws -> Profile {
        let identity = try readFile(dir.appendingPathComponent("PROFILE.md"))
        let rules    = readFileOrEmpty(dir.appendingPathComponent("RULES.md"))
        let custom   = readFileOrEmpty(dir.appendingPathComponent("CUSTOM.md"))
        let memories = loadMemories(from: dir.appendingPathComponent("memories"))

        return Profile(
            name: name,
            identity: identity,
            rules: rules,
            custom: custom,
            memories: memories,
            meta: [:]  // profile.toml parsing reserved for future version
        )
    }

    private func loadMemories(from memoriesDir: URL) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: memoriesDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: memoriesDir.path) else {
            return []
        }
        let files = entries
            .filter { $0.hasSuffix(".md") || $0.hasSuffix(".txt") }
            .sorted()
        return files.compactMap { filename in
            readFileOrEmpty(memoriesDir.appendingPathComponent(filename)).isEmpty ? nil
                : readFileOrEmpty(memoriesDir.appendingPathComponent(filename))
        }
    }

    private func readFile(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PriestError(code: .profileInvalid, message: "Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func readFileOrEmpty(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
