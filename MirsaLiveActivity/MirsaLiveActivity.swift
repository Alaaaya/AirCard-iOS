import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

@main
struct MirsaLiveActivityBundle: WidgetBundle {
    var body: some Widget { MirsaDownloadLiveActivity() }
}

struct MirsaDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MirsaDownloadAttributes.self) { context in
            MirsaActivityDetails(state: context.state, isStale: context.isStale)
                .padding(16)
                .activityBackgroundTint(Color(red: 0.04, green: 0.06, blue: 0.10))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "mirsa://downloads"))
                .environment(\.layoutDirection, .leftToRight)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Mirsa", systemImage: context.state.symbol)
                        .font(.headline).foregroundStyle(MirsaActivityDetails.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MirsaActivityValue(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MirsaActivityDetails(state: context.state, isStale: context.isStale, showsHeader: false)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(MirsaActivityDetails.accent)
                    .accessibilityLabel(context.state.phaseText)
            } compactTrailing: {
                MirsaActivityValue(state: context.state).font(.caption2.bold())
            } minimal: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(MirsaActivityDetails.accent)
                    .accessibilityLabel(context.state.phaseText)
            }
            .keylineTint(MirsaActivityDetails.accent)
            .widgetURL(URL(string: "mirsa://downloads"))
        }
    }
}

private struct MirsaActivityDetails: View {
    static let accent = Color(red: 0.30, green: 0.86, blue: 0.78)
    let state: MirsaDownloadAttributes.ContentState
    let isStale: Bool
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack {
                    Label("Mirsa", systemImage: state.symbol)
                        .font(.subheadline.bold()).foregroundStyle(Self.accent)
                    Spacer()
                    MirsaActivityValue(state: state)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text(state.phaseText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if state.phase == .downloading, state.receivedBytes > 0 {
                    Text(state.byteText).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let fraction = state.progress {
                ProgressView(value: fraction).tint(Self.accent)
                    .accessibilityLabel(state.phaseText)
                    .accessibilityValue("\(Int(fraction * 100))%")
            } else if !state.isTerminal {
                // Indeterminate is deliberate. No invented percentage for unknown sizes/signing.
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                    Text(state.isArabic ? "افتح مرسى للتفاصيل" : "Open Mirsa for details")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if isStale && !state.isTerminal {
                Text(state.isArabic ? "آخر حالة معروفة. افتح مرسى للتحديث." : "Last known status. Open Mirsa to refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct MirsaActivityValue: View {
    let state: MirsaDownloadAttributes.ContentState
    var body: some View {
        Group {
            if let fraction = state.progress, !state.isTerminal {
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit().contentTransition(.numericText())
            } else {
                Image(systemName: state.symbol)
            }
        }
        .foregroundStyle(MirsaActivityDetails.accent)
        .accessibilityLabel(state.phaseText)
    }
}

private extension MirsaDownloadAttributes.ContentState {
    var isTerminal: Bool {
        switch phase {
        case .ready, .completed, .failed, .cancelled: return true
        default: return false
        }
    }
    var phaseText: String {
        switch phase {
        case .downloading: return isArabic ? "عم ينزّل" : "Downloading"
        case .preparing: return isArabic ? "عم يجهّز الملف" : "Preparing IPA"
        case .ready: return isArabic ? "جاهز. افتح مرسى لتكمّل" : "Ready. Open Mirsa to continue"
        case .signing: return isArabic ? "عم يوقّع" : "Signing"
        case .installing: return isArabic ? "عم يثبّت" : "Installing"
        case .completed: return isArabic ? "تم التثبيت" : "Installed"
        case .failed: return isArabic ? "ما زبطت. افتح مرسى للتفاصيل" : "Failed. Open Mirsa for details"
        case .cancelled: return isArabic ? "تم الإلغاء" : "Cancelled"
        }
    }
    var symbol: String {
        switch phase {
        case .downloading: return "arrow.down.circle.fill"
        case .preparing: return "shippingbox.fill"
        case .ready: return "checkmark.circle"
        case .signing: return "signature"
        case .installing: return "square.and.arrow.down.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
    var byteText: String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        guard expectedBytes > 0 else { return received }
        return received + " / " + ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }
}
