import Foundation
import Observation
import UserNotifications

/// The two `UNUserNotificationCenter` calls the timer uses (a protocol so tests can count them).
protocol PreBolusNotificationCenter: AnyObject {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: PreBolusNotificationCenter {}

/// The armed pre-bolus timer: one pending local notification ("Laikas valgyti") and `deadline`, which the
/// Home countdown reads — one source of truth. Armed at "Enact bolus" when the plan is a wait; removed when
/// that bolus fails (enactBolus callback false), when the user cancels a bolus (Cancel buttons pass
/// `cancelCallback`), or when a newer wait replaces it. A bolus without a wait (correction, eat now…) leaves a
/// running timer alone. Uses the notification permission Trio already holds; no AlertManager history, so
/// nothing replays after a restart.
@Observable final class PreBolusNotifier {
    static let shared = PreBolusNotifier(center: UNUserNotificationCenter.current())

    /// End of the armed wait; nil when nothing is armed.
    private(set) var deadline: Date?

    @ObservationIgnored private let center: PreBolusNotificationCenter
    @ObservationIgnored private var armID = UUID()

    init(center: PreBolusNotificationCenter) {
        self.center = center
    }

    /// The hook in `Treatments.StateModel.addPumpInsulin`: plans from the bolus screen's data and returns the
    /// callback to pass to `apsManager.enactBolus`. `glucose` is newest first; only the last hour is read.
    @MainActor func arm(carbs: Decimal, glucose: [GlucoseStored], now: Date = Date()) -> ((Bool, String) -> Void)? {
        let plan = PreBolusPlanner.plan(carbs: carbs, readings: PreBolusReading.from(Array(glucose.prefix(12))), now: now)
        return arm(plan: plan, now: now)
    }

    @MainActor func arm(plan: PreBolusPlan, now: Date = Date()) -> ((Bool, String) -> Void)? {
        guard case let .wait(minutes, until) = plan, minutes > 0 else { return nil }
        disarm() // a newer wait replaces the previous one

        let id = UUID()
        armID = id
        deadline = until

        let content = UNMutableNotificationContent()
        content.title = PreBolusConstants.notificationTitle
        content.body = PreBolusConstants.notificationBody
        content.sound = .default
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(until.timeIntervalSince(now), 1), repeats: false)
        center.add(
            UNNotificationRequest(identifier: PreBolusConstants.notificationIdentifier, content: content, trigger: trigger),
            withCompletionHandler: nil
        )

        return { [weak self] success, _ in
            guard !success else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.disarm(ifArmed: id) } }
        }
    }

    /// For `apsManager.cancelBolus(_:)` at the Cancel buttons: a successful cancel removes the timer.
    var cancelCallback: (Bool, String) -> Void {
        { [weak self] success, _ in
            guard success else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.disarm() } }
        }
    }

    @MainActor func disarm() {
        center.removePendingNotificationRequests(withIdentifiers: [PreBolusConstants.notificationIdentifier])
        deadline = nil
    }

    @MainActor private func disarm(ifArmed id: UUID) {
        guard armID == id, deadline != nil else { return }
        disarm()
    }
}
