import SwiftUI
import UniformTypeIdentifiers

// MARK: - Glass helpers (Liquid Glass on iOS 26, material fallback)

extension View {
    @ViewBuilder
    func appsGlassClassic(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let g: Glass = tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular
            self.glassEffect(interactive ? g.interactive() : g, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.appsGlassFallback(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        self.appsGlassFallback(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    @ViewBuilder
    func appsGlassCapsuleClassic(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let g: Glass = tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular
            self.glassEffect(g.interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
        }
        #else
        self.background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
        #endif
    }

    func appsGlassFallback(cornerRadius: CGFloat, tint: Color?) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((tint ?? .clear).opacity(0.12))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8)
            )
    }
}

// MARK: - Aurora background

struct AuroraBackground: View {
    @AppStorage(MirsaTheme.key) private var theme = MirsaTheme.liquid.rawValue
    var body: some View {
        if theme == MirsaTheme.liquid.rawValue { LiquidBackground() } else { classic }
    }

    private var classic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { ctx in
            let t = Float(ctx.date.timeIntervalSinceReferenceDate)
            let s = sin(t * 0.25) * 0.08
            let c = cos(t * 0.21) * 0.08
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + s, 0.45 + c], [1, 0.5],
                    [0, 1], [0.5 - c, 1], [1, 1],
                ],
                colors: [
                    Color(red: 0.06, green: 0.04, blue: 0.16), Color(red: 0.30, green: 0.14, blue: 0.62), Color(red: 0.05, green: 0.10, blue: 0.28),
                    Color(red: 0.10, green: 0.22, blue: 0.55), Color(red: 0.12, green: 0.45, blue: 0.62), Color(red: 0.36, green: 0.16, blue: 0.58),
                    Color(red: 0.02, green: 0.03, blue: 0.08), Color(red: 0.03, green: 0.20, blue: 0.24), Color(red: 0.03, green: 0.03, blue: 0.10),
                ]
            )
        }
        .overlay(Color.black.opacity(0.25))
        .ignoresSafeArea()
    }
}

// MARK: - Icon colour

enum IconTint {
    private static var cache: [String: Color] = [:]

    static func color(for id: String, image: UIImage?) -> Color {
        if let c = cache[id] { return c }
        guard let image else { return Color(red: 0.45, green: 0.35, blue: 0.95) }
        let r = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let px = r.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        var c = Color(red: 0.45, green: 0.35, blue: 0.95)
        if let cg = px.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            c = Color(red: Double(p[0]) / 255, green: Double(p[1]) / 255, blue: Double(p[2]) / 255)
        }
        cache[id] = c
        return c
    }
}

// MARK: - Root

enum AppsSegment { case container, real, downloads }

struct AppsTab: View {
    @EnvironmentObject var vm: AppViewModel
    @StateObject private var store = AppsStore.shared
    @StateObject private var updater = MirsaUpdater.shared
    @State private var segment: AppsSegment = .container
    @State private var showPicker = false
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var infoApp: ManagedApp?
    @State private var backupApp: ManagedApp?
    @State private var shortcutError: String?
    @ObservedObject private var downloads = DownloadsLibrary.shared
    @Namespace private var segNS

