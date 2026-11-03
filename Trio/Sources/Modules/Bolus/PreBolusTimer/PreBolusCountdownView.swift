import AudioToolbox
import SwiftUI

/// Home countdown "🍽️ 12:40" (mm:ss) while a pre-bolus timer is armed (`PreBolusNotifier.deadline`).
/// Battery: the seconds are drawn by the system (`Text(timerInterval:)`), the app runs no timer; the only
/// wake-up is one sleep until the deadline — and only while the row is visible.
/// Sits as an overlay at the bottom of the meal-panel slot, so the fixed Home layout never reflows.
/// Tap: a dialog "Valgau" (meal starts now) / "Atšaukti" (timer removed, nothing recorded) — no extra buttons in the slot.
struct PreBolusCountdownView: View {
    private let notifier = PreBolusNotifier.shared
    @State private var showDialog = false

    var body: some View {
        if let deadline = notifier.deadline {
            TimelineView(.explicit([deadline])) { context in
                let now = max(context.date, Date())
                if now < deadline {
                    Button {
                        showDialog = true
                    } label: {
                        HStack(spacing: 0) {
                            Text(verbatim: "🍽️ ")
                            Text(timerInterval: now ... deadline, countsDown: true)
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: "Laikas iki valgio"))
                }
            }
            .confirmationDialog(
                Text(verbatim: PreBolusConstants.dialogTitle),
                isPresented: $showDialog,
                titleVisibility: .visible
            ) {
                Button { notifier.markEating() } label: { Text(verbatim: PreBolusConstants.actionEating) }
                Button(role: .destructive) { notifier.cancel() } label: { Text(verbatim: PreBolusConstants.actionCancel) }
                Button(role: .cancel) {} label: { Text(verbatim: PreBolusConstants.actionClose) }
            } message: {
                Text(verbatim: PreBolusConstants.dialogMessage)
            }
            .task(id: deadline) {
                // Runs while Home shows the row; the loop-cycle hook covers the background.
                let wait = deadline.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                // Silent mode on screen: the banner may come without sound, so vibrate once — only right at the deadline.
                if notifier.isSilent, UIApplication.shared.applicationState == .active,
                   Date().timeIntervalSince(deadline) < 30
                {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
                notifier.finalizeIfExpired()
            }
        }
    }
}
