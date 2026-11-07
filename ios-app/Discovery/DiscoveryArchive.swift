import Foundation
#if canImport(Compression)
import Compression
#endif

// MARK: - Limits

struct IPALimits {
    var maxEntries = 30_000
    var maxTotalUncompressed: UInt64 = 6 * 1024 * 1024 * 1024
    var maxExecutable: UInt64 = 1_500_000_000
    var maxPlist: UInt64 = 2 * 1024 * 1024
    var maxCompressionRatio: UInt64 = 1000      // per entry that we actually decompress
    var maxFileSize: UInt64 = 4 * 1024 * 1024 * 1024
    var maxPathDepth = 128
    var rejectSymlinks = false
    static let standard = IPALimits()
}

enum IPAValidationError: Error, Equatable, CustomStringConvertible {
    case notZip, zip64Unsupported, tooManyEntries, tooLarge, unsafePath(String), noApp, multipleApps
    case plistMissing, plistInvalid, executableMissing, badIdentifier, badVersion
    case bundleMismatch(expected: String, actual: String), versionMismatch(expected: String, actual: String)
    case minOSTooHigh(String), notArm64, encrypted, machOInvalid, decompressionFailed, ratioExceeded

    var description: String {
        switch self {
        case .notZip: return "The file is not a valid IPA (zip) archive."
        case .zip64Unsupported: return "Archives needing zip64 are refused."
        case .tooManyEntries: return "The archive has too many files."
        case .tooLarge: return "The archive is larger than the allowed limit."
        case .unsafePath(let p): return "Unsafe path inside the archive: \(p)"
        case .noApp: return "No app was found inside Payload/."
        case .multipleApps: return "The archive holds more than one app."
        case .plistMissing: return "Info.plist is missing."
        case .plistInvalid: return "Info.plist could not be read."
        case .executableMissing: return "The app's executable is missing."
        case .badIdentifier: return "The bundle identifier is invalid."
        case .badVersion: return "The version string is invalid."
        case .bundleMismatch(let e, let a): return "Wrong app: expected \(e) but the file is \(a)."
        case .versionMismatch(let e, let a): return "Version mismatch: the source said \(e) but the file is \(a)."
        case .minOSTooHigh(let v): return "The app needs iOS \(v) or newer."
        case .notArm64: return "The app has no arm64 slice."
        case .encrypted: return "The app is still FairPlay-encrypted, so it can't be used."
        case .machOInvalid: return "The executable is not a valid Mach-O file."
        case .decompressionFailed: return "The archive is corrupt."
        case .ratioExceeded: return "The archive looks like a decompression bomb."
        }
    }
}

// MARK: - Zip central directory reader (read only, nothing is extracted to disk)

struct ZipEntry: Equatable {
    let name: String
    let method: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

struct ZipReader {
    let data: Data          // memory-mapped file or in-memory bytes
    let entries: [ZipEntry]

    static func le16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    static func le32(_ d: Data, _ o: Int) -> UInt32 { UInt32(le16(d, o)) | UInt32(le16(d, o + 2)) << 16 }

    /// Rejects absolute paths, parent traversal, backslashes, NULs, control chars and drive letters.
    static func isSafePath(_ p: String) -> Bool {
        if p.isEmpty || p.hasPrefix("/") || p.contains("\\") || p.contains("\0") { return false }
        if p.unicodeScalars.contains(where: { $0.value < 0x20 }) { return false }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains("..") { return false }
        if let f = parts.first, f.count == 2, f.last == ":" { return false }
        return true
    }

