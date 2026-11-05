import SwiftUI

/// Home row "🍽️ 12:40 iki valgio" with the buttons "Valgau" / "Atšaukti" while a pre-bolus timer is armed
/// (`PreBolusNotifier.deadline`). Its own slot of `height` under the meal panel, only while armed — the chart gives up
/// that height (`HomeRootView.mainChart`). The same countdown runs in the Live Activity (Dynamic Island, lock screen).
/// Battery: the seconds are drawn by the system (`Text(timerInterval:)`), the app runs no timer; the only wake-up is
/// one sleep until the deadline — and only while the row is visible.
/// "Valgau": the meal starts now. "Atšaukti": the timer is removed, nothing recorded.
struct PreBolusCountdownView: View {
    static let height: CGFloat = 56

    private let notifier = PreBolusNotifier.shared

    var body: some View {
        if let deadline = notifier.deadline {
            TimelineView(.explicit([deadline])) { context in
                let now = max(context.date, Date())
                HStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "🍽️")
                        if now < deadline {
                            Text(timerInterval: now ... deadline, countsDown: true)
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                                .fixedSize()
                            Text(verbatim: PreBolusConstants.textUntilMeal)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: PreBolusConstants.notificationTitle)
                                .font(.title3.weight(.bold))
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: "Laikas iki valgio"))

                    Spacer(minLength: 4)

                    Button { notifier.markEating() } label: { Text(verbatim: PreBolusConstants.actionEating) }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { notifier.cancel() } label: {
                        Text(verbatim: PreBolusConstants.actionCancel)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.callout.weight(.semibold)) // buttons: fits 375 pt with the timer
                .lineLimit(1)
                .padding(.horizontal, 16)
            }
            .frame(height: Self.height)
            .task(id: deadline) {
                // Runs while Home shows the row; the loop-cycle hook covers the background.
                let wait = deadline.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                notifier.finalizeIfExpired()
            }
        }
    }
}
