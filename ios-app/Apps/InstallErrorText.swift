import Foundation

/// One presentation boundary for install, renewal and signing diagnostics.
/// Keep the useful stage/OS reason, not Rust source locations or sandbox paths.
enum InstallErrorText {
    static func sanitize(_ raw: String, arabic: Bool) -> String {
        if raw == "MIRSA_SOURCE_IPA_MISSING" {
            return arabic ? "ملف التطبيق مو موجود، نزّله من جديد" : "The app file is missing. Download it again."
        }
        var text = raw
        // Rootcause appends a compiler-machine source location after the cause.
        text = text.replacingOccurrences(of: #"(?m)^\s*(?:at\s+)?/[^\n]+\.rs:\d+(?::\d+)?\s*$"#,
                                         with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![A-Za-z0-9:])/(?:[^\s\x22'<>\[\]()]+)"#,
                                         with: "[path]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b[A-Za-z]:\\[^\s\x22'<>]+"#,
                                         with: "[path]", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return arabic ? "ما اكتملت العملية. جرّب من جديد." : "The operation did not complete. Try again." }
        if arabic {
            let stages = [
                ("Install failed:", "ما اكتمل تثبيت التطبيق"),
                ("Signing failed:", "ما اكتمل توقيع التطبيق"),
                ("Preparing app archive:", "ما اكتمل تجهيز ملف التطبيق"),
                ("Preparing extracted app:", "ما اكتمل تجهيز ملفات التطبيق"),
                ("Preparing install workspace:", "ما اكتمل تجهيز مجلد التثبيت"),
                ("Preparing app snapshot:", "ما اكتمل تجهيز نسخة التثبيت"),
                ("Reading source app:", "ما اكتملت قراءة ملف التطبيق"),
                ("Saving app snapshot:", "ما اكتمل حفظ نسخة التثبيت"),
                ("Publishing app snapshot:", "ما اكتمل تجهيز نسخة التثبيت")
            ]
            for (prefix, localized) in stages where text.hasPrefix(prefix) {
                text = localized + "، " + text.dropFirst(prefix.count()).trimmingCharacters(in: .whitespaces)
                break
            }
            text = text.replacingOccurrences(of: "No such file or directory", with: "ملف أو مجلد مؤقت مو متاح")
        }
        return text
    }
}
