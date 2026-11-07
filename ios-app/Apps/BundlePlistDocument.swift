import Foundation

/// Typed plist editing that preserves the original serialization (xml / binary) and value types.
struct PlistDocument {
    enum Key: Equatable { case key(String), index(Int) }
    private(set) var root: Any
    let format: PropertyListSerialization.PropertyListFormat

    init(data: Data) throws {
        guard data.count <= BundleLimits.maxPlistBytes else { throw BundleFileError.tooLarge(data.count) }
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        do { root = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &fmt) }
        catch { throw BundleFileError.invalidPlist(error.localizedDescription) }
        guard fmt == .xml || fmt == .binary else { throw BundleFileError.invalidPlist("unsupported format") }
        format = fmt
        try Self.checkDepth(root, 0)
    }
    /// Edit as XML text, then re-serialize in the ORIGINAL format.
    init(xmlText: String, preserving format: PropertyListSerialization.PropertyListFormat) throws {
        let d = Data(xmlText.utf8)
        guard d.count <= BundleLimits.maxPlistBytes else { throw BundleFileError.tooLarge(d.count) }
        var f = PropertyListSerialization.PropertyListFormat.xml
        do { root = try PropertyListSerialization.propertyList(from: d, options: [.mutableContainersAndLeaves], format: &f) }
        catch { throw BundleFileError.invalidPlist(error.localizedDescription) }
        self.format = format
        try Self.checkDepth(root, 0)
    }
    static func checkDepth(_ v: Any, _ depth: Int) throws {
        if depth > BundleLimits.maxPlistDepth { throw BundleFileError.invalidPlist("nesting too deep") }
        if let d = v as? [String: Any] { for x in d.values { try checkDepth(x, depth + 1) } }
        else if let a = v as? [Any] { for x in a { try checkDepth(x, depth + 1) } }
    }
    func serialized() throws -> Data {
        guard PropertyListSerialization.propertyList(root, isValidFor: format) else { throw BundleFileError.invalidPlist("not serializable") }
        let d = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        guard d.count <= BundleLimits.maxPlistBytes else { throw BundleFileError.tooLarge(d.count) }
        return d
    }
    func xmlText() throws -> String {
        let d = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        return String(decoding: d, as: UTF8.self)
    }

    static func typeName(_ v: Any) -> String {
        if v is [String: Any] { return "dictionary" }
        if v is [Any] { return "array" }
        if v is Data { return "data" }
        if v is Date { return "date" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "bool" }
            return CFNumberIsFloatType(n) ? "real" : "integer"
        }
        return v is String ? "string" : "unknown"
    }
    func value(at path: [Key]) -> Any? {
        var cur: Any = root
        for k in path {
            switch k {
            case let .key(s): guard let d = cur as? [String: Any], let n = d[s] else { return nil }; cur = n
            case let .index(i): guard let a = cur as? [Any], a.indices.contains(i) else { return nil }; cur = a[i]
            }
        }
        return cur
    }
    static func parse(_ text: String, as type: String) throws -> Any {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "string": return text
        case "bool":
            switch t.lowercased() { case "true", "yes", "1": return true; case "false", "no", "0": return false
            default: throw BundleFileError.typeMismatch(expected: "bool") }
        case "integer": guard let i = Int(t) else { throw BundleFileError.typeMismatch(expected: "integer") }; return i
        case "real": guard let d = Double(t), d.isFinite else { throw BundleFileError.typeMismatch(expected: "real") }; return d
        case "date": guard let d = ISO8601DateFormatter().date(from: t) else { throw BundleFileError.typeMismatch(expected: "date (ISO 8601)") }; return d
        case "data": guard let d = Data(base64Encoded: t) else { throw BundleFileError.typeMismatch(expected: "data (base64)") }; return d
        default: throw BundleFileError.typeMismatch(expected: "scalar")
        }
    }
    /// Replace a scalar keeping its existing type; text that does not parse as that type is rejected.
    mutating func setScalar(at path: [Key], text: String) throws {
        guard let old = value(at: path) else { throw BundleFileError.notFound("plist path") }
        let type = Self.typeName(old)
        guard !["dictionary", "array", "unknown"].contains(type) else { throw BundleFileError.typeMismatch(expected: "scalar") }
        try replace(at: path, with: Self.parse(text, as: type))
    }
    /// Add a new key / append with an explicit type.
    mutating func add(at container: [Key], key: String?, type: String, text: String) throws {
        let v: Any
        switch type { case "dictionary": v = [String: Any](); case "array": v = [Any](); default: v = try Self.parse(text, as: type) }
        guard let c = value(at: container) else { throw BundleFileError.notFound("plist path") }
        if var d = c as? [String: Any] {
            guard let key, !key.isEmpty else { throw BundleFileError.invalidPath("key") }
            guard d[key] == nil else { throw BundleFileError.alreadyExists(key) }
            d[key] = v; try replace(at: container, with: d)
        } else if var a = c as? [Any] { a.append(v); try replace(at: container, with: a) }
        else { throw BundleFileError.typeMismatch(expected: "container") }
    }
    mutating func remove(at path: [Key]) throws {
        guard let last = path.last else { throw BundleFileError.invalidPath("root") }
        let parent = Array(path.dropLast())
        guard let c = value(at: parent) else { throw BundleFileError.notFound("plist path") }
        switch last {
        case let .key(k): guard var d = c as? [String: Any], d[k] != nil else { throw BundleFileError.notFound(k) }; d[k] = nil; try replace(at: parent, with: d)
        case let .index(i): guard var a = c as? [Any], a.indices.contains(i) else { throw BundleFileError.notFound("index") }; a.remove(at: i); try replace(at: parent, with: a)
        }
    }
    private mutating func replace(at path: [Key], with new: Any) throws {
        func go(_ cur: Any, _ rest: ArraySlice<Key>) throws -> Any {
            guard let k = rest.first else { return new }
            switch k {
            case let .key(s):
                guard var d = cur as? [String: Any], let child = d[s] else { throw BundleFileError.notFound(s) }
                d[s] = try go(child, rest.dropFirst()); return d
            case let .index(i):
                guard var a = cur as? [Any], a.indices.contains(i) else { throw BundleFileError.notFound("index") }
                a[i] = try go(a[i], rest.dropFirst()); return a
            }
        }
        let updated = try go(root, path[...])
        try Self.checkDepth(updated, 0)
        root = updated
    }
}

