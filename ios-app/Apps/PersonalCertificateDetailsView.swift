import SwiftUI
import CoreFoundation
import UIKit

/// Shows locally decoded profile values, not an online revocation verdict.
struct PersonalCertificateDetailsView: View {
    let identity: PersonalIdentityVault.SavedIdentity
    private struct Capability {
        let key: String
        let name: String
        let explanation: String
    }
    private var groups: [(String, [Capability])] {
        [
            (personalText("Identity & security", "الهوية والأمان"), [
                .init(key: "application-identifier", name: personalText("Application identifier", "معرّف التطبيق"), explanation: personalText("Profile application scope", "نطاق التطبيقات بالبروفايل")),
                .init(key: "com.apple.developer.team-identifier", name: personalText("Developer team", "فريق المطوّر"), explanation: ""),
                .init(key: "keychain-access-groups", name: personalText("Keychain groups", "مجموعات سلسلة المفاتيح"), explanation: "")]),
            (personalText("Services & sharing", "الخدمات والمشاركة"), [
                .init(key: "aps-environment", name: personalText("Push notifications", "الإشعارات"), explanation: ""),
                .init(key: "com.apple.security.application-groups", name: personalText("App groups", "مجموعات التطبيقات"), explanation: ""),
                .init(key: "com.apple.developer.associated-domains", name: personalText("Associated domains", "النطاقات المرتبطة"), explanation: ""),
                .init(key: "com.apple.developer.icloud-services", name: "iCloud", explanation: ""),
                .init(key: "com.apple.developer.networking.networkextension", name: personalText("Network extensions", "إضافات الشبكة"), explanation: ""),
                .init(key: "com.apple.developer.healthkit", name: "HealthKit", explanation: ""),
                .init(key: "com.apple.developer.homekit", name: "HomeKit", explanation: "")]),
            (personalText("Development & debugging", "التطوير والتصحيح"), [
                .init(key: "get-task-allow", name: personalText("Debugging", "تصحيح الأخطاء"), explanation: personalText("Allows debugger attachment when true", "بيسمح باتصال المصحّح لما تكون القيمة true"))])
        ]
    }
    private var unknownKeys: [String] {
        let known = Set(groups.flatMap { $0.1.map(\.key) })
        return identity.entitlements.keys.filter { !known.contains($0) }.sorted()
    }
    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(identity.name, systemImage: "signature").font(.title3.bold())
                        metadata("Team ID", identity.teamID)
                        metadata(personalText("Application identifier", "معرّف التطبيق"), identity.bundleID)
                        metadata(personalText("Type", "النوع"), identity.profileType)
                        if let expiry = identity.expiry {
                            metadata(personalText("Expires", "بينتهي"), expiry.formatted(date: .abbreviated, time: .shortened))
                        }
                        Label(personalText("This device: not checked", "هالجهاز: لسا مو مفحوص"), systemImage: "questionmark.circle")
                            .foregroundStyle(.orange).font(.caption)
                        Text(personalText("Local profile data. This is not an online validity or revocation check.", "بيانات البروفايل المحلي. هاد مو فحص أونلاين لصلاحية الشهادة أو إلغائها."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18).appsGlass(cornerRadius: 24)
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(group.0).font(.headline)
                            ForEach(group.1, id: \.key) { capability in
                                entitlement(capability, unknown: false)
                            }
                        }.padding(18).appsGlass(cornerRadius: 24)
                    }
                    if !unknownKeys.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(personalText("Other capabilities", "صلاحيات تانية")).font(.headline)
                            ForEach(unknownKeys, id: \.self) { key in
                                entitlement(.init(key: key, name: key, explanation: ""), unknown: true)
                            }
                        }.padding(18).appsGlass(cornerRadius: 24)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Label("UDIDs (\(identity.devices.count))", systemImage: "iphone").font(.headline)
                        if identity.devices.isEmpty {
                            Text(personalText("No device list in this profile", "ما في قائمة أجهزة بهالبروفايل")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(identity.devices, id: \.self) { device in
                            HStack {
                                Text(device).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button { UIPasteboard.general.string = device } label: { Image(systemName: "doc.on.doc") }
                                    .accessibilityLabel(personalText("Copy device identifier", "نسخ معرّف الجهاز"))
                            }
                        }
                    }.padding(18).appsGlass(cornerRadius: 24)
                }.padding(20)
            }
        }
        .navigationTitle(personalText("Certificate details", "تفاصيل الشهادة"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(.dark)
    }
    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }
    }
    private func entitlement(_ capability: Capability, unknown: Bool) -> some View {
        let value = identity.entitlements[capability.key]
        let enabled = value.map { value in
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if let array = value as? [Any] { return !array.isEmpty }
            if let text = value as? String { return !text.isEmpty }
            return true
        } ?? false
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: unknown ? "questionmark.circle.fill" : enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(unknown ? Color.blue : enabled ? Color.green : Color.gray)
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.name).font(.subheadline.weight(.semibold))
                if !capability.explanation.isEmpty { Text(capability.explanation).font(.caption).foregroundStyle(.secondary) }
                Text(capability.key).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if let value { Text(Self.display(value)).font(.caption).textSelection(.enabled) }
                else { Text(personalText("Not present in profile", "مو موجود بالبروفايل")).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static func display(_ value: Any) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        if let array = value as? [Any] { return array.map { display($0) }.joined(separator: ", ") }
        if let dictionary = value as? [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) { return text }
        return String(describing: value)
    }
}
