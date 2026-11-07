import SwiftUI

/// App-wide UI language. Arabic is the default. Layout is always physical LTR.
enum AppLanguage: String, CaseIterable, Identifiable {
    case arabic = "ar", sorani = "ckb", kurmanji = "kmr", english = "en"
    var id: String { rawValue }

    /// Label in the Arabic UI.
    var arabicLabel: String {
        switch self {
        case .arabic: return "العربية"
        case .sorani: return "كوردي سوراني"
        case .kurmanji: return "كوردي كرمانجي"
        case .english: return "English"
        }
    }
    var nativeLabel: String {
        switch self {
        case .arabic: return "العربية"
        case .sorani: return "کوردی (سۆرانی)"
        case .kurmanji: return "Kurdî (Kurmancî)"
        case .english: return "English"
        }
    }
    var locale: Locale {
        switch self {
        case .arabic: return Locale(identifier: "ar")
        case .sorani: return Locale(identifier: "ckb")
        case .kurmanji: return Locale(identifier: "kmr")
        case .english: return Locale(identifier: "en")
        }
    }
}

/// Observable holder so changing the language rebuilds the whole UI at once.
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    static let key = "mirsa.appLanguage"
    @Published private(set) var current: AppLanguage
    private init() {
        current = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .arabic
    }
    func set(_ l: AppLanguage) {
        UserDefaults.standard.set(l.rawValue, forKey: Self.key)
        current = l
    }
    static var snapshot: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .arabic
    }
}

/// Round globe button that sits beside the settings gear.
struct LanguageGlobeMenu: View {
    @ObservedObject private var store = AppLanguageStore.shared
    var size: CGFloat = 42
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { l in
                Button {
                    store.set(l)
                } label: {
                    if l == store.current {
                        Label(l.nativeLabel, systemImage: "checkmark")
                    } else {
                        Text(l == .sorani || l == .kurmanji ? "\(l.arabicLabel)  ·  \(l.nativeLabel)" : l.nativeLabel)
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
        .accessibilityLabel(tr("Language", "اللغة"))
    }
}
