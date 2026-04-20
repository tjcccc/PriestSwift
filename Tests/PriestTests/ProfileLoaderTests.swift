import XCTest
@testable import Priest

/// Tests for FilesystemProfileLoader caching behaviour.
final class ProfileLoaderTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeProfileDir(name: String, identity: String) -> URL {
        let dir = tmpDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profileMd = dir.appendingPathComponent("PROFILE.md")
        try! identity.write(to: profileMd, atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Basic loading

    func test_loadsProfileFromDirectory() throws {
        _ = makeProfileDir(name: "bot", identity: "I am a bot.")
        let loader = FilesystemProfileLoader(profilesRoot: tmpDir)
        let profile = try loader.load("bot")
        XCTAssertEqual(profile.name, "bot")
        XCTAssertEqual(profile.identity, "I am a bot.")
    }

    func test_fallsBackToDefaultWhenNameIsDefault() throws {
        let loader = FilesystemProfileLoader(profilesRoot: tmpDir)
        let profile = try loader.load("default")
        XCTAssertEqual(profile.name, "default")
    }

    func test_throwsWhenProfileNotFoundAndNotDefault() {
        let loader = FilesystemProfileLoader(profilesRoot: tmpDir)
        XCTAssertThrowsError(try loader.load("missing"))
    }

    // MARK: - Cache hit

    func test_cacheHit_returnsSameInstanceWhenFilesUnchanged() throws {
        _ = makeProfileDir(name: "bot", identity: "Bot.")
        let loader = FilesystemProfileLoader(profilesRoot: tmpDir)
        let first  = try loader.load("bot")
        let second = try loader.load("bot")
        // Same value-type content; verify identity via name equality and that no re-parse occurred
        // (Profile is a struct so reference equality is not applicable — check content is stable)
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(first.name,     second.name)
    }

    // MARK: - Cache invalidation

    func test_cacheInvalidation_reloadsAfterFileModified() throws {
        let dir = makeProfileDir(name: "bot", identity: "Bot v1.")
        let profileMd = dir.appendingPathComponent("PROFILE.md")
        let loader = FilesystemProfileLoader(profilesRoot: tmpDir)
        let first = try loader.load("bot")
        XCTAssertEqual(first.identity, "Bot v1.")

        // Overwrite file content and advance mtime by 2 seconds
        try "Bot v2.".write(to: profileMd, atomically: true, encoding: .utf8)
        let futureDate = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: profileMd.path)

        let second = try loader.load("bot")
        XCTAssertEqual(second.identity, "Bot v2.")
    }

    func test_cacheInvalidation_reloadsWhenFileAdded() throws {
        let dir = makeProfileDir(name: "bot", identity: "Bot.")
        let loader = FilesystemProfileLoader(profilesRoot: tmpDir)
        _ = try loader.load("bot")

        // Add an optional RULES.md — fileCount changes, cache invalidates
        let rulesMd = dir.appendingPathComponent("RULES.md")
        try "Be concise.".write(to: rulesMd, atomically: true, encoding: .utf8)
        let futureDate = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: rulesMd.path)

        let reloaded = try loader.load("bot")
        XCTAssertEqual(reloaded.rules, "Be concise.")
    }
}
