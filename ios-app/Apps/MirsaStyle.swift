import SwiftUI

/// Mirsa's look for the older Form/ScrollView screens: aurora background,
/// translucent rows, clear navigation bar, purple accent.
struct MirsaForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        Form { content() }
            .mirsaScreen()
    }
}

struct MirsaScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView { content() }
            .mirsaScreen()
    }
}

extension View {
    func mirsaScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AuroraBackground().ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(Color(red: 0.62, green: 0.55, blue: 1.0))
            .environment(\.defaultMinListRowHeight, 50)
            .preferredColorScheme(.dark)
    }
}
