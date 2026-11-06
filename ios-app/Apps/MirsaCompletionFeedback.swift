import Foundation
import UIKit
import AVFoundation

/// The caller supplies one token for one logical operation, not each intermediate phase.
@MainActor
final class MirsaCompletionFeedback {
    enum Outcome { case success, failure, cancelled }
    static let shared = MirsaCompletionFeedback()
    static let enabledKey = "mirsa.completionFeedback.enabled"
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    private var completed = Set<UUID>()
    private var order: [UUID] = []
    private var player: AVAudioPlayer?

    func finish(operationID: UUID, outcome: Outcome) {
        guard completed.insert(operationID).inserted else { return }
        order.append(operationID)
        if order.count > 256 { completed.remove(order.removeFirst()) }
        guard enabled, UIApplication.shared.applicationState == .active else { return }
        switch outcome {
        case .cancelled: return
        case .failure:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .success:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
            playSoftTone()
        }
    }

    static func outcome(for error: Error) -> Outcome {
        error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failure
    }

    private func playSoftTone() {
        // Ambient is mixed with other audio and obeys the hardware silent switch.
        // Do not replace an unrelated active playback/recording session.
        let session = AVAudioSession.sharedInstance()
        guard session.category == .soloAmbient || session.category == .ambient else { return }
        do {
            try session.setCategory(.ambient, mode: .default)
            player = try AVAudioPlayer(data: Self.tone)
            player?.volume = 0.18
            player?.play()
        } catch { /* Optional feedback must never affect the operation. */ }
    }

    private static let tone: Data = {
        let rate = 22_050
        let count = 2_646
        var samples = Data()
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let envelope = sin(Double.pi * Double(i) / Double(count))
            var sample = Int16(sin(2 * Double.pi * 880 * t) * envelope * envelope * 5_000).littleEndian
            withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
        }
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples.count)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(samples.count)); data.append(samples)
        return data
    }()
}