/// Extra guardrails for the app's Info.plist; returns blocking errors and soft warnings.
enum InfoPlistGuard {
    static func check(_ doc: PlistDocument, originalExecutable: String?) -> (errors: [String], warnings: [String]) {
        var e: [String] = [], w: [String] = []
        guard let d = doc.root as? [String: Any] else { return (["Info.plist root must be a dictionary."], []) }
        for k in ["CFBundleIdentifier", "CFBundleExecutable"] {
            if !(d[k] is String) || (d[k] as? String)?.isEmpty == true { e.append("\(k) must be a non-empty string.") }
        }
        if let o = originalExecutable, let n = d["CFBundleExecutable"] as? String, n != o {
            e.append("CFBundleExecutable must stay \"\(o)\"; the executable is not renamed.")
        }
        if d["CFBundleVersion"] != nil && !(d["CFBundleVersion"] is String) { w.append("CFBundleVersion should be a string.") }
        if d["CFBundleShortVersionString"] != nil && !(d["CFBundleShortVersionString"] is String) { w.append("CFBundleShortVersionString should be a string.") }
        if d["MinimumOSVersion"] != nil && !(d["MinimumOSVersion"] is String) { w.append("MinimumOSVersion should be a string.") }
        w.append("Changing the bundle identifier can break entitlements, App Groups and keychain access.")
        return (e, w)
    }
}
