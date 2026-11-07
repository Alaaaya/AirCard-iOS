import Foundation

/// Interface presence is a preflight hint, never proof of a successful pairing.
/// The transport still authenticates the pairing file and establishes the session.
enum DeviceConnectionPolicy {
    static func mayAttempt(tunnelRoute: Bool, hasPairing: Bool) -> Bool {
        tunnelRoute && hasPairing
    }
}

struct DeviceConnectionFailure: Equatable {
    let stage: String
    let kind: String
    let domain: String
    let code: String
    let endpoint: String

    init?(_ raw: String) {
        guard let start = raw.range(of: "MIRSA_CONNECTION|") else { return nil }
        let fields = raw[start.upperBound...].split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5 else { return nil }
        let values = fields.map(String.init)
        guard ["pairing", "connect"].contains(values[0]),
              ["pairing_rejected", "permission", "timeout", "route_unreachable", "heartbeat", "transport"].contains(values[1]),
              ["POSIX", "transport"].contains(values[2]),
              (values[3] == "unknown" || (values[3].count <= 5 && UInt16(values[3]) != nil)),
              ["unreported", "10.7.0.1:49152", "172.16.0.1:49152", "10.7.0.1:62078", "172.16.0.1:62078"].contains(values[4])
        else { return nil }
        stage = values[0]; kind = values[1]; domain = values[2]; code = values[3]; endpoint = values[4]
    }

    func message(arabic: Bool) -> String {
        let en: String
        let ar: String
        switch kind {
        case "pairing_rejected":
            en = "The pairing record is invalid or was rejected. Import a new pairing file for this iPhone."
            ar = "ملف الاقتران غير صالح أو انرفض. استورد ملف اقتران جديد لهالآيفون."
        case "permission":
            en = "iOS denied the connection. Check Mirsa's Local Network permission in Settings."
            ar = "النظام رفض الاتصال. تأكد من إذن الشبكة المحلية لمرسا بالإعدادات."
        case "timeout":
            en = "The device connection timed out. Check LocalDevVPN and try again. This does not prove the pairing file is invalid."
            ar = "انتهت مهلة الاتصال بالجهاز. تأكد من LocalDevVPN وجرّب مرة تانية. هاد مو دليل إن ملف الاقتران غلط."
        case "route_unreachable":
            en = "The device route is unreachable. Check LocalDevVPN and retry."
            ar = "مسار الاتصال بالجهاز مو متاح. تأكد من LocalDevVPN وجرّب مرة تانية."
        case "heartbeat":
            en = "The device heartbeat failed. This can be a routing or pairing issue; try Wi-Fi to compare."
            ar = "فشل اتصال نبض الجهاز. ممكن تكون المشكلة بالمسار أو الاقتران؛ جرّب الواي فاي للمقارنة."
        default:
            en = "The device connection failed. The cause is not yet known."
            ar = "فشل الاتصال بالجهاز. السبب لسه مو معروف."
        }
        // All fields are fixed labels or bounded numbers, never raw error content.
        return (arabic ? ar : en) + "\n[\(stage) / \(kind) / \(domain) / \(code) / \(endpoint)]"
    }
}
