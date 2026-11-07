import SwiftUI

/// Self-contained file browser for an extracted bundle. Embed with:
/// BundleFileBrowserView(manager: m, onChange: { persist(m.overlay) })
struct BundleFileBrowserView: View {
    let manager: BundleFileManager
    var directory: String = ""
    var onChange: () -> Void = {}
    @State private var entries: [BundleEntry] = []
    @State private var error: String?
    @State private var confirmDelete: BundleEntry?
    @State private var renaming: BundleEntry?
    @State private var newName = ""
    @State private var importing = false
    @State private var revision = 0

    var body: some View {
        List {
            if !manager.overlay.isEmpty {
                Section("Staged (applied at signing)") {
                    ForEach(Array(manager.overlay.ops.enumerated()), id: \.offset) { i, op in
                        Text(op.summary).font(.footnote)
                            .swipeActions { Button("Undo") { manager.unstage(at: i); reload() }.tint(.orange) }
                    }
                }
            }
            Section(directory.isEmpty ? "App bundle" : directory) {
                ForEach(entries) { e in row(e) }
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle(directory.isEmpty ? "Files" : BundlePath.lastComponent(directory))
        .toolbar { Button { importing = true } label: { Image(systemName: "square.and.arrow.down") } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            run { try manager.stageImport(from: url, intoDirectory: directory) }
        }
        .alert("Delete?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete when signing", role: .destructive) { if let e = confirmDelete { run { try manager.stageDelete(e.path) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The original bundle is not changed. This is only applied to the signing copy.") }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let e = renaming { run { try manager.stageRename(e.path, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder private func row(_ e: BundleEntry) -> some View {
        let reason = manager.protectedReason(e.path)
        Group {
            switch e.kind {
            case .directory:
                NavigationLink { BundleFileBrowserView(manager: manager, directory: e.path, onChange: onChange) } label: { Label(e.name, systemImage: "folder") }
            case .plist, .text:
                NavigationLink { BundleFileEditorView(manager: manager, entry: e, onChange: { onChange(); reload() }) } label: {
                    Label(e.name, systemImage: e.kind == .plist ? "list.bullet.rectangle" : "doc.text") }
            case .binary:
                Label { Text(e.name); Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) } icon: { Image(systemName: "doc") }
            }
        }
        .swipeActions {
            if reason == nil {
                Button("Delete", role: .destructive) { confirmDelete = e }
                Button("Rename") { newName = e.name; renaming = e }.tint(.blue)
            } else { Button("Protected") { error = reason }.tint(.gray) }
        }
    }
    private func run(_ work: () throws -> Void) {
        do { try work(); error = nil; onChange() } catch { self.error = String(describing: error) }
        reload()
    }
    private func reload() {
        do { entries = try manager.list(directory) } catch { self.error = String(describing: error) }
    }
}

struct BundleFileEditorView: View {
    let manager: BundleFileManager
    let entry: BundleEntry
    var onChange: () -> Void = {}
    @State private var text = ""
    @State private var format: PropertyListSerialization.PropertyListFormat = .xml
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            if entry.kind == .plist { Text(format == .binary ? "Binary plist (saved as binary, shown as XML)" : "XML plist").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
            if let message { Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
        }
        .navigationTitle(entry.name)
        .toolbar { Button("Stage") { save() } }
        .onAppear(perform: load)
    }
    private func load() {
        do {
            switch try manager.read(entry.path) {
            case let .plist(d): format = d.format; text = try d.xmlText()
            case let .text(t): text = t
            default: message = "Not editable."
            }
        } catch { message = String(describing: error) }
    }
    private func save() {
        do {
            if entry.kind == .plist { try manager.stageWrite(entry.path, plist: try PlistDocument(xmlText: text, preserving: format)) }
            else { try manager.stageWrite(entry.path, text: text) }
            onChange(); dismiss()
        } catch { message = String(describing: error) }
    }
}
