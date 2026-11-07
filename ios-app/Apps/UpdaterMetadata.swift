import Foundation

/// Numeric bundle versions only. Never flatten tags or guess from marketing versions.
enum UpdaterMetadata {
    static func components(_ value: String) -> [UInt64]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var result: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let n = UInt64(part) else { return nil }
            result.append(n)
        }
        return result + Array(repeating: 0, count: 3 - result.count)
    }
    static func isNewer(remote: String?, installed: String?) -> Bool {
        guard let remote, let installed, let a = components(remote), let b = components(installed) else { return false }
        return a.lexicographicallyPrecedes(b) == false && a != b
    }
    struct Notes: Decodable {
        let releaseNotes: [String: String]?
    }
    static func notes(body: String?, language: String) -> String? {
        guard let data = body?.data(using: .utf8),
              let notes = try? JSONDecoder().decode(Notes.self, from: data).releaseNotes else { return nil }
        // Do not show English commit subjects as an Arabic changelog.
        let locale = language.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        guard let value = notes[locale]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
