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
/// Home countdown reads — one source of truth. Armed at "Enact bolus"; disarmed when the bolus fails
/// (enactBolus callback false), is cancelled (`bolusProgress` ends below 100 %) or a new bolus is armed.
/// Uses the notification permission Trio already holds; no AlertManager history, so nothing replays.
@Observable final class PreBolusNotifier {
    static let shared = PreBolusNotifier(center: UNUserNotificationCenter.current())

    /// End of the armed wait; nil when nothing is armed.
    private(set) var deadline: Date?

    @ObservationIgnored private let center: PreBolusNotificationCenter
    @ObservationIgnored private var progressSubscription: AnyCancellable?
    @ObservationIgnored private var armID = UUID()

    init(center: PreBolusNotificationCenter) {
        self.center = center
    }

    /// The hook in `Treatments.StateModel.addPumpInsulin`: plans from the bolus screen's data and returns the
    /// callback to pass to `apsManager.enactBolus`.
    @MainActor func arm(
        carbs: Decimal,
        glucose: [GlucoseStored],
        apsManager: APSManager,
        now: Date = Date()
    ) -> ((Bool, String) -> Void)? {
        let plan = PreBolusPlanner.plan(carbs: carbs, readings: PreBolusReading.from(glucose), now: now)
        return arm(plan: plan, bolusProgress: apsManager.bolusProgress.eraseToAnyPublisher(), now: now)
    }

    @MainActor func arm(
        plan: PreBolusPlan,
        bolusProgress: AnyPublisher<Decimal?, Never>,
        now: Date = Date()
    ) -> ((Bool, String) -> Void)? {
        disarm()
        guard case let .wait(minutes, until) = plan, minutes > 0 else { return nil }

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

        // A cancelled bolus ends with progress < 1 followed by nil; a finished one reports 1 first.
        var last: Decimal?
        progressSubscription = bolusProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                if let progress {
                    last = progress
                } else if let finalProgress = last {
                    // delivered on the main queue (receive(on:) above)
                    MainActor.assumeIsolated {
                        if finalProgress < 1 { self?.disarm(ifArmed: id) }
                        self?.progressSubscription = nil
                    }
                }
            }

        return { [weak self] success, _ in
            guard !success else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.disarm(ifArmed: id) } }
        }
    }

    @MainActor func disarm() {
        center.removePendingNotificationRequests(withIdentifiers: [PreBolusConstants.notificationIdentifier])
        deadline = nil
        progressSubscription = nil
    }

    @MainActor private func disarm(ifArmed id: UUID) {
        guard armID == id, deadline != nil else { return }
        disarm()
    }
}
