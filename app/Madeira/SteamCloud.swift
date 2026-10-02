// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Steam Cloud saves for games in Madeira Dock's Steam library
// (docs/STEAM_CLOUD.md). Written from Steam's published service messages
// (Cloud.GetAppFileChangelist) and the app's `ufs` product info; the same
// model as other open-source Steam clients use.
//
// Stage 1, this file: read-only. It asks Steam which save files the account
// has in the cloud for each installed game, finds the same files in the Wine
// prefix, and logs how they compare. Nothing is downloaded, uploaded or
// changed. Log tag: [steam-cloud] (App IDs, counts, save file names under
// their Steam folder names; never account data or user folder names).

import CryptoKit
import Foundation

// MARK: - The cloud's file list

/// One file of an app's Steam Cloud, as Cloud.GetAppFileChangelist lists it.
struct SteamCloudFile: Equatable, Sendable {
    /// Folder part, usually starting with a `%Root%` placeholder; may be empty.
    var prefix: String
    var name: String
    var sha: Data
    /// Unix seconds.
    var timestamp: UInt64
    var size: UInt64
    /// persist_state: 0 = present; anything else is a forgotten or deleted file.
    var persistState: UInt32

    var path: String { prefix + name }
}

struct SteamCloudListing: Equatable, Sendable {
    var changeNumber: UInt64 = 0
    var files: [SteamCloudFile] = []

    /// CCloud_GetAppFileChangelist_Response: current_change_number = 1,
    /// files = 2 { file_name = 1, sha_file = 2, time_stamp = 3, raw_file_size = 4,
    /// persist_state = 5, path_prefix_index = 7 }, path_prefixes = 4.
    static func parse(_ data: Data) throws -> SteamCloudListing {
        var decoder = ProtobufDecoder(data)
        var listing = SteamCloudListing()
        var prefixes: [String] = []
        var raw: [(file: SteamCloudFile, prefixIndex: Int?)] = []
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): listing.changeNumber = try decoder.readVarint()
            case (4, .lengthDelimited): prefixes.append(try decoder.readString())
            case (2, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var file = SteamCloudFile(prefix: "", name: "", sha: Data(), timestamp: 0, size: 0, persistState: 0)
                var prefixIndex: Int?
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): file.name = try sub.readString()
                    case (2, .lengthDelimited): file.sha = try sub.readBytes()
                    case (3, .varint): file.timestamp = try sub.readVarint()
                    case (4, .varint): file.size = try sub.readVarint()
                    case (5, .varint): file.persistState = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case (7, .varint): prefixIndex = Int(truncatingIfNeeded: try sub.readVarint())
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                raw.append((file, prefixIndex))
                if raw.count > 20_000 { throw SteamFileError.invalid("Too many Steam Cloud files.") }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        listing.files = raw.map { entry in
            var file = entry.file
            if let index = entry.prefixIndex, prefixes.indices.contains(index) { file.prefix = prefixes[index] }
            return file
        }
        return listing
    }
}

// MARK: - Where a cloud path lives in the Wine prefix

/// Maps Steam's save folders to folders of Madeira Dock's Wine prefix.
/// Foundation only.
struct SteamCloudPaths: Sendable {
    /// drive_c
    var drive: URL
    /// drive_c/users/<name>
    var userFolder: URL
    /// The game's folder under steamapps/common.
    var installFolder: URL
    /// Steam's own folder for files written through the Steam Cloud API:
    /// userdata/<account>/<app>/remote.
    var remoteFolder: URL
    var steamID: UInt64
    var overrides: [SteamAppInfo.RootOverride]

