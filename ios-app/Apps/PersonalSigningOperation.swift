import Foundation
import SwiftUI
import UIKit

/// Shared operation lifetime is independent of the project view's navigation.
@MainActor
final class PersonalSigningOperation: ObservableObject {
    static let shared = PersonalSigningOperation()
    enum Stage: String {
        case preparing, signing, packaging, connecting, installing, completed, failed
        var order: Int {
            switch self {
            case .preparing: return 0
            case .signing: return 1
            case .packaging: return 2
            case .connecting: return 3
            case .installing: return 4
            case .completed, .failed: return 5
            }
        }
    }
    struct State {
        let id: UUID
        let projectID: UUID
        var stage: Stage = .preparing
        var fraction: Double?
        var completedUnits: UInt64 = 0
        var totalUnits: UInt64 = 0
        var running = true
        var backgroundExpired = false
        var result: PersonalCertificateSigner.Result?
        var error: String?
        /// Main-actor callbacks can be enqueued out of order. Do not regress a
        /// measured stage or republish unchanged progress on every backend tick.
        @discardableResult
        mutating func apply(_ event: PersonalSigningEvent) -> Bool {
            guard running, event.stage.order >= stage.order else { return false }
            let sameStage = stage == event.stage
            let nextFraction: Double?
            if sameStage, let current = fraction {
                nextFraction = max(current, event.fraction ?? current)
            } else { nextFraction = event.fraction }
            let nextCompleted = sameStage ? max(completedUnits, event.completed) : event.completed
            guard stage != event.stage || fraction != nextFraction ||
                    completedUnits != nextCompleted || totalUnits != event.total else { return false }
            stage = event.stage; fraction = nextFraction
            completedUnits = nextCompleted; totalUnits = event.total
            return true
        }
    }
    @Published private(set) var state: State?
    init(initialState: State? = nil) { state = initialState }
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid
    private var control: PersonalSigningControl?
    private var activityID: String?
    var running: Bool { state?.running == true }

    func start(projectID: UUID, title: String, input: URL, material: PersonalIdentityVault.Material,
               pairingPath: String, options: PersonalProjectOptions) {
        guard !running else { return }
        if let previous = state?.result?.url {
            try? FileManager.default.removeItem(at: previous.deletingLastPathComponent())
        }
        let id = UUID()
        let control = PersonalSigningControl()
        self.control = control
        lastActivityStage = nil
        state = State(id: id, projectID: projectID)
        let operation = MirsaOperationProgress.shared.begin(appID: projectID.uuidString, phase: .preparing)
        activityID = MirsaInstallActivity.shared.begin(title: title, phase: .preparing)
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Mirsa signing and installation") { [weak self] in
            // UIKit invokes this handler on the main thread. End the grant
            // before the expiration handler returns, not in a later queued task.
            MainActor.assumeIsolated { self?.expire(id: id) }
        }
        // Deliberately NOT attached to SwiftUI .task; leaving the screen cannot cancel it.
        Task {
            do {
                if MirsaInstallMode.ownCertificate {
                    _ = try OwnCertificateDevice.require()
                    let staged = try CertificateInstall.stageSignedApp(ipa:input,in:FileManager.default.temporaryDirectory)
                    defer { try? FileManager.default.removeItem(at:staged.stage) }
                    try await CertificateOTA.install(source:staged.app)
                    self.state?.running = false
                    self.state?.stage = .completed
                    self.state?.error = "تم فتح مثبّت iOS. هاد مو تأكيد نجاح التثبيت."
                    self.finishActivity(success:true)
                    MirsaOperationProgress.shared.finish(operation)
                    self.endBackgroundTime()
                    self.control = nil
                    return
                }
                let result = try await Task.detached(priority: .userInitiated) {
                    try PersonalCertificateSigner.sign(ipa: input, material: material, pairingPath: pairingPath,
                        options: options, install: true, control: control) { event in
                            Task { @MainActor [weak self] in self?.receive(event, id: id, operation: operation) }
                        }
                }.value
                guard self.state?.id == id else { return }
                self.state?.result = result
                self.state?.stage = result.installed ? .completed : .failed
                self.state?.fraction = result.installed ? 1 : nil
                self.state?.error = result.installError
                self.state?.running = false
                self.finishActivity(success: result.installed)
                MirsaCompletionFeedback.shared.finish(operationID: operation, outcome: result.installed ? .success : .failure)
            } catch {
                guard self.state?.id == id else { return }
                self.state?.stage = .failed
                self.state?.fraction = nil
                self.state?.error = error.localizedDescription
                self.state?.running = false
                self.finishActivity(success: false)
                MirsaCompletionFeedback.shared.finish(operationID: operation, outcome: MirsaCompletionFeedback.outcome(for: error))
            }
            MirsaOperationProgress.shared.finish(operation)
            self.endBackgroundTime()
            self.control = nil
        }
    }

    private func receive(_ event: PersonalSigningEvent, id: UUID, operation: UUID) {
        guard var next = state, next.id == id, next.apply(event) else { return }
        state = next
        let phase: MirsaOperationProgress.Phase
        let activity: MirsaInstallActivity.Phase
        switch event.stage {
        case .signing: phase = .signing; activity = .signing
        case .installing, .connecting: phase = .installing; activity = .installing
        default: phase = .preparing; activity = .preparing
        }
        MirsaOperationProgress.shared.update(operation, phase: phase, fraction: next.fraction)
        // Do not overwrite another download's activity if that operation replaced ours.
        guard let activityID, MirsaInstallActivity.shared.operationID == activityID else { return }
        // Reset percentage only at a real stage transition.
        if lastActivityStage != event.stage {
            lastActivityStage = event.stage
            MirsaInstallActivity.shared.setPhase(activity)
        }
        if let fraction = next.fraction { MirsaInstallActivity.shared.updateProgress(fraction) }
    }
    private func finishActivity(success: Bool) {
        if let activityID, MirsaInstallActivity.shared.operationID == activityID {
            MirsaInstallActivity.shared.finish(success: success)
        }
        activityID = nil
    }
    private var lastActivityStage: Stage?
    private func expire(id: UUID) {
        guard state?.id == id, running else { return }
        control?.cancel()
        state?.backgroundExpired = true
        // No promise of unlimited execution. Current blocking install may settle only
        // after foregrounding; we never announce failure/success before its actual result.
        endBackgroundTime()
    }
    private func endBackgroundTime() {
        guard backgroundID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundID)
        backgroundID = .invalid
    }
}

