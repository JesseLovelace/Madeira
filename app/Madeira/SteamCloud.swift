// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Steam Cloud saves for games in Madeira Dock's Steam library
// (docs/STEAM_CLOUD.md). Written from Steam's published service messages
// (Cloud.GetAppFileChangelist) and the app's `ufs` product info; the same
// model as other open-source Steam clients use.
//
// Stages 1 and 2, this file: it asks Steam which save files the account has
// in the cloud for a game, finds the same files in the Wine prefix and
// compares them, and can download cloud files into the prefix when the user
// asks. A file a download replaces is copied to a backup folder first.
// Nothing is uploaded yet. Log tag: [steam-cloud] (App IDs, counts, save file
// names under their Steam folder names; never account data or user folder
// names).

import Compression
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

// MARK: - Comparison

/// One save file, on either side or both.
struct SteamCloudEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case same, differ, cloudOnly, localOnly }
    /// The cloud path with its %Root% placeholder (for a local-only file, the
    /// path it would have).
    var path: String
    var kind: Kind
    var cloudSize: UInt64 = 0
    var cloudTime: UInt64 = 0
    var localSize: UInt64 = 0
    var localTime: UInt64 = 0
    var cloudSHA = Data()

    var id: String { path }
    /// The file name without its folders, for display.
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// How one app's cloud and local save files compare.
struct SteamCloudAudit: Equatable, Sendable {
    var changeNumber: UInt64 = 0
    var cloudFiles = 0
    var entries: [SteamCloudEntry] = []
    /// Cloud paths under a root this prefix has no folder for.
    var unmapped: [String] = []

    func count(_ kind: SteamCloudEntry.Kind) -> Int { entries.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }
    func paths(_ kind: SteamCloudEntry.Kind) -> [String] { entries.filter { $0.kind == kind }.map(\.path) }

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
        var known = Set<String>()   // local paths the cloud lists
        for file in listing.files where file.persistState == 0 {
            audit.cloudFiles += 1
            guard let place = paths.location(cloudPath: file.path) else { audit.unmapped.append(file.path); continue }
            let url = SteamCloudPaths.resolve(base: place.base, parts: place.parts)
            known.insert(key(url))
            var entry = SteamCloudEntry(path: file.path, kind: .cloudOnly, cloudSize: file.size, cloudTime: file.timestamp, cloudSHA: file.sha)
            if let local = attributes(url) {
                entry.localSize = local.size; entry.localTime = local.time
                entry.kind = (local.size == file.size && sha1(of: url) == file.sha) ? .same : .differ
            }
            audit.entries.append(entry)
        }
        // Local files the game's save patterns cover that the cloud does not list.
        var folders: [(label: String, url: URL, pattern: String, recursive: Bool)] = []
        for save in saveFiles where save.platforms.isEmpty || save.platforms.contains("windows") {
            guard let place = paths.location(cloudPath: "%\(save.root)%" + (save.path.isEmpty ? "x" : save.path + "/x")) else { continue }
            let folder = SteamCloudPaths.resolve(base: place.base, parts: Array(place.parts.dropLast()))
            let label = "%\(save.root)%" + (save.path.isEmpty ? "" : save.path + "/")
            folders.append((label, folder, save.pattern.isEmpty ? "*" : save.pattern, save.recursive))
        }
        folders.append(("", paths.remoteFolder, "*", true))
        var seen = Set<String>()
        for folder in folders {
            let options: FileManager.DirectoryEnumerationOptions = folder.recursive ? [] : [.skipsSubdirectoryDescendants]
            guard let walk = FileManager.default.enumerator(at: folder.url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: options) else { continue }
            let base = folder.url.resolvingSymlinksInPath().path
            var visited = 0
            for case let url as URL in walk {
                visited += 1
                if visited > 5_000 { break }
                guard fnmatch(folder.pattern, url.lastPathComponent, FNM_CASEFOLD) == 0, let local = attributes(url) else { continue }
                let fileKey = key(url)
                guard !known.contains(fileKey), seen.insert(fileKey).inserted else { continue }
                // Both resolved: the enumerator may spell the same folder differently (/private/var).
                let relative = url.resolvingSymlinksInPath().path.dropFirst(base.count).drop { $0 == "/" }
                audit.entries.append(SteamCloudEntry(path: folder.label + String(relative), kind: .localOnly,
                                                     localSize: local.size, localTime: local.time))
            }
        }
        return audit
    }

    /// Where a file the cloud lists, and this prefix lacks, might really be: the
    /// first file of that name under the user folder, as a path relative to it.
    /// Diagnostic for a game that keeps its saves somewhere Steam does not say.
    static func findElsewhere(name: String, userFolder: URL) -> String? {
        guard let walk = FileManager.default.enumerator(at: userFolder, includingPropertiesForKeys: nil) else { return nil }
        let base = userFolder.resolvingSymlinksInPath().path
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if visited > 30_000 { return nil }
            if walk.level > 7 { walk.skipDescendants(); continue }
            if url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                return String(url.resolvingSymlinksInPath().path.dropFirst(base.count).drop { $0 == "/" })
            }
        }
        return nil
    }

    var summary: String {
        "cloud-change=\(changeNumber) cloud-files=\(cloudFiles) same=\(count(.same)) differ=\(count(.differ)) " +
        "missing-local=\(count(.cloudOnly)) local-only=\(count(.localOnly)) unmapped=\(unmapped.count)"
    }
}

// MARK: - Download