    @AppStorage(MirsaTheme.key) private var theme = MirsaTheme.liquid.rawValue
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: theme == MirsaTheme.liquid.rawValue ? 14 : 18), count: theme == MirsaTheme.liquid.rawValue ? 4 : 3) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AuroraBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    HeroCard(store: store, onSignIn: { showLogin = true }, onRefresh: refreshAll)
                    statusWarnings
                    segmentControl
                    grid
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)

            fab
                .padding(.trailing, 22)
                .padding(.bottom, theme == MirsaTheme.liquid.rawValue ? 18 : 26)

            if let busy = store.busy { BusyOverlay(text: busy, progress: store.progress) }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPicker) {
            DocumentPickerView(allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip]) { url in
                Task { await store.importIPA(from: url) }
            }
        }
        .sheet(item: Binding(get: { store.pending }, set: { if $0 == nil { store.cancelPending() } })) { p in
            InstallChoiceSheet(pending: p, store: store) { location in
                Task { await store.commitPending(to: location, vm: vm) }
            }
            .presentationDetents([.large])
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet(store: store)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $store.prompt) { p in
            PromptSheet(prompt: p) { store.prompt = nil }
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSettings) {
            AppsSettingsSheet(store: store, onSignIn: { showSettings = false; showLogin = true })
                .environmentObject(vm)
        }
        .sheet(item: $updater.available) { rel in
            MirsaUpdateSheet(release: rel, updater: updater) { Task { await updater.install(rel, vm: vm) } }
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $backupApp) { a in BackupsSheet(app: a) }
        .alert(tr("Home Screen", "الشاشة الرئيسية"), isPresented: Binding(get: { shortcutError != nil }, set: { if !$0 { shortcutError = nil } })) {
            Button("OK") { shortcutError = nil }
        } message: { Text(shortcutError ?? "") }
        .sheet(item: $infoApp) { a in
            AppInfoSheet(app: a, store: store)
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
        .alert(L.t("tab"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert(L.f("launch.title", store.launchCandidate?.name ?? ""),
               isPresented: Binding(get: { store.launchCandidate != nil }, set: { if !$0 { store.launchCandidate = nil } })) {
            Button(L.t("choice.cancel"), role: .cancel) { store.launchCandidate = nil }
            Button(L.t("launch.go")) { if let a = store.launchCandidate { store.confirmLaunch(a) } }
        } message: { Text(L.f("launch.body", store.launchCandidate?.name ?? "")) }
        .alert(L.t("repair.title"), isPresented: Binding(get: { store.needsRepair && store.busy == nil && store.error == nil },
                                                         set: { if !$0 { store.needsRepair = false } })) {
            Button(L.t("choice.cancel"), role: .cancel) { store.needsRepair = false }
            Button(L.t("repair.go")) { Task { await store.installSelf(vm: vm) } }
        } message: { Text(L.t("repair.body")) }
        .overlay(alignment: .top) { toast }
        .task {
            let launchErr = store.lastLaunchError
            if launchErr != nil {
                UserDefaults.standard.removeObject(forKey: "aircard.guest.lastError")
                store.forceResignContainer()
            }
            if store.account == nil && store.hasSavedLogin { await store.refreshAccount() }
            if let e = launchErr {
                let t = await store.signerSelfTest()
                store.error = store.signingDiagnostics + "\n" + t + "\n\n" + e
            }
            store.scheduleExpiryReminders()
            await updater.check()
            if GitHubWatcher.shared.autoInstall && !GitHubWatcher.shared.sources.isEmpty && store.networkReady(vm) {
                Task { await GitHubWatcher.shared.checkAll(install: true) }
            }
            vm.refreshNetworkStatus()
            store.scheduleBackgroundRefresh()
        }
    }

    // MARK: Pieces

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? L.t("greeting.morning") : (h < 18 ? L.t("greeting.afternoon") : L.t("greeting.evening"))
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                Text(L.t("title"))
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
            }
            .appsGlassCapsule()
            .accessibilityLabel(L.t("settings.title"))
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var statusWarnings: some View {
        if segment == .real || store.pending != nil {
            if !vm.vpnUp {
                WarningPill(icon: "lock.shield", text: L.t("hero.vpnOff"))
            } else if !vm.wifiUp {
                WarningPill(icon: "wifi.slash", text: L.t("hero.wifiOff"))
            }
        }
    }

    private var segmentControl: some View {
        HStack(spacing: 4) {
            segButton(.container, title: L.t("seg.container"), trailing: "∞")
            segButton(.real, title: L.t("seg.real"), trailing: "\(store.slotsUsed)/\(store.realLimit)")
            segButton(.downloads, title: tr("Downloads", "التنزيلات"), trailing: "\(downloads.items.count)")
        }
        .padding(4)
        .appsGlassCapsule()
    }

    private func segButton(_ s: AppsSegment, title: String, trailing: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { segment = s }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(trailing)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(segment == s ? 0.9 : 0.5))
            }
            .foregroundStyle(segment == s ? .white : .white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if segment == s {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 0.48, green: 0.36, blue: 1.0).opacity(0.75),
                                                      Color(red: 0.18, green: 0.56, blue: 0.95).opacity(0.6)],
                                             startPoint: .leading, endPoint: .trailing))
                        .matchedGeometryEffect(id: "seg", in: segNS)
                        .shadow(color: Color(red: 0.45, green: 0.4, blue: 1).opacity(0.5), radius: 10)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var currentApps: [ManagedApp] { segment == .container ? store.containerApps : store.realApps }

    @ViewBuilder
    private var grid: some View {
        if segment == .downloads {
            DownloadsList(store: store)
        } else if currentApps.isEmpty {
            ContentUnavailableView {
                Label(L.t("empty.title"), systemImage: segment == .container ? "shippingbox" : "app.badge")
                    .foregroundStyle(.white)
            } description: {
                Text(segment == .container ? L.t("empty.container") : L.t("empty.real"))
                    .foregroundStyle(.white.opacity(0.7))
            } actions: {
                Button { showPicker = true } label: {
                    Label(L.t("empty.import"), systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color(red: 0.45, green: 0.38, blue: 1.0))
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .appsGlass(cornerRadius: 28)
        } else {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(currentApps) { app in
                    AppTile(app: app)
                        .onTapGesture { store.launch(app) }
                        .contextMenu { menu(for: app) }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for app: ManagedApp) -> some View {
        Button { store.launch(app) } label: { Label(L.t("menu.open"), systemImage: "arrow.up.forward.app") }
        if app.location == .container {
            Button { Task { await store.move(app, to: .real, vm: vm) } } label: {
                Label(L.t("menu.toReal"), systemImage: "iphone.and.arrow.forward")
            }
            .disabled(store.slotsLeft == 0)
            Button { Task { await store.resign(app) } } label: { Label(L.t("menu.resign"), systemImage: "signature") }
            Button { backupApp = app } label: { Label(tr("Data backups", "نسخ البيانات"), systemImage: "externaldrive") }
            Button { shortcutError = HomeShortcut.add(app) } label: {
                Label(tr("Add to Home Screen", "إضافة للشاشة الرئيسية"), systemImage: "plus.app")
            }
        } else {
            Button { Task { await store.move(app, to: .container, vm: vm) } } label: {
                Label(L.t("menu.toContainer"), systemImage: "shippingbox")
            }
            Button { Task { await store.refresh(app, vm: vm) } } label: { Label(L.t("menu.refresh"), systemImage: "arrow.clockwise") }
        }
        Button { infoApp = app } label: { Label(L.t("menu.info"), systemImage: "info.circle") }
        Divider()
        Button(role: .destructive) { Task { await store.delete(app, vm: vm) } } label: {
            Label(L.t("menu.delete"), systemImage: "trash")
        }
    }

    private var fab: some View {
        Button { showPicker = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    Circle().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.38, blue: 1.0),
                                                          Color(red: 0.16, green: 0.62, blue: 0.95)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Color(red: 0.45, green: 0.45, blue: 1).opacity(0.7), radius: 18, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t("empty.import"))
    }

    @ViewBuilder
    private var toast: some View {
        if let t = store.toast {
            Text(t)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .appsGlassCapsule(tint: .green)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation { store.toast = nil }
                }
        }
    }

    private func refreshAll() {
        Task {
            await store.refreshAccount()
            await store.refreshAll(vm: vm)
        }
    }
}

// MARK: - Hero card

struct HeroCard: View {
    @ObservedObject var store: AppsStore
    let onSignIn: () -> Void
    let onRefresh: () -> Void

    private var days: Int? {
        guard let d = store.nextRenewal else { return nil }
        return max(0, Int(ceil(d.timeIntervalSinceNow / 86_400)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(red: 0.3, green: 0.85, blue: 0.6), Color(red: 0.1, green: 0.55, blue: 0.75)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: store.account != nil ? "checkmark.shield.fill" : "person.badge.shield.checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 50, height: 50)
                .shadow(color: .green.opacity(0.45), radius: 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.account != nil ? L.t("hero.active") : L.t("hero.signedOut"))
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let a = store.account {
                        Text(a.email)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                        if let avail = a.appIDsAvailable, let max = a.appIDsMax {
                            Text(L.f("hero.appIDs", avail, max))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Text(L.f("hero.slots", store.slotsLeft, store.realLimit))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                RenewalRing(days: days)
            }

            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Text(L.t("seg.container") + " ∞ · " + L.t("seg.real") + " \(store.slotsUsed)/\(store.realLimit)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(action: store.account != nil || store.hasSavedLogin ? onRefresh : onSignIn) {
                    Label(store.account != nil || store.hasSavedLogin ? L.t("hero.refresh") : L.t("hero.signIn"),
                          systemImage: store.account != nil || store.hasSavedLogin ? "arrow.clockwise" : "person.crop.circle")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .appsGlassCapsule(tint: Color(red: 0.45, green: 0.4, blue: 1))
            }
        }
        .padding(18)
        .appsGlass(cornerRadius: 28, tint: Color(red: 0.45, green: 0.35, blue: 1))
    }
}

struct RenewalRing: View {
    let days: Int?
    var body: some View {
        let fraction = days.map { min(1, Double($0) / 7.0) } ?? 0
        let color: Color = (days ?? 7) <= 1 ? .red : ((days ?? 7) <= 3 ? .orange : Color(red: 0.4, green: 0.9, blue: 0.7))
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 6)
            VStack(spacing: -2) {
                Text(days.map(String.init) ?? "–")
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(L.t("hero.days"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(days ?? 0) \(L.t("hero.days")) \(L.t("hero.renews"))")
    }
}

// MARK: - Tile

struct AppTile: View {
    let app: ManagedApp
    @AppStorage(MirsaTheme.key) private var theme = MirsaTheme.liquid.rawValue
    private var liquid: Bool { theme == MirsaTheme.liquid.rawValue }
    private var icon: UIImage? { UIImage(contentsOfFile: AppsStore.iconURL(app.id).path) }

    var body: some View {
        let img = icon
        let tint = IconTint.color(for: app.id, image: img)
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 70, height: 70)
                    .blur(radius: 22)
                    .opacity(0.55)
                Group {
                    if let img {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(colors: [tint, tint.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                            Text(String(app.name.prefix(1)))
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: liquid ? 54 : 64, height: liquid ? 54 : 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            }
            .frame(width: liquid ? 76 : 96, height: liquid ? 76 : 96)
            .appsGlass(cornerRadius: liquid ? 24 : 26, tint: liquid ? nil : tint)
            .overlay(alignment: .topTrailing) { badges }

            Text(app.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: liquid ? 82 : 96)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
    }

    @ViewBuilder
    private var badges: some View {
        if app.location == .real {
            HStack(spacing: 3) {
                if app.wantsNotifications {
                    Image(systemName: "bell.fill").font(.system(size: 9, weight: .bold))
                }
                if let d = app.daysLeft {
                    Text(L.f("badge.days", d)).font(.system(size: 10, weight: .bold).monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill((app.daysLeft ?? 7) <= 2 ? Color.red : Color(red: 0.3, green: 0.45, blue: 1)))
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - Small views

struct WarningPill: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .appsGlass(cornerRadius: 16, tint: .orange)
    }
}

struct BusyOverlay: View {
    let text: String
    let progress: Double
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                if progress > 0.01 && progress < 1 {
                    ProgressView(value: progress).tint(.white).frame(width: 160)
                } else {
                    ProgressView().tint(.white).controlSize(.large)
                }
                Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(28)
            .appsGlass(cornerRadius: 26)
        }
        .transition(.opacity)
    }
}

// MARK: - Install choice

struct InstallChoiceSheet: View {
    let pending: PendingImport
    @ObservedObject var store: AppsStore
    let onChoose: (AppLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var afterLogin: AppLocation?

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
                    appHeader

                    optionCard(selected: true,
                               icon: "shippingbox.fill", iconTint: Color(red: 0.5, green: 0.4, blue: 1),
                               title: L.t("choice.container"), sub: L.t("choice.containerSub"),
                               trailing: "∞", disabled: false) {
                        dismissThen(.container)
                    }

                    optionCard(selected: false,
                               icon: "app.badge.fill", iconTint: Color(red: 0.2, green: 0.65, blue: 0.95),
                               title: L.t("choice.real"), sub: L.f("choice.realSub", store.realLimit),
                               trailing: "\(store.slotsLeft)/\(store.realLimit)", disabled: store.slotsLeft == 0) {
                        dismissThen(.real)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bell.badge.fill").foregroundStyle(.yellow)
                            Text(L.t("choice.note")).font(.footnote).foregroundStyle(.white.opacity(0.85))
                        }
                        Divider().overlay(.white.opacity(0.15))
                        Label(L.f("choice.slots", store.slotsLeft, store.realLimit), systemImage: "square.grid.3x3.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        if let a = store.account, let avail = a.appIDsAvailable, let max = a.appIDsMax {
                            Label(L.f("choice.appIDs", avail, max), systemImage: "number.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        }
                        if store.slotsLeft == 0 {
                            Label(L.t("choice.full"), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appsGlass(cornerRadius: 22)

                    Button(L.t("choice.cancel")) { store.cancelPending(); dismiss() }
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLogin, onDismiss: {
            if let l = afterLogin, store.account != nil {
                afterLogin = nil
                onChoose(l)
            }
        }) {
            LoginSheet(store: store)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private func dismissThen(_ l: AppLocation) {
        if store.account == nil && !store.hasSavedLogin {
            afterLogin = l
            showLogin = true
        } else {
            onChoose(l)
        }
    }

    private var appHeader: some View {
        HStack(spacing: 14) {
            Group {
                if let i = pending.icon { Image(uiImage: i).resizable().scaledToFill() }
                else { Color.purple.overlay(Text(String(pending.name.prefix(1))).font(.title.bold()).foregroundStyle(.white)) }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(L.f("choice.title", pending.name)).font(.title3.bold()).foregroundStyle(.white)
                Text("\(pending.version) · \(ByteCountFormatter.string(fromByteCount: pending.sizeBytes, countStyle: .file))")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                Text(pending.bundleID).font(.caption2).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
        .appsGlass(cornerRadius: 24)
    }

    private func optionCard(selected: Bool, icon: String, iconTint: Color, title: String, sub: String,
                            trailing: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(iconTint.gradient))
                    .shadow(color: iconTint.opacity(0.6), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(sub).font(.caption).foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Text(trailing)
                    .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
            .appsGlass(cornerRadius: 22, tint: selected ? iconTint : nil)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? iconTint.opacity(0.8) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - Login

struct LoginSheet: View {
    @ObservedObject var store: AppsStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = Keychain.get("appleid.email") ?? ""
    @State private var password = ""

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 18) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .padding(.top, 30)
                Text(L.t("login.title")).font(.title2.bold()).foregroundStyle(.white)
                Text(L.t("login.sub"))
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))

                VStack(spacing: 0) {
                    TextField(L.t("login.email"), text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                    Divider().overlay(.white.opacity(0.15))
                    SecureField(L.t("login.password"), text: $password)
                        .textContentType(.password)
                        .padding(14)
                }
                .foregroundStyle(.white)
                .appsGlass(cornerRadius: 18)

                Button {
                    Task {
                        await store.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                        if store.account != nil { dismiss() }
                    }
                } label: {
                    Text(L.t("login.button")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color(red: 0.45, green: 0.38, blue: 1.0))
                .disabled(email.isEmpty || password.isEmpty || store.busy != nil)

                if store.busy != nil { ProgressView().tint(.white) }

                Text(L.t("login.privacy"))
                    .font(.caption2).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $store.prompt) { p in
            PromptSheet(prompt: p) { store.prompt = nil }
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
                .interactiveDismissDisabled()
        }
    }
}

// MARK: - 2FA / certificate prompt

struct PromptSheet: View {
    let prompt: SideloadPrompt
    let close: () -> Void
    @State private var code = ""
    @State private var answered = false

    private func answer(_ v: String?) {
        guard !answered else { return }
        answered = true
        PromptBridge.shared.respond(v)
        close()
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                switch prompt.kind {
                case .twoFactor: twoFactor
                case .maxCerts: certs
                }
                Button(L.t("choice.cancel")) { answer("abort") }
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onDisappear { answer("abort") }
    }

    private var twoFactor: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill").font(.system(size: 40)).foregroundStyle(.white).padding(.top, 20)
            Text(L.t("twofa.title")).font(.title2.bold()).foregroundStyle(.white)
            Text(prompt.sms ? L.t("twofa.subSMS") : L.t("twofa.sub"))
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
            if let e = prompt.lastError, !e.isEmpty {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(14)
                .appsGlass(cornerRadius: 18)
            Button { answer("code:" + code) } label: {
                Text(L.t("twofa.submit")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color(red: 0.45, green: 0.38, blue: 1.0))
            .disabled(code.count < 6)

            HStack(spacing: 10) {
                if !prompt.sms {
                    ForEach(prompt.phones) { p in
                        Button(L.t("twofa.sms") + " " + p.number) { answer("sms:\(p.id)") }
                            .font(.caption.weight(.semibold))
                    }
                } else {
                    Button(L.t("twofa.devices")) { answer("devices") }.font(.caption.weight(.semibold))
                }
                Button(L.t("twofa.resend")) { answer("resend") }.font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var certs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("certs.title")).font(.title3.bold()).foregroundStyle(.white).padding(.top, 20)
            Text(L.t("certs.sub")).font(.footnote).foregroundStyle(.white.opacity(0.7))
            ForEach(prompt.certs) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.machine.isEmpty ? c.name : c.machine).font(.headline).foregroundStyle(.white)
                        Text(c.serial).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(L.t("certs.revoke"), role: .destructive) { answer(c.serial) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
                .padding(14)
                .appsGlass(cornerRadius: 18)
            }
        }
    }
}

// MARK: - Settings

struct AppsSettingsSheet: View {
    @EnvironmentObject var vm: AppViewModel
    @AppStorage(MirsaTheme.key) private var theme = MirsaTheme.liquid.rawValue
    @ObservedObject var store: AppsStore
    let onSignIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(L.t("settings.account")) {
                    if let a = store.account {
                        LabeledContent("Apple ID", value: a.email)
                        LabeledContent("Team", value: a.teamName.isEmpty ? a.teamID : "\(a.teamName) (\(a.teamID))")
                        if let avail = a.appIDsAvailable, let max = a.appIDsMax {
                            LabeledContent("App IDs", value: "\(avail) / \(max)")
                        }
                        Button(L.t("settings.signOut"), role: .destructive) { store.signOut() }
                    } else {
                        Button(L.t("hero.signIn"), action: onSignIn)
                    }
                }
                Section(tr("Theme", "الثيم")) {
                    Picker(tr("Theme", "الثيم"), selection: $theme) {
                        ForEach(MirsaTheme.allCases) { t in Text(t.title).tag(t.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Stepper(value: $store.realLimit, in: 1...100) {
                        LabeledContent(L.t("settings.limit"), value: "\(store.realLimit)")
                    }
                    Toggle(L.t("settings.autoRefresh"), isOn: $store.autoRefresh)
                } footer: { Text(L.t("settings.limitFoot")) }

                Section {
                    Button {
                        dismiss()
                        Task { await store.installSelf(vm: vm) }
                    } label: { Label(L.t("settings.selfInstall"), systemImage: "arrow.down.app") }
                    .disabled(store.account == nil && !store.hasSavedLogin)
                } footer: { Text(L.t("settings.selfInstallFoot")) }

                Section(L.t("settings.anisette")) {
                    TextField("https://ani.sidestore.io", text: $store.anisetteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section(tr("Days left", "الأيام الباقية")) {
                    ExpiryListView(store: store)
                }

                Section(tr("Get apps", "جيب تطبيقات")) {
                    NavigationLink { GitHubSourcesView() } label: {
                        Label(tr("GitHub Updates", "تحديثات GitHub"), systemImage: "shippingbox.and.arrow.backward")
                    }
                    NavigationLink { WebUploadView() } label: {
                        Label(tr("Upload from Computer", "رفع من الكمبيوتر"), systemImage: "laptopcomputer.and.arrow.down")
                    }
                }

                Section {
                    NavigationLink(L.t("settings.licenses")) { LicensesView() }
                }
            }
            .onChange(of: store.pending?.id) { _, new in if new != nil { dismiss() } }
            .navigationTitle(L.t("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L.t("settings.done")) { dismiss() } }
            }
        }
    }
}

// MARK: - App info

struct AppInfoSheet: View {
    let app: ManagedApp
    @ObservedObject var store: AppsStore

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(L.t("info.version"), value: app.version)
                LabeledContent(L.t("info.bundle"), value: app.installedBundleID ?? app.id)
                LabeledContent(L.t("info.location"), value: app.location == .container ? L.t("seg.container") : L.t("seg.real"))
                LabeledContent(L.t("info.size"), value: ByteCountFormatter.string(fromByteCount: app.sizeBytes, countStyle: .file))
                if let e = app.expires {
                    LabeledContent(L.t("info.expires"), value: e.formatted(date: .abbreviated, time: .shortened))
                }
                if let s = app.signedSerial {
                    LabeledContent(L.t("info.signedWith"), value: s)
                }
            }
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Licenses

struct LicensesView: View {
    private struct Item: Identifiable { let id = UUID(); let name: String; let license: String; let url: String; let note: String }
    private let items: [Item] = [
        Item(name: "isideload", license: "MIT", url: "https://github.com/nab138/isideload",
             note: "Apple ID sign-in, anisette, development certificates, App IDs, provisioning profiles and app signing."),
        Item(name: "idevice", license: "MIT", url: "https://github.com/jkcoxson/idevice",
             note: "AFC and installation_proxy over the on-device loopback tunnel; pairing and RSD."),
        Item(name: "apple-codesign-quick", license: "LGPL-2.1-or-later", url: "https://github.com/Dadoum/apple-codesign-quick",
             note: "Code signing (used by isideload). Statically linked: Mirsa's full source and build scripts are public so you can relink with a modified version, as the LGPL requires."),
        Item(name: "Mirsa Container loader", license: "MIT (Mirsa)", url: "https://github.com/Alaaaya/Mirsa/tree/main/app-source",
             note: "Written for Mirsa. Uses the same general idea as LiveContainer (AGPL-3.0) but contains none of its code."),
    ]

    var body: some View {
        List(items) { i in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(i.name).font(.headline)
                    Spacer()
                    Text(i.license).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Text(i.note).font(.footnote).foregroundStyle(.secondary)
                if let u = URL(string: i.url) { Link(i.url, destination: u).font(.caption) }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle(L.t("settings.licenses"))
    }
}
