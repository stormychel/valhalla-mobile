import Foundation
import ValhallaConfigModels
import Light_Swift_Untar

enum ValhallaFileManagerError: Error {
    case tzdataNotFound
    case systemDirNotFound(String)
}

enum ValhallaFileManager {
    
    /// Write `config` to disk and return the path the C++ core should read.
    ///
    /// The file is named after the config's own content. Every `Valhalla`
    /// instance used to share one `valhalla-config.json`, which is a data race
    /// as soon as a process builds more than one engine — and an app that
    /// routes on a background task while the user plans a route does exactly
    /// that. Two intermittent failures came out of it:
    ///
    /// - A reader catching a partially-written file: `Could not parse json,
    ///   error at offset: N`, because the write was not atomic.
    /// - A reader catching a *complete* file written by a different engine, and
    ///   silently routing against the wrong tile directory. That one is worse —
    ///   it doesn't look like corruption, it looks like a bad route, or
    ///   `No suitable edges near location` when the requested coordinates
    ///   aren't inside the other engine's graph.
    ///
    /// Content-addressing fixes both. Different configs get different files, so
    /// they cannot overwrite each other; identical configs share one file and
    /// write identical bytes. The write is atomic, so a concurrent reader sees
    /// a whole file or no file.
    ///
    /// This rests on `JSONEncoder` being byte-stable for a given config, which
    /// holds because `ValhallaConfig` has no `Dictionary` properties — Swift's
    /// per-process hash seeding would otherwise reorder dictionary keys and
    /// scatter a fresh file on every launch. Adding a `Dictionary` property to
    /// `ValhallaConfig` would silently break that, and the symptom would be a
    /// slowly filling Application Support rather than a crash — worth a test
    /// here once this package's test target builds again (it currently fails to
    /// resolve: the library requires macOS 10.13 while its model dependencies
    /// require 10.15).
    static func saveConfigTo(_ config: ValhallaConfig) throws -> URL {
        guard let applicationDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ValhallaFileManagerError.systemDirNotFound("applicationSupport")
        }
        try FileManager.default.createDirectory(at: applicationDir, withIntermediateDirectories: true)
        removeLegacyConfig(in: applicationDir)
        let data = try JSONEncoder().encode(config)
        let configURL = applicationDir
            .appendingPathComponent("valhalla-config-\(stableDigest(of: data)).json")

        // Always write, atomically. An earlier revision skipped the write when
        // a file already sat at this path, to save re-encoding identical bytes
        // for apps that build many engines. That saving is real but small, and
        // it introduced a worse failure mode: a damaged file at the path would
        // be trusted forever, wedging every future engine construction with
        // `Could not parse json`. Writing unconditionally is what the code did
        // before this change and cannot regress.
        try data.write(to: configURL, options: .atomic)
        sweepStaleConfigs(in: applicationDir, keeping: configURL)
        return configURL
    }

    /// Delete the single shared config this used to write.
    ///
    /// Nothing reads it any more, and leaving it behind means every app that
    /// upgrades carries a stale file forever. Safe to do while an older engine
    /// is alive: the C++ core parses the config once in `ValhallaActor`'s
    /// constructor and keeps only the parsed tree, so the path is never
    /// re-read. Best-effort — failing to remove it must never block engine
    /// construction.
    private static func removeLegacyConfig(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("valhalla-config.json"))
    }

    /// Drop content-addressed configs nothing is going to ask for again.
    ///
    /// `ValhallaConfig` embeds the ABSOLUTE tile path, and iOS rotates the
    /// container UUID on every app update, so each update re-mints every config
    /// the app uses. At ~10 KB apiece across per-region tile directories and
    /// years of updates that is a slow leak — untidy rather than dangerous, but
    /// there is no reason to keep them.
    ///
    /// The grace window is what makes this safe. A file written moments ago is
    /// never swept, which closes the only harmful window: between another
    /// thread's write and the C++ side reading it. Sweeping a config that IS in
    /// use is harmless anyway — it has already been parsed, and the next
    /// construction simply writes it again. Crash-orphaned `.atomic` temp files
    /// in the same directory age out the same way.
    private static func sweepStaleConfigs(in directory: URL, keeping current: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        for url in entries where url.lastPathComponent.hasPrefix("valhalla-config-") {
            guard url != current else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// FNV-1a over the encoded config.
    ///
    /// Deliberately not `hashValue`: Swift seeds that per process, so the same
    /// config would land in a different file on every launch and the directory
    /// would grow without bound.
    private static func stableDigest(of data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Add tzdata to the Library directory
    ///
    /// The HowardHinnant/date library used in valhalla requires the tzdata.tar file to be stored
    /// in Bundle.main. When the tar is manually added that way, the c++ library will extract this
    /// into the Library directory on run. This function provides a workaround for this by injecting
    /// our own resource tzdata.tar into the Library directory before any balhalla action runs.
    ///
    /// Learn more see <https://github.com/HowardHinnant/date>
    /// and <https://howardhinnant.github.io/date/tz.html#Installation>
    static func injectTzdataIntoLibrary() throws {
        guard let tzdataFileURL = Bundle.module.url(forResource: "tzdata", withExtension: "tar") else {
            throw ValhallaFileManagerError.tzdataNotFound
        }

        guard let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw ValhallaFileManagerError.systemDirNotFound("library")
        }

        let tzdataFileData = try Data(contentsOf: tzdataFileURL)
        let libraryURL = libraryDir.appendingPathComponent("tzdata")

        // Write the tar to Library/tzdata
        // TODO: We can create our own tar extract here if we want to avoid the dependency
        try FileManager.default.createFilesAndDirectories(url: libraryURL, tarData: tzdataFileData)
    }
}