    /// The Windows user folder games write to. A prefix can hold several
    /// folders under users (the template's, earlier builds'); Wine names the
    /// live one after $USER, else the passwd name, so those are tried first,
    /// then the most recently changed. nil when the prefix has none yet.
    static func userFolder(drive: URL) -> (url: URL, candidates: Int, how: String)? {
        let users = drive.appendingPathComponent("users", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: users.path) else { return nil }
        let own = names.filter { !$0.hasPrefix(".") && $0.caseInsensitiveCompare("Public") != .orderedSame }
        func find(_ name: String?) -> URL? {
            guard let name, let match = own.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            return users.appendingPathComponent(match, isDirectory: true)
        }
        if let url = find(getenv("USER").map { String(cString: $0) }) { return (url, own.count, "env") }
        if let entry = getpwuid(getuid()), let url = find(String(cString: entry.pointee.pw_name)) { return (url, own.count, "passwd") }
        func changed(_ name: String) -> Date {
            let appData = users.appendingPathComponent(name + "/AppData", isDirectory: true)
            return (try? appData.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        guard let newest = own.max(by: { changed($0) < changed($1) }) else { return nil }
        return (users.appendingPathComponent(newest, isDirectory: true), own.count, "newest")
    }

    /// The local folder a Steam root name stands for on Windows, or nil for a
    /// root this prefix has no folder for (another platform's).
    func folder(root: String) -> URL? {
        switch root.lowercased() {
        case "gameinstall": return installFolder
        case "winmydocuments": return userFolder.appendingPathComponent("Documents", isDirectory: true)
        case "winappdatalocal": return userFolder.appendingPathComponent("AppData/Local", isDirectory: true)
        case "winappdatalocallow": return userFolder.appendingPathComponent("AppData/LocalLow", isDirectory: true)
        case "winappdataroaming": return userFolder.appendingPathComponent("AppData/Roaming", isDirectory: true)
        case "winsavedgames": return userFolder.appendingPathComponent("Saved Games", isDirectory: true)
        default: return nil
        }
    }

    /// Splits "%Root%rest" into its root name and the rest; no placeholder
    /// gives a nil root (Steam's `remote` folder).
    static func split(_ path: String) -> (root: String?, rest: String) {
        guard path.hasPrefix("%"), let end = path.dropFirst().firstIndex(of: "%") else { return (nil, path) }
        let root = String(path[path.index(after: path.startIndex)..<end])
        return (root, String(path[path.index(after: end)...]))
    }

    /// The path components of a relative save path, or nil when it is not a
    /// plain relative path (empty, absolute, or leaving its folder).
    func components(_ relative: String) -> [String]? {
        let text = relative.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "{64BitSteamID}", with: String(steamID))
            .replacingOccurrences(of: "{Steam3AccountID}", with: String(steamID & 0xFFFF_FFFF))
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 32,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") || $0.utf8.count > 255 }) else { return nil }
        return parts
    }

    /// The base folder and relative components a cloud path maps to, with the
    /// Windows root override applied. nil: no folder here, or an unsafe path.
    func location(cloudPath: String) -> (base: URL, parts: [String])? {
        var (root, rest) = Self.split(cloudPath)
        if let name = root,
           let override = overrides.first(where: { $0.root.caseInsensitiveCompare(name) == .orderedSame
                                                   && $0.os.caseInsensitiveCompare("Windows") == .orderedSame }) {
            if !override.useInstead.isEmpty { root = override.useInstead }
            if !override.addPath.isEmpty { rest = override.addPath + "/" + rest }
        }
        guard let parts = components(rest) else { return nil }
        if let root {
            guard let base = folder(root: root) else { return nil }
            return (base, parts)
        }
        return (remoteFolder, parts)
    }

    /// Wine treats names without regard to case and iOS does not: follow the
    /// components by case-insensitive match, falling back to the given
    /// spelling for the part that does not exist yet.
    static func resolve(base: URL, parts: [String]) -> URL {
        var url = base
        for (index, part) in parts.enumerated() {
            let exact = url.appendingPathComponent(part, isDirectory: index < parts.count - 1)
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                url = url.appendingPathComponent(match, isDirectory: index < parts.count - 1)
            } else {
                url = exact
            }
        }
        return url
    }
}

// MARK: - Comparison (read-only)

