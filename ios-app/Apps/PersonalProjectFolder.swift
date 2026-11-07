import Foundation
import SwiftUI
import Security

struct ProjectFolderLocation: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Files is not used as a navigator: its undocumented deep link may restore another app.
/// UUID-only directories and component-wise checks prevent symlink and traversal escape.
enum PersonalProjectFolder {
    static func directory(documents: URL, id: UUID, create: Bool = true) throws -> URL {
        let fm = FileManager.default
        try checkDirectory(documents)
        var url = documents
        for component in ["Projects", id.uuidString] {
            url.appendPathComponent(component, isDirectory: true)
            if create && !fm.fileExists(atPath: url.path) {
                // A dangling symlink must not be treated as a missing directory.
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw CocoaError(.fileReadNoPermission) }
                try fm.createDirectory(at: url, withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.complete])
            }
            try checkDirectory(url)
        }
        return url
    }

    /// Preflight every source and destination before changing user data.
    /// On failure, roll back moves without ever overwriting a collision.
    static func migrate(files: [URL], to directory: URL,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        try checkDirectory(directory)
        var planned: [(URL, URL)] = []
        for source in files {
            let attrs: [FileAttributeKey: Any]
            do { attrs = try fm.attributesOfItem(atPath: source.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { continue }
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadNoPermission) }
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            // attributesOfItem also detects dangling symlinks, unlike fileExists.
            if (try? fm.attributesOfItem(atPath: destination.path)) != nil {
                throw CocoaError(.fileWriteFileExists)
            }
            planned.append((source, destination))
        }
        var moved: [(URL, URL)] = []
        do {
            for (source, destination) in planned {
                try move(source, destination)
                moved.append((source, destination))
            }
        } catch {
            for (source, destination) in moved.reversed() {
                // If rollback is itself interrupted, the destination is retained.
                // Never delete the sole surviving copy or overwrite a new legacy file.
                if (try? fm.attributesOfItem(atPath: source.path)) == nil {
                    try? fm.moveItem(at: destination, to: source)
                }
            }
            throw error
        }
    }

    private static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
    }

    static func validated(_ candidate: URL, in root: URL) throws -> URL {
        try checkDirectory(root)
        let base = root.standardizedFileURL.pathComponents
        let parts = candidate.standardizedFileURL.pathComponents
        guard parts.count >= base.count, Array(parts.prefix(base.count)) == base,
              candidate.pathComponents == candidate.standardizedFileURL.pathComponents else { throw CocoaError(.fileReadNoPermission) }
        var current = root
        for part in parts.dropFirst(base.count) {
            current.appendPathComponent(part)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        }
        let resolvedBase = root.resolvingSymlinksInPath().pathComponents
        let resolved = candidate.resolvingSymlinksInPath().pathComponents
        guard Array(resolved.prefix(resolvedBase.count)) == resolvedBase else { throw CocoaError(.fileReadNoPermission) }
        return candidate
    }

    static func contents(of directory: URL, in root: URL) throws -> [URL] {
        let directory = try validated(directory, in: root)
        try checkDirectory(directory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { (try? validated($0, in: root)) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

enum PersonalCertificateLabel {
    /// Decode the already-selected leaf DER, not the RFC4514 display DN.
    /// Security handles escaped commas, multi-valued RDNs and Unicode.
    static func name(certificate: Data?) -> String {
        guard let certificate,
              let cert = SecCertificateCreateWithData(nil, certificate as CFData) else { return fallback }
        var value: CFString?
        guard SecCertificateCopyCommonName(cert, &value) == errSecSuccess,
              let value else { return fallback }
        let clean = (value as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }
    static var fallback: String { personalText("Personal certificate", "شهادة شخصية") }
}

struct PersonalProjectFolderBrowser: View {
    let root: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ProjectFolderContents(root: root, directory: root)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(personalText("Close", "إغلاق")) { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct ProjectFolderContents: View {
    let root: URL
    let directory: URL
    @State private var files: [URL] = []
    @State private var error: String?
    @State private var shared: ProjectFolderLocation?
    var body: some View {
        List {
            Section {
                Label("Mirsa / Projects / " + root.lastPathComponent, systemImage: "folder.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let error {
                Text(error).foregroundStyle(.orange)
            } else if files.isEmpty {
                Text(personalText("This project folder is empty.", "مجلد هالمشروع فاضي."))
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { file in
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    NavigationLink {
                        ProjectFolderContents(root: root, directory: file).navigationTitle(file.lastPathComponent)
                    } label: {
                        Label(file.lastPathComponent, systemImage: "folder")
                    }
                } else {
                    Button {
                        do {
                            shared = ProjectFolderLocation(url: try PersonalProjectFolder.validated(file, in: root))
                        } catch { self.error = personalText("Cannot open this file.", "ما قدرنا نفتح هالملف.") }
                    } label: {
                        HStack {
                            Label(file.lastPathComponent, systemImage: "doc")
                                .foregroundStyle(.primary).lineLimit(2)
                            Spacer()
                            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .task {
            do { files = try PersonalProjectFolder.contents(of: directory, in: root); error = nil }
            catch { self.error = personalText("Could not read this project folder.", "ما قدرنا نقرأ مجلد هالمشروع.") }
        }
        .sheet(item: $shared) { location in PersonalSignedShare(url: location.url) }
    }
}