/// Where Steam says a cloud file can be fetched (Cloud.ClientFileDownload).
struct SteamCloudDownloadInfo: Sendable {
    var fileSize: UInt64 = 0      // bytes on the wire
    var rawSize: UInt64 = 0       // bytes of the file itself
    var host = ""
    var path = ""
    var https = true
    var headers: [(name: String, value: String)] = []
    var encrypted = false

    /// CCloud_ClientFileDownload_Response: file_size = 2, raw_file_size = 3,
    /// url_host = 7, url_path = 8, use_https = 9, request_headers = 10
    /// { name = 1, value = 2 }, encrypted = 11.
    static func parse(_ data: Data) throws -> SteamCloudDownloadInfo {
        var decoder = ProtobufDecoder(data)
        var info = SteamCloudDownloadInfo()
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, .varint): info.fileSize = try decoder.readVarint()
            case (3, .varint): info.rawSize = try decoder.readVarint()
            case (7, .lengthDelimited): info.host = try decoder.readString()
            case (8, .lengthDelimited): info.path = try decoder.readString()
            case (9, .varint): info.https = try decoder.readVarint() != 0
            case (11, .varint): info.encrypted = try decoder.readVarint() != 0
            case (10, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var name = "", value = ""
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): name = try sub.readString()
                    case (2, .lengthDelimited): value = try sub.readString()
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                if !name.isEmpty, info.headers.count < 32 { info.headers.append((name, value)) }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return info
    }

    var url: URL? {
        guard !host.isEmpty, !host.contains("/"), !host.contains("@") else { return nil }
        return URL(string: (https ? "https://" : "http://") + host + (path.hasPrefix("/") ? path : "/" + path))
    }
}

enum SteamCloudTransfer {
    /// Saves are small; anything larger than this is refused.
    static let maxFileBytes = 256 << 20

    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The first entry of a ZIP archive (Steam sends a compressed cloud file
    /// as a one-entry archive): stored or deflated. Sizes come from the
    /// central directory, which is always filled in.
    static func unzipFirstEntry(_ data: Data, rawSize: Int) -> Data? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 30, u32(0) == 0x04034b50, rawSize >= 0, rawSize <= maxFileBytes else { return nil }
        let method = u16(8)
        let start = 30 + u16(26) + u16(28)
        var packed = u32(18)
        if packed == 0 {   // sizes deferred to the central directory
            var at = bytes.count - 46
            var found = false
            while at >= start {
                if u32(at) == 0x02014b50 { packed = u32(at + 20); found = true; break }
                at -= 1
            }
            guard found else { return nil }
        }
        guard start <= bytes.count, packed >= 0, start + packed <= bytes.count else { return nil }
        let payload = Array(bytes[start..<(start + packed)])
        if method == 0 { return payload.count == rawSize ? Data(payload) : nil }
        guard method == 8, rawSize > 0 else { return rawSize == 0 && method == 8 ? Data() : nil }
        let capacity = rawSize + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_decode_buffer(&output, capacity, payload, payload.count, nil, COMPRESSION_ZLIB)
        return written == rawSize ? Data(output[0..<rawSize]) : nil
    }

    /// Fetches one cloud file's bytes and checks them against the SHA-1 the
    /// cloud's own list gives. Throws rather than return anything unverified.
    static func fetch(_ info: SteamCloudDownloadInfo, expectedSHA: Data) async throws -> Data {
        guard !info.encrypted else { throw SteamFileError.invalid("This Steam Cloud file is encrypted, which is not supported.") }
        guard let url = info.url, info.fileSize <= UInt64(maxFileBytes), info.rawSize <= UInt64(maxFileBytes) else {
            throw SteamFileError.invalid("Steam gave no usable address for this Steam Cloud file.")
        }
        var request = URLRequest(url: url)
        for header in info.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        let (body, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamFileError.invalid("Steam Cloud download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var file = body
        if info.fileSize != info.rawSize || (body.count != Int(info.rawSize) && body.starts(with: [0x50, 0x4b, 0x03, 0x04])) {
            guard let unpacked = unzipFirstEntry(body, rawSize: Int(info.rawSize)) else {
                throw SteamFileError.invalid("A Steam Cloud file could not be unpacked.")
            }
            file = unpacked
        }
        guard Data(Insecure.SHA1.hash(data: file)) == expectedSHA else {
            throw SteamFileError.invalid("A Steam Cloud file did not match its checksum.")
        }
        return file
    }

    /// Puts downloaded bytes in place. An existing file is first copied under
    /// `backup` (same relative path); the new file replaces it atomically and
    /// takes the cloud's modification time.
    static func place(_ file: Data, at url: URL, backupTo backup: URL, relative: [String], time: UInt64) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            var target = backup
            for part in relative { target.appendPathComponent(part) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: url, to: target)
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url, options: .atomic)
        if time > 0 {
            try? manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(time))], ofItemAtPath: url.path)
        }
    }
}

// MARK: - State the interface shows

/// One game's Steam Cloud state, as its Game details page shows it.
struct SteamCloudState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case checking, ready, downloading(done: Int, of: Int), failed(String) }
    var phase: Phase = .checking
    var audit = SteamCloudAudit()
    var checked: Date?
    /// The last download: how many files arrived, and where replaced files were copied.
    var lastDownload: (files: Int, backedUp: Int)?

    static func == (a: SteamCloudState, b: SteamCloudState) -> Bool {
        a.phase == b.phase && a.audit == b.audit && a.checked == b.checked
            && a.lastDownload?.files == b.lastDownload?.files && a.lastDownload?.backedUp == b.lastDownload?.backedUp
    }
}
