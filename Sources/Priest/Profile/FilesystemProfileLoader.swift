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
/// Caches loaded profiles per instance. Cache is invalidated when the max mtime
/// or file count across all profile files changes.
///
/// If `profilesRoot` is nil or the named profile is not found, falls back to the
/// built-in default profile when `name == "default"`.
public struct FilesystemProfileLoader: ProfileLoader {
    public let profilesRoot: URL?

    public init(profilesRoot: URL? = nil) {
        self.profilesRoot = profilesRoot
    }

    // Box mutable cache in a class so the struct can remain non-mutating.
    private final class Cache: @unchecked Sendable {
        struct Entry {
            let maxMtime: Date
            let fileCount: Int
            let profile: Profile
        }
        var entries: [String: Entry] = [:]
    }
    private let _cache = Cache()

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
        let (maxMtime, fileCount) = profileCacheKey(dir: dir)
        if let entry = _cache.entries[name], entry.maxMtime == maxMtime, entry.fileCount == fileCount {
            return entry.profile
        }

        let identity = try readFile(dir.appendingPathComponent("PROFILE.md"))
        let rules    = readFileOrEmpty(dir.appendingPathComponent("RULES.md"))
        let custom   = readFileOrEmpty(dir.appendingPathComponent("CUSTOM.md"))
        let memories = loadMemories(from: dir.appendingPathComponent("memories"))

        let profile = Profile(
            name: name,
            identity: identity,
            rules: rules,
            custom: custom,
            memories: memories,
            meta: [:]
        )
        _cache.entries[name] = Cache.Entry(maxMtime: maxMtime, fileCount: fileCount, profile: profile)
        return profile
    }

    private func profileCacheKey(dir: URL) -> (maxMtime: Date, fileCount: Int) {
        let fm = FileManager.default
        var candidates: [URL] = [
            dir.appendingPathComponent("PROFILE.md"),
            dir.appendingPathComponent("RULES.md"),
            dir.appendingPathComponent("CUSTOM.md"),
            dir.appendingPathComponent("profile.toml"),
        ]
        let memoriesDir = dir.appendingPathComponent("memories")
        if let entries = try? fm.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil) {
            candidates += entries
        }

        var maxMtime = Date.distantPast
        var fileCount = 0
        for url in candidates {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            fileCount += 1
            if mtime > maxMtime { maxMtime = mtime }
        }
        return (maxMtime, fileCount)
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
            let content = readFileOrEmpty(memoriesDir.appendingPathComponent(filename))
            return content.isEmpty ? nil : content
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
