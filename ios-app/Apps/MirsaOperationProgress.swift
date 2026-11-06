import Foundation
import Combine

/// Ephemeral UI state only. Never supplies invented percentages or app identities.
@MainActor
final class MirsaOperationProgress: ObservableObject {
    enum Phase: String { case downloading, preparing, signing, installing, updating }
    struct Entry: Identifiable, Equatable {
        let id: UUID
        var appID: String?
        var phase: Phase
        var fraction: Double?
        var canCancel: Bool
    }
    static let shared = MirsaOperationProgress()
    @Published private(set) var entries: [UUID: Entry] = [:]
    private var cancellations: [UUID: () -> Void] = [:]

    @discardableResult
    func begin(appID: String? = nil, phase: Phase, cancel: (() -> Void)? = nil) -> UUID {
        let id = UUID()
        entries[id] = Entry(id: id, appID: appID, phase: phase, fraction: nil,
                            canCancel: phase == .downloading && cancel != nil)
        if phase == .downloading { cancellations[id] = cancel }
        return id
    }

    func entry(for appID: String) -> Entry? {
        entries.values.first { $0.appID == appID }
    }

    /// Call only with a known managed ID or metadata validated from the archive.
    func associate(_ id: UUID, appID: String) {
        guard var value = entries[id] else { return }
        value.appID = appID
        entries[id] = value
    }

    func update(_ id: UUID, phase: Phase, fraction: Double? = nil) {
        guard var value = entries[id] else { return }
        value.phase = phase
        value.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        if phase != .downloading { cancellations[id] = nil; value.canCancel = false }
        entries[id] = value
    }

    func finish(_ id: UUID) { entries[id] = nil; cancellations[id] = nil }

    func cancel(_ id: UUID) {
        guard entries[id]?.canCancel == true, let action = cancellations[id] else { return }
        finish(id)
        action()
    }
}