    init(data: Data, limits: IPALimits = .standard) throws {
        self.data = data
        guard data.count >= 22, data.count <= Int(limits.maxFileSize) else { throw IPAValidationError.notZip }
        guard data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else { throw IPAValidationError.notZip }
        // find End Of Central Directory (last 64KB + 22)
        var eocd = -1
        let start = max(0, data.count - 22 - 65_535)
        var i = data.count - 22
        while i >= start {
            if Self.le32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw IPAValidationError.notZip }
        let total = Int(Self.le16(data, eocd + 10))
        let cdSize = Int(Self.le32(data, eocd + 12))
        let cdOffset = Int(Self.le32(data, eocd + 16))
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw IPAValidationError.zip64Unsupported }
        guard total <= limits.maxEntries else { throw IPAValidationError.tooManyEntries }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= eocd else { throw IPAValidationError.notZip }
        var out: [ZipEntry] = []; out.reserveCapacity(total)
        var p = cdOffset
        var sum: UInt64 = 0
        for _ in 0..<total {
            guard p + 46 <= cdOffset + cdSize, Self.le32(data, p) == 0x02014b50 else { throw IPAValidationError.notZip }
            let method = Self.le16(data, p + 10)
            let csize = UInt64(Self.le32(data, p + 20)), usize = UInt64(Self.le32(data, p + 24))
            let nlen = Int(Self.le16(data, p + 28)), elen = Int(Self.le16(data, p + 30)), clen = Int(Self.le16(data, p + 32))
            let off = UInt64(Self.le32(data, p + 42))
            guard p + 46 + nlen + elen + clen <= cdOffset + cdSize else { throw IPAValidationError.notZip }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || off == 0xFFFF_FFFF { throw IPAValidationError.zip64Unsupported }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nlen))
            guard let name = String(data: nameData, encoding: .utf8) else { throw IPAValidationError.unsafePath("<non-utf8>") }
            guard Self.isSafePath(name), name.split(separator: "/").count <= limits.maxPathDepth else { throw IPAValidationError.unsafePath(name) }
            let unixMode = Self.le32(data, p + 38) >> 16
            if limits.rejectSymlinks && (unixMode & 0xF000) == 0xA000 { throw IPAValidationError.unsafePath(name) }
            sum += usize
            guard sum <= limits.maxTotalUncompressed else { throw IPAValidationError.tooLarge }
            out.append(ZipEntry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: off))
            p += 46 + nlen + elen + clen
        }
        self.entries = out
    }

    func entry(_ name: String) -> ZipEntry? { entries.first { $0.name == name } }

    /// Reads bytes [offset, offset+length) of the decompressed entry, streaming, never more than the declared size.
    func read(_ e: ZipEntry, offset: UInt64 = 0, length: UInt64, limits: IPALimits = .standard) throws -> Data {
        let lh = Int(e.localHeaderOffset)
        guard lh + 30 <= data.count, Self.le32(data, lh) == 0x04034b50 else { throw IPAValidationError.notZip }
        let nlen = Int(Self.le16(data, lh + 26)), elen = Int(Self.le16(data, lh + 28))
        let begin = lh + 30 + nlen + elen
        guard begin >= 0, UInt64(begin) + e.compressedSize <= UInt64(data.count) else { throw IPAValidationError.notZip }
        let raw = data.subdata(in: (data.startIndex + begin)..<(data.startIndex + begin + Int(e.compressedSize)))
        if offset >= e.uncompressedSize { return Data() }
        let want = min(length, e.uncompressedSize - offset)
        switch e.method {
        case 0:
            guard e.compressedSize == e.uncompressedSize, offset + want <= UInt64(raw.count) else { throw IPAValidationError.notZip }
            return raw.subdata(in: Int(offset)..<Int(offset + want))
        case 8:
            if e.compressedSize > 0, e.uncompressedSize / max(e.compressedSize, 1) > limits.maxCompressionRatio { throw IPAValidationError.ratioExceeded }
            return try Self.inflate(raw, offset: offset, length: want, declared: e.uncompressedSize)
        default:
            throw IPAValidationError.decompressionFailed
        }
    }

    static func inflate(_ raw: Data, offset: UInt64, length: UInt64, declared: UInt64) throws -> Data {
        #if canImport(Compression)
        let bufSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        let src = UnsafeMutablePointer<UInt8>.allocate(capacity: max(raw.count, 1))
        defer { dst.deallocate(); src.deallocate() }
        raw.copyBytes(to: src, count: raw.count)
        var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: src, src_size: raw.count, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw IPAValidationError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = UnsafePointer(src); stream.src_size = raw.count
        var produced: UInt64 = 0
        var out = Data()
        let end = offset + length
        while true {
            stream.dst_ptr = dst; stream.dst_size = bufSize
            let st = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let n = bufSize - stream.dst_size
            if n > 0 {
                let chunkStart = produced, chunkEnd = produced + UInt64(n)
                produced = chunkEnd
                if produced > declared { throw IPAValidationError.ratioExceeded }
                if chunkEnd > offset && chunkStart < end {
                    let from = Int(max(chunkStart, offset) - chunkStart), to = Int(min(chunkEnd, end) - chunkStart)
                    out.append(dst + from, count: to - from)
                }
            }
            if produced >= end { break }
            if st == COMPRESSION_STATUS_END { break }
            if st == COMPRESSION_STATUS_ERROR { throw IPAValidationError.decompressionFailed }
        }
        return out
        #else
        throw IPAValidationError.decompressionFailed
        #endif
    }
}

