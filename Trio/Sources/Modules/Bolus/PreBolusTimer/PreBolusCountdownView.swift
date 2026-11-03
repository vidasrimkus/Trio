import SwiftUI

/// Home countdown "🍽️ 12:40" (mm:ss) while a pre-bolus timer is armed (`PreBolusNotifier.deadline`).
/// Battery: the seconds are drawn by the system (`Text(timerInterval:)`), the app runs no timer; the only
/// wake-up is one `TimelineView` entry at the deadline to remove the row — and only while it is visible.
/// Sits as an overlay at the bottom of the meal-panel slot, so the fixed Home layout never reflows.
struct PreBolusCountdownView: View {
    private let notifier = PreBolusNotifier.shared

    var body: some View {
        if let deadline = notifier.deadline {
            TimelineView(.explicit([deadline])) { context in
                let now = max(context.date, Date())
                if now < deadline {
                    (Text("🍽️ ") + Text(timerInterval: now ... deadline, countsDown: true))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .offset(y: 6)
                        .accessibilityLabel(Text("Laikas iki valgio"))
                }
            }
        }
    }
}
