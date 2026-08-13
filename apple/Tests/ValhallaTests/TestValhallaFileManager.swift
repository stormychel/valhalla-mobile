import XCTest
import ValhallaConfigModels
@testable import Valhalla

/// Config files are content-addressed so two engines can't share, overwrite, or
/// half-read one another's config. These pin the properties that makes safe.
final class TestValhallaFileManager: XCTestCase {

    private var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private func tilesDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("valhalla-test-tiles-\(name)", isDirectory: true)
    }

    // MARK: Digest stability

    /// The load-bearing assumption: encoding must produce identical bytes for
    /// an identical config, or the digest changes and Application Support fills
    /// with a new config file per engine construction.
    ///
    /// This is not free. With a plain `JSONEncoder` it FAILED — five encodes of
    /// one config gave five different digests, same byte count, different key
    /// order. `.sortedKeys` is what makes it hold, and this test is what caught
    /// it; two code reviews had both concluded the encoding was already stable.
    func testSameConfigAlwaysProducesTheSamePath() throws {
        let first = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("same")))
        let second = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("same")))

        XCTAssertEqual(first, second, "the same config produced two different config files")
    }

    /// Repeated encodes of one value — the case that actually failed before
    /// `.sortedKeys`, where two separately-built-but-equal configs might not.
    func testDigestIsStableAcrossRepeatedEncodes() throws {
        let config = try ValhallaConfig(tilesDir: tilesDir("stable"))
        let paths = try (0..<5).map { _ in try ValhallaFileManager.saveConfigTo(config) }

        XCTAssertEqual(Set(paths).count, 1, "the digest drifted across encodes: \(Set(paths))")
    }

    /// The actual bug: two engines with different tile directories must never
    /// land on the same file, or one silently routes against the other's graph.
    func testDifferentConfigsProduceDifferentPaths() throws {
        let a = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("a")))
        let b = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("b")))

        XCTAssertNotEqual(a, b, "two different configs shared one file — the race is back")
    }

    /// What lands on disk must be the config we asked for.
    func testTheWrittenFileIsTheConfigWeAskedFor() throws {
        let dir = tilesDir("roundtrip")
        let url = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: dir))

        let onDisk = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ValhallaConfig.self, from: onDisk)
        let reEncoded = try ValhallaFileManager.deterministicEncoder.encode(decoded)
        XCTAssertEqual(onDisk, reEncoded, "the file on disk is not the config that was asked for")
    }

    /// A damaged file must not be trusted. The write is unconditional for
    /// exactly this reason — an earlier revision skipped it when the path
    /// existed, which would wedge every future engine construction.
    func testADamagedConfigIsRewritten() throws {
        let config = try ValhallaConfig(tilesDir: tilesDir("damaged"))
        let url = try ValhallaFileManager.saveConfigTo(config)
        try Data().write(to: url)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)

        _ = try ValhallaFileManager.saveConfigTo(config)

        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0,
                             "a zero-length config was left in place; every future engine would fail to parse it")
    }

    // MARK: Cleanup

    /// The pre-fix shared file is removed, so an upgrading app doesn't carry it
    /// forever.
    func testTheLegacySharedConfigIsRemoved() throws {
        let legacy = appSupport.appendingPathComponent("valhalla-config.json")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy)

        _ = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("legacy")))

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "the pre-fix valhalla-config.json was left behind")
    }

    /// The sweep is a delete path, so pin both halves: old files go, and — the
    /// half that matters — anything recent stays. Sweeping a config seconds
    /// after another thread wrote it, but before the C++ side reads it, is the
    /// one way this could break routing.
    func testTheSweepTakesOldConfigsAndSparesRecentOnes() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let old = appSupport.appendingPathComponent("valhalla-config-0000deadbeef.json")
        let recent = appSupport.appendingPathComponent("valhalla-config-1111deadbeef.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 60 * 60)],
            ofItemAtPath: old.path)

        _ = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("sweep")))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a month-old config survived the sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path),
                      "the sweep took a freshly written config — this is the race it must not create")
    }

    /// The config just written is never swept, whatever its timestamp.
    func testTheConfigJustWrittenIsNeverSwept() throws {
        let url = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("current")))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 60 * 60)],
            ofItemAtPath: url.path)

        let again = try ValhallaFileManager.saveConfigTo(ValhallaConfig(tilesDir: tilesDir("current")))

        XCTAssertEqual(url, again)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path),
                      "saveConfigTo swept the very file it returned")
    }
}
