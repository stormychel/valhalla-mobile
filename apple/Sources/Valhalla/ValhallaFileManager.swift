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
    /// write identical bytes, so the directory stays bounded and nothing needs
    /// cleaning up. The write is atomic, so a concurrent reader sees a whole
    /// file or no file.
    static func saveConfigTo(_ config: ValhallaConfig) throws -> URL {
        guard let applicationDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ValhallaFileManagerError.systemDirNotFound("applicationSupport")
        }
        try FileManager.default.createDirectory(at: applicationDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        let configURL = applicationDir
            .appendingPathComponent("valhalla-config-\(stableDigest(of: data)).json")

        try data.write(to: configURL, options: .atomic)
        return configURL
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