/// How one app's cloud and local save files compare.
struct SteamCloudAudit: Sendable {
    struct Difference: Sendable {
        var path: String          // the cloud path, with its %Root% placeholder
        var cloudSize: UInt64
        var localSize: UInt64
        var cloudTime: UInt64
        var localTime: UInt64
    }
    var changeNumber: UInt64 = 0
    var cloudFiles = 0
    var same = 0
    var differ: [Difference] = []
    /// In the cloud, not on this device.
    var missingLocal: [String] = []
    /// On this device (matching the game's save patterns), not in the cloud.
    var localOnly: [String] = []
    /// Cloud paths under a root this prefix has no folder for.
    var unmapped: [String] = []

    static func sha1(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func attributes(_ url: URL) -> (size: UInt64, time: UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (UInt64(max(0, values.fileSize ?? 0)), UInt64(max(0, values.contentModificationDate?.timeIntervalSince1970 ?? 0)))
    }

    /// One spelling per file, whatever route led to it and whatever its case.
    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path.lowercased() }

    /// Compares the listing with the prefix. Reads files; changes nothing.
    static func run(listing: SteamCloudListing, saveFiles: [SteamAppInfo.SaveFile], paths: SteamCloudPaths) -> SteamCloudAudit {
        var audit = SteamCloudAudit()
        audit.changeNumber = listing.changeNumber
        var known = Set<String>()   // lower-cased local paths the cloud lists
        for file in listing.files where file.persistState == 0 {
            audit.cloudFiles += 1
            guard let place = paths.location(cloudPath: file.path) else { audit.unmapped.append(file.path); continue }
            let url = SteamCloudPaths.resolve(base: place.base, parts: place.parts)
            known.insert(key(url))
            guard let local = attributes(url) else { audit.missingLocal.append(file.path); continue }
            if local.size == file.size, sha1(of: url) == file.sha {
                audit.same += 1
            } else {
                audit.differ.append(Difference(path: file.path, cloudSize: file.size, localSize: local.size,
                                               cloudTime: file.timestamp, localTime: local.time))
            }
        }
        // Local files the game's save patterns cover that the cloud does not list.
        var folders: [(label: String, url: URL, pattern: String, recursive: Bool)] = []
        for entry in saveFiles where entry.platforms.isEmpty || entry.platforms.contains("windows") {
            guard let place = paths.location(cloudPath: "%\(entry.root)%" + (entry.path.isEmpty ? "x" : entry.path + "/x")) else { continue }
            let folder = SteamCloudPaths.resolve(base: place.base, parts: Array(place.parts.dropLast()))
            folders.append(("%\(entry.root)%\(entry.path)", folder, entry.pattern.isEmpty ? "*" : entry.pattern, entry.recursive))
        }
        folders.append(("", paths.remoteFolder, "*", true))
        var seen = Set<String>()
        for folder in folders {
            let options: FileManager.DirectoryEnumerationOptions = folder.recursive ? [] : [.skipsSubdirectoryDescendants]
            guard let walk = FileManager.default.enumerator(at: folder.url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: options) else { continue }
            var visited = 0
            for case let url as URL in walk {
                visited += 1
                if visited > 5_000 { break }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      fnmatch(folder.pattern, url.lastPathComponent, FNM_CASEFOLD) == 0 else { continue }
                let fileKey = key(url)
                guard !known.contains(fileKey), seen.insert(fileKey).inserted else { continue }
                // Both resolved: the enumerator may spell the same folder differently (/private/var).
                let relative = url.resolvingSymlinksInPath().path
                    .dropFirst(folder.url.resolvingSymlinksInPath().path.count).drop { $0 == "/" }
                audit.localOnly.append(folder.label + "/" + String(relative))
            }
        }
        return audit
    }

    var summary: String {
        "cloud-change=\(changeNumber) cloud-files=\(cloudFiles) same=\(same) differ=\(differ.count) " +
        "missing-local=\(missingLocal.count) local-only=\(localOnly.count) unmapped=\(unmapped.count)"
    }
}