// MARK: - Mach-O inspection (bytes only, the executable is never loaded)

struct MachOInfo: Equatable { var hasArm64: Bool; var encrypted: Bool }

enum MachOInspector {
    static let cpuArm64: UInt32 = 0x0100000C
    static func u32(_ d: Data, _ o: Int, big: Bool) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        let b = (0..<4).map { UInt32(d[d.startIndex + o + $0]) }
        return big ? (b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) : (b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0])
    }

    /// Slice layout of a fat file or nil for thin. Offsets are what the caller must read next.
    static func fatSlices(_ head: Data) -> [(cpu: UInt32, offset: UInt64, size: UInt64)]? {
        guard head.count >= 8 else { return nil }
        let magic = u32(head, 0, big: true)
        guard magic == 0xCAFEBABE else { return magic == 0xCAFEBABF ? [] : nil }
        let n = Int(u32(head, 4, big: true))
        guard n > 0, n <= 16, head.count >= 8 + n * 20 else { return [] }
        return (0..<n).map { i in
            let o = 8 + i * 20
            return (u32(head, o, big: true), UInt64(u32(head, o + 8, big: true)), UInt64(u32(head, o + 12, big: true)))
        }
    }

    /// Parses one thin slice header + load commands. Throws on malformed input.
    static func inspectThin(_ d: Data) throws -> (cpu: UInt32, encrypted: Bool) {
        guard d.count >= 32 else { throw IPAValidationError.machOInvalid }
        let magic = u32(d, 0, big: false)
        guard magic == 0xFEEDFACF else { throw IPAValidationError.machOInvalid }
        let cpu = u32(d, 4, big: false)
        let ncmds = Int(u32(d, 16, big: false)), sizeofcmds = Int(u32(d, 20, big: false))
        guard ncmds <= 4096, sizeofcmds <= d.count - 32 else { throw IPAValidationError.machOInvalid }
        var off = 32, encrypted = false
        for _ in 0..<ncmds {
            guard off + 8 <= 32 + sizeofcmds else { throw IPAValidationError.machOInvalid }
            let cmd = u32(d, off, big: false), size = Int(u32(d, off + 4, big: false))
            guard size >= 8, off + size <= 32 + sizeofcmds else { throw IPAValidationError.machOInvalid }
            if cmd == 0x21 || cmd == 0x2C {   // LC_ENCRYPTION_INFO(_64)
                guard size >= 20 else { throw IPAValidationError.machOInvalid }
                if u32(d, off + 16, big: false) != 0 { encrypted = true }
            }
            off += size
        }
        return (cpu, encrypted)
    }
}

// MARK: - IPA validation

struct IPAFacts: Equatable {
    let bundleID: String
    let version: String
    let build: String?
    let displayName: String
    let minOS: String?
    let executable: String
}

enum IPAValidator {
    static let bundleIDPattern = #"^[A-Za-z0-9]([A-Za-z0-9.\-]{0,126}[A-Za-z0-9])?$"#
    static let versionPattern = #"^[A-Za-z0-9._+\-]{1,64}$"#

