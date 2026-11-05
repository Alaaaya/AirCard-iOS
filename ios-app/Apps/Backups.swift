import Foundation
import SwiftUI

// MARK: - Container app data backups
//
// Backups live in Documents/Backups/<bundle id>/<date>.zip, so they also show
// in the Files app under Mirsa. One is made automatically before an app is
// updated or deleted; the newest few per app are kept.

struct DataBackup: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let size: Int64
}

extension AppsStore {
    static let keepBackups = 5

    static var backupsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
    }

    static func backupDir(_ id: String) -> URL { backupsRoot.appendingPathComponent(id, isDirectory: true) }

    func backups(for app: ManagedApp) -> [DataBackup] {
        let fm = FileManager.default
        let dir = Self.backupDir(app.id)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "zip" }.map { u in
            let v = try? u.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return DataBackup(url: u, date: v?.creationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    /// Zips the app's data folder. Returns nil when there is nothing to back up.
    @discardableResult
    func backupData(_ app: ManagedApp, quiet: Bool = false) async -> URL? {
        let fm = FileManager.default
        let data = Self.dataDir(app.id)
        guard let items = try? fm.contentsOfDirectory(atPath: data.path), !items.isEmpty else {
            if !quiet { error = tr("This app has no data yet.", "هالتطبيق ما عنده بيانات لسا.") }
            return nil
        }
        if !quiet { busy = tr("Backing up…", "عم ياخد نسخة…") }
        defer { if !quiet { busy = nil } }
        let dir = Self.backupDir(app.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dest = dir.appendingPathComponent("\(app.name)_\(f.string(from: Date())).zip")

        let result: Result<Void, Error> = await Task.detached {
            var coordError: NSError?
            var copyError: Error?
            // Asking the coordinator to read a folder "for uploading" hands back a zip of it.
            NSFileCoordinator().coordinate(readingItemAt: data, options: .forUploading, error: &coordError) { zip in
                do { try FileManager.default.copyItem(at: zip, to: dest) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { return .failure(e) }
            return .success(())
        }.value

        switch result {
        case .success:
            for old in backups(for: app).dropFirst(Self.keepBackups) { try? fm.removeItem(at: old.url) }
            return dest
        case let .failure(e):
            if !quiet { error = e.localizedDescription }
            return nil
        }
    }

    /// Replaces the app's data with a backup. The current data is backed up first.
    func restoreData(_ app: ManagedApp, from backup: DataBackup) async {
        let fm = FileManager.default
        busy = tr("Restoring…", "عم يرجّع النسخة…")
        defer { busy = nil }
        await backupData(app, quiet: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ok = await Task.detached { SideloadService.unzip(backup.url.path, to: tmp.path) }.value
        guard ok else { error = tr("Couldn't open the backup.", "ما قدرت افتح النسخة."); return }
        // The zip holds one top-level folder (the data folder itself).
        let top = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let src: URL
        if top.count == 1, (try? top[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            src = top[0]
        } else {
            src = tmp
        }
        let data = Self.dataDir(app.id)
        try? fm.removeItem(at: data)
        do { try fm.moveItem(at: src, to: data) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - View

struct BackupsSheet: View {
    let app: ManagedApp
    @ObservedObject var store = AppsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var list: [DataBackup] = []
    @State private var confirm: DataBackup?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await store.backupData(app); list = store.backups(for: app) }
                    } label: { Label(tr("Back up now", "خذ نسخة هلّق"), systemImage: "externaldrive.badge.plus") }
                } footer: {
                    Text(tr("Mirsa also backs up automatically before updating or deleting the app, and keeps the last \(AppsStore.keepBackups). Backups are in Files › Mirsa › Backups.",
                            "Mirsa بياخد نسخة لحاله قبل التحديث أو الحذف، وبيحتفظ بآخر \(AppsStore.keepBackups). النسخ بتلاقيها بالملفات › Mirsa › Backups."))
                }
                if !list.isEmpty {
                    Section(tr("Backups", "النسخ")) {
                        ForEach(list) { b in
                            Button { confirm = b } label: {
                                HStack {
                                    Text(b.date.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx { try? FileManager.default.removeItem(at: list[i].url) }
                            list = store.backups(for: app)
                        }
                    }
                }
            }
            .navigationTitle(app.name)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(tr("Done", "تم")) { dismiss() } } }
            .confirmationDialog(tr("Restore this backup? The current data is backed up first.",
                                   "ترجّع هالنسخة؟ البيانات الحالية بتنحفظ أول."),
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button(tr("Restore", "رجّعها")) {
                    if let b = confirm { Task { await store.restoreData(app, from: b); list = store.backups(for: app) } }
                }
            }
            .onAppear { list = store.backups(for: app) }
            .mirsaScreen()
        }
    }
}
