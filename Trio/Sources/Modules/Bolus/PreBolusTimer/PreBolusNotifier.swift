import Combine
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
/// that bolus fails before reaching the pump (enactBolus callback false without an `APSError.pumpError`;
/// a pump error means delivery is uncertain, so the reminder stays), when the user cancels a bolus (Cancel buttons pass
/// `cancelCallback`), or when a newer wait replaces it. A bolus without a wait (correction, eat now…) leaves a
/// running timer alone. Uses the notification permission Trio already holds; no AlertManager history, so
/// nothing replays after a restart.
@Observable final class PreBolusNotifier {
    static let shared = PreBolusNotifier(center: UNUserNotificationCenter.current())

    /// End of the armed wait; nil when nothing is armed.
    private(set) var deadline: Date?

    @ObservationIgnored private let center: PreBolusNotificationCenter
    @ObservationIgnored private var armID = UUID()
    /// The arm of the bolus enacted last; nil when that bolus had no wait (a correction). A Cancel only
    /// removes the timer when it cancels the bolus that armed it.
    @ObservationIgnored private var runningArmID: UUID?
    @ObservationIgnored private var errorSubscription: AnyCancellable?

    init(center: PreBolusNotificationCenter) {
        self.center = center
    }

    /// The hook in `Treatments.StateModel.addPumpInsulin`: plans from the bolus screen's data and returns the
    /// callback to pass to `apsManager.enactBolus`. `glucose` is newest first; only the last hour is read.
    @MainActor func arm(
        carbs: Decimal,
        glucose: [GlucoseStored],
        lastError: AnyPublisher<Error?, Never>,
        now: Date = Date()
    ) -> ((Bool, String) -> Void)? {
        let plan = PreBolusPlanner.plan(carbs: carbs, readings: PreBolusReading.from(Array(glucose.prefix(12))), now: now)
        return arm(plan: plan, lastError: lastError, now: now)
    }

    /// `lastError`: `apsManager.lastError`. Its pump-error path sends `APSError.pumpError` right before
    /// `callback(false)` (the command reached the pump: delivery uncertain); the pre-checks send
    /// `invalidPumpState` or nothing (no bolus was sent).
    @MainActor func arm(
        plan: PreBolusPlan,
        lastError: AnyPublisher<Error?, Never> = Empty().eraseToAnyPublisher(),
        now: Date = Date()
    ) -> ((Bool, String) -> Void)? {
        guard case let .wait(minutes, until) = plan, minutes > 0 else {
            runningArmID = nil // a bolus without a wait is running now; a Cancel of it keeps the timer
            return nil
        }
        disarm() // a newer wait replaces the previous one

        // Set synchronously on the thread that sends it, before that thread calls the callback.
        var pumpWasCommanded = false
        errorSubscription = lastError.dropFirst().sink { error in
            if let apsError = error as? APSError, case .pumpError = apsError { pumpWasCommanded = true }
        }

        let id = UUID()
        armID = id
        runningArmID = id
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
            let keep = success || pumpWasCommanded // uncertain delivery: keep the reminder
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.armID == id else { return }
                    self.errorSubscription = nil
                    if !keep { self.disarm(ifArmed: id) }
                }
            }
        }
    }

    /// For `apsManager.cancelBolus(_:)` at the Cancel buttons: a successful cancel of the bolus that armed the
    /// timer removes it; cancelling a later correction keeps the meal reminder.
    var cancelCallback: (Bool, String) -> Void {
        { [weak self] success, _ in
            guard success else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let running = self.runningArmID else { return }
                    self.disarm(ifArmed: running)
                }
            }
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