struct PersonalSigningEvent {
    static func installation(_ fraction: Double, stage: String) -> PersonalSigningEvent? {
        guard stage == "Installing", fraction.isFinite else { return nil }
        return PersonalSigningEvent(stage: .installing, fraction: min(0.99, max(0, fraction)))
    }
    static func signing(completed: UInt64, total: UInt64) -> PersonalSigningEvent {
        PersonalSigningEvent(stage: .signing, fraction: total > 0 ? min(1, Double(completed) / Double(total)) : nil,
                             completed: completed, total: total)
    }
    let stage: PersonalSigningOperation.Stage
    var fraction: Double? = nil
    var completed: UInt64 = 0
    var total: UInt64 = 0
}
/// Shared only for cooperative cancellation checks, never secrets or file paths.
final class PersonalSigningControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func checkpoint() throws {
        if isCancelled { throw SideloadError.message("انتهى وقت الخلفية. افتح Mirsa وجرّب التوقيع من جديد.") }
    }
}

struct PersonalSigningProgressView: View {
    let state: PersonalSigningOperation.State
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.stage == .installing ? "iphone.and.arrow.forward" : "signature")
                Text(label).fontWeight(.semibold)
                Spacer()
                if let fraction = state.fraction {
                    Text("\(Int(fraction * 100))%").monospacedDigit().fontWeight(.bold)
                }
            }
            if let fraction = state.fraction {
                ProgressView(value: fraction).tint(.green).accessibilityValue("\(Int(fraction * 100))%")
            } else {
                HStack(spacing: 8) { ProgressView(); Text(personalText("Waiting for measured progress", "بانتظار تقدّم فعلي")).font(.caption) }
            }
            if state.stage == .signing, state.totalUnits > 0 {
                Text(personalText("Signed bundles", "الحزم الموقّعة") + " \(state.completedUnits)/\(state.totalUnits)").font(.caption).foregroundStyle(.secondary)
            }
            if state.backgroundExpired {
                Text(personalText("Background time ended. Keep Mirsa open to see the result.",
                    "خلص وقت الخلفية. افتح Mirsa لتشوف النتيجة.")).font(.caption).foregroundStyle(.orange)
            }
        }.accessibilityIdentifier("personalSigningProgress")
    }
    private var label: String {
        switch state.stage {
        case .preparing: return personalText("Preparing", "تجهيز")
        case .signing: return personalText("Signing", "توقيع")
        case .packaging: return personalText("Exporting signed IPA", "تجهيز الـ IPA الموقّع")
        case .connecting: return personalText("Connecting to device", "اتصال بالجهاز")
        case .installing: return personalText("Installing", "تثبيت")
        case .completed: return personalText("Signed and installed", "تم التوقيع والتثبيت")
        case .failed: return personalText("Not completed", "ما اكتملت العملية")
        }
    }
}
