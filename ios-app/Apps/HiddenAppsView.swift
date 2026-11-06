import SwiftUI

// Reusable PIN gate + hidden grid container. Mirsa-only privacy, not OS security.
// Integration: HiddenAppsView(store: .shared) { HiddenGrid() } presented as sheet/fullScreenCover.
// Layout is always LTR (owner rule), even in Arabic.

struct HiddenPINPad: View {
    enum Mode { case create, enter }
    let mode: Mode
    let message: String?
    let onSubmit: (String) -> Void
    @State private var pin = ""
    @State private var first: String? = nil
    @State private var shake = 0

    private var title: String {
        switch mode {
        case .enter: return personalText("Enter PIN", "اكتب الرمز")
        case .create: return first == nil ? personalText("Create a PIN", "سوّي رمز") : personalText("Confirm PIN", "أكّد الرمز")
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text(title).font(.title2.weight(.bold)).foregroundStyle(.white)
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { i in
                    Circle().fill(i < pin.count ? Color.white : Color.white.opacity(0.18)).frame(width: 14, height: 14)
                        .scaleEffect(i < pin.count ? 1.15 : 1).animation(.spring(response: 0.25, dampingFraction: 0.6), value: pin.count)
                }
            }.modifier(Shake(t: CGFloat(shake)))
            Text(message ?? (mode == .create ? personalText("4 to 6 digits. Stored only on this device.", "من 4 لـ 6 أرقام. بينحفظ على جهازك بس.") : personalText("4 to 6 digits", "من 4 لـ 6 أرقام")))
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.65)).frame(minHeight: 34)
            VStack(spacing: 14) {
                ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                    HStack(spacing: 18) { ForEach(row, id: \.self) { key(String($0)) } }
                }
                HStack(spacing: 18) {
                    Button { if !pin.isEmpty { pin.removeLast() } } label: { Image(systemName: "delete.left").frame(width: 74, height: 74) }
                        .foregroundStyle(.white.opacity(0.8)).accessibilityLabel(personalText("Delete", "مسح"))
                    key("0")
                    Button { submit() } label: { Image(systemName: "checkmark").frame(width: 74, height: 74) }
                        .foregroundStyle(HiddenAppsStore.isValidPIN(pin) ? .white : .white.opacity(0.25))
                        .disabled(!HiddenAppsStore.isValidPIN(pin)).accessibilityLabel(personalText("OK", "تأكيد"))
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(24)
        .onChange(of: message) { _ in pin = ""; withAnimation(.linear(duration: 0.4)) { shake += 1 } }
    }

    private func key(_ d: String) -> some View {
        Button { if pin.count < 6 { pin += d } } label: {
            Text(d).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(.white)
                .frame(width: 74, height: 74).background(Circle().fill(Color.white.opacity(0.12)))
        }
    }

    private func submit() {
        guard HiddenAppsStore.isValidPIN(pin) else { return }
        if mode == .create {
            if let f = first {
                if f == pin { onSubmit(pin) } else { first = nil; pin = ""; withAnimation(.linear(duration: 0.4)) { shake += 1 } }
            } else { first = pin; pin = "" }
        } else { onSubmit(pin); pin = "" }
    }
}

private struct Shake: GeometryEffect {
    var t: CGFloat
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(t * .pi * 4), y: 0))
    }
}

struct HiddenAppsView<Content: View>: View {
    @ObservedObject var store: HiddenAppsStore
    var title: String = personalText("Hidden apps", "التطبيقات المخفية")
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if store.health == .faulted {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.lock.fill").font(.largeTitle).foregroundStyle(.white)
                    Text(personalText("Hidden apps are unavailable", "التطبيقات المخفية مو متاحة هلأ")).font(.headline).foregroundStyle(.white)
                    Text(personalText("The protected data could not be read. Nothing was deleted and your hidden apps stay hidden.", "ما قدرنا نقرا البيانات المحمية. ما انحذف شي والتطبيقات المخفية بتضل مخفية."))
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.65))
                    Button(personalText("Retry", "جرّب كمان")) { store.reload() }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                }.padding(32)
            } else if store.isUnlocked {
                VStack(spacing: 0) {
                    HStack {
                        Button { store.lock(); dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
                            .foregroundStyle(.white).accessibilityLabel(personalText("Close", "سكّر"))
                        Text(title).font(.headline).foregroundStyle(.white)
                        Spacer()
                        Button(personalText("Lock", "قفل")) { store.lock(); dismiss() }.foregroundStyle(.white.opacity(0.8))
                    }.padding(.horizontal, 12)
                    content()
                }.environment(\.layoutDirection, .leftToRight)
            } else if !store.hasPIN {
                HiddenPINPad(mode: .create, message: message) { pin in
                    do { try store.setPIN(pin); message = nil } catch { message = personalText("Could not save the PIN.", "ما قدرنا نحفظ الرمز.") }
                }
            } else {
                HiddenPINPad(mode: .enter, message: message ?? lockedText) { pin in
                    switch store.unlock(pin) {
                    case .success: message = nil
                    case .wrongPIN(let r): message = r > 0 ? personalText("Wrong PIN. \(r) tries left.", "الرمز غلط. باقي \(r) محاولات.") : personalText("Wrong PIN.", "الرمز غلط.")
                    case .locked(let u): message = lockText(u)
                    case .faulted: message = personalText("Could not verify the PIN.", "ما قدرنا نتحقق من الرمز.")
                    case .notConfigured: message = nil
                    }
                }
            }
        }
        .onChange(of: phase) { p in if p != .active { store.lock() } }
        .onDisappear { store.lock() }
        .onReceive(ticker) { now = $0 }
    }

    private var lockedText: String? { nil }
    private func lockText(_ until: Date) -> String {
        let s = max(1, Int(until.timeIntervalSince(Date()).rounded(.up)))
        let t = s >= 60 ? personalText("\(s / 60) min", "\(s / 60) دقيقة") : personalText("\(s) s", "\(s) ثانية")
        return personalText("Too many tries. Wait \(t).", "محاولات كتير. استنى \(t).")
    }
}

extension Notification.Name { static let mirsaShowHidden = Notification.Name("mirsa.showHidden") }

/// Unlocked content: applies a pending hide once (after PIN setup/unlock), lists hidden apps with unhide.
struct HiddenAppsGrid: View {
    let apps: [ManagedApp]
    @Binding var pendingHide: String?
    @ObservedObject private var hidden = HiddenAppsStore.shared

    var body: some View {
        let items = hidden.hiddenItems(apps, ns: .main, id: { $0.id })
        List {
            if items.isEmpty { Text(personalText("No hidden apps", "ما في تطبيقات مخفية")).foregroundStyle(.secondary) }
            ForEach(items) { app in
                HStack {
                    Text(app.name).foregroundStyle(.white)
                    Spacer()
                    Button(personalText("Unhide", "إظهار")) { _ = hidden.unhide(HiddenAppID(.main, app.id)) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if let id = pendingHide { pendingHide = nil; _ = hidden.hide(HiddenAppID(.main, id)) }
        }
    }
}