    /// - Parameters:
    ///   - expectedBundleID: when known (bundle-verified candidate), the plist must match it.
    ///   - expectedVersion: version the source advertised; a different version in the file fails.
    ///   - deviceOS: current iOS version string; app must not require newer.
    static func validate(data: Data, expectedBundleID: String?, expectedVersion: String?, deviceOS: String?,
                         limits: IPALimits = .standard) throws -> IPAFacts {
        let zip = try ZipReader(data: data, limits: limits)
        // exactly one Payload/<x>.app
        var apps = Set<String>()
        for e in zip.entries {
            let c = e.name.split(separator: "/", omittingEmptySubsequences: true)
            if c.count >= 2, c[0] == "Payload", c[1].hasSuffix(".app") { apps.insert(String(c[1])) }
        }
        guard !apps.isEmpty else { throw IPAValidationError.noApp }
        guard apps.count == 1, let appDir = apps.first else { throw IPAValidationError.multipleApps }
        guard let plistEntry = zip.entry("Payload/\(appDir)/Info.plist") else { throw IPAValidationError.plistMissing }
        guard plistEntry.uncompressedSize <= limits.maxPlist else { throw IPAValidationError.plistInvalid }
        let plistData = try zip.read(plistEntry, length: limits.maxPlist, limits: limits)
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let info = obj as? [String: Any] else { throw IPAValidationError.plistInvalid }

        guard let bid = info["CFBundleIdentifier"] as? String,
              bid.range(of: bundleIDPattern, options: .regularExpression) != nil else { throw IPAValidationError.badIdentifier }
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        guard version.range(of: versionPattern, options: .regularExpression) != nil else { throw IPAValidationError.badVersion }
        if let exp = expectedBundleID, !exp.isEmpty, exp.caseInsensitiveCompare(bid) != .orderedSame {
            throw IPAValidationError.bundleMismatch(expected: exp, actual: bid)
        }
        if let ev = expectedVersion, !ev.isEmpty, ev != version, ev != (info["CFBundleVersion"] as? String) {
            throw IPAValidationError.versionMismatch(expected: ev, actual: version)
        }
        let minOS = info["MinimumOSVersion"] as? String
        if let m = minOS, let d = deviceOS, m.compare(d, options: .numeric) == .orderedDescending {
            throw IPAValidationError.minOSTooHigh(m)
        }
        guard let exeName = info["CFBundleExecutable"] as? String, ZipReader.isSafePath(exeName), !exeName.contains("/"),
              let exe = zip.entry("Payload/\(appDir)/\(exeName)"), exe.uncompressedSize <= limits.maxExecutable
        else { throw IPAValidationError.executableMissing }

        // Mach-O: read just headers.
        let head = try zip.read(exe, length: 4096, limits: limits)
        let thin: Data
        if let slices = MachOInspector.fatSlices(head) {
            guard let arm = slices.first(where: { $0.cpu == MachOInspector.cpuArm64 }) else { throw IPAValidationError.notArm64 }
            guard arm.offset + arm.size <= exe.uncompressedSize else { throw IPAValidationError.machOInvalid }
            thin = try zip.read(exe, offset: arm.offset, length: min(arm.size, 256 * 1024), limits: limits)
        } else {
            thin = try zip.read(exe, length: 256 * 1024, limits: limits)
        }
        let m = try MachOInspector.inspectThin(thin)
        guard m.cpu == MachOInspector.cpuArm64 else { throw IPAValidationError.notArm64 }
        if m.encrypted { throw IPAValidationError.encrypted }

        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bid
        return IPAFacts(bundleID: bid, version: version, build: info["CFBundleVersion"] as? String,
                        displayName: name, minOS: minOS, executable: exeName)
    }

    static func validate(file: URL, expectedBundleID: String?, expectedVersion: String?, deviceOS: String?,
                         limits: IPALimits = .standard) throws -> IPAFacts {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attrs[.size] as? NSNumber)?.uint64Value, size <= limits.maxFileSize else { throw IPAValidationError.tooLarge }
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        return try validate(data: data, expectedBundleID: expectedBundleID, expectedVersion: expectedVersion,
                            deviceOS: deviceOS, limits: limits)
    }
}
