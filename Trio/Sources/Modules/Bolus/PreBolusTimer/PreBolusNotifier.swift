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

/// What is armed, kept in UserDefaults so a relaunch restores the countdown and still reports the meal start.
struct PreBolusArmedTimer: Codable, Equatable {
    let deadline: Date
    /// When "Enact bolus" was tapped.
    let bolusAt: Date
    let plannedMinutes: Int
}

/// The armed pre-bolus timer: one pending local notification ("Laikas valgyti") and `deadline`, which the
/// Home countdown reads — one source of truth. Armed at "Enact bolus" when the plan is a wait; removed when
/// that bolus fails before reaching the pump (enactBolus callback false without an `APSError.pumpError`;
/// a pump error means delivery is uncertain, so the reminder stays), when the user cancels a bolus (Cancel buttons pass
/// `cancelCallback`), or when a newer wait replaces it. A bolus without a wait (correction, eat now…) leaves a
/// running timer alone. Uses the notification permission Trio already holds; no AlertManager history, so
/// no alert replays after a restart.
///
/// v2: the meal start. "Valgau" on the Home countdown (`markEating`) or the timer running out (`finalizeIfExpired`,
/// called at the deadline while Home is visible and after every loop cycle) sends one `meal_started` event;
/// "Atšaukti" (`cancel`) and every removal above send nothing.
@Observable final class PreBolusNotifier {
    static let shared = PreBolusNotifier(center: UNUserNotificationCenter.current())

    /// End of the armed wait; nil when nothing is armed.
    private(set) var deadline: Date?

    /// Set by `BaseTrioEventReporter` when it starts; nil in tests unless a mock is set.
    @ObservationIgnored weak var reporter: TrioEventReporter?

    @ObservationIgnored private let center: PreBolusNotificationCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var armed: PreBolusArmedTimer?
    @ObservationIgnored private var armID = UUID()
    /// The arm of the bolus enacted last; nil when that bolus had no wait (a correction). A Cancel only
    /// removes the timer when it cancels the bolus that armed it.
    @ObservationIgnored private var runningArmID: UUID?
    @ObservationIgnored private var errorSubscription: AnyCancellable?

    init(center: PreBolusNotificationCenter, defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        if let data = defaults.data(forKey: PreBolusConstants.armedTimerKey),
           let restored = try? JSONDecoder().decode(PreBolusArmedTimer.self, from: data)
        {
            armed = restored
            deadline = restored.deadline
            // After a relaunch, Cancel buttons can still remove the timer of the bolus that armed it.
            runningArmID = armID
        }
    }

    /// "Tylus priminimas": vibration only.
    var isSilent: Bool { defaults.bool(forKey: PreBolusConstants.silentReminderKey) }

    /// The notification sound file: the silent one in silent mode, nil = the default sound. Never `sound = nil`:
    /// without a sound iOS shows the banner without vibrating.
    static func soundName(silent: Bool) -> String? {
        silent ? PreBolusConstants.silentSoundName : nil
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
        finalizeIfExpired(now: now) // an earlier timer that already ran out still reports its meal
        disarm() // a newer wait replaces the previous one

        // Set synchronously on the thread that sends it, before that thread calls the callback.
        var pumpWasCommanded = false
        errorSubscription = lastError.dropFirst().sink { error in
            if let apsError = error as? APSError, case .pumpError = apsError { pumpWasCommanded = true }
        }

        let id = UUID()
        armID = id
        runningArmID = id
        store(PreBolusArmedTimer(deadline: until, bolusAt: now, plannedMinutes: minutes))

        let content = UNMutableNotificationContent()
        content.title = PreBolusConstants.notificationTitle
        content.body = PreBolusConstants.notificationBody
        content.sound = Self.soundName(silent: isSilent).map { UNNotificationSound(named: UNNotificationSoundName($0)) } ??
            .default
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

    /// "Valgau": the meal starts now. Ends the timer and removes the pending notification. Once the deadline has
    /// passed this is the timer's own end (`at` = deadline, `via=timer`).
    @MainActor func markEating(now: Date = Date()) {
        guard let armed else { return }
        if now >= armed.deadline {
            finalizeIfExpired(now: now)
            return
        }
        disarm()
        report(armed, at: now, via: .button)
    }

    /// "Atšaukti": removes the timer and its notification; no meal start is recorded.
    @MainActor func cancel() {
        guard armed != nil else { return }
        disarm()
    }

    /// The timer ran out: the meal started at the deadline. Sends `meal_started via=timer` once; does nothing before
    /// the deadline. Leaves the delivered notification on screen. Found more than `maxReplayAge` late: ends silently.
    @MainActor func finalizeIfExpired(now: Date = Date()) {
        guard let armed, now >= armed.deadline else { return }
        disarm()
        if now.timeIntervalSince(armed.deadline) <= PreBolusConstants.maxReplayAge {
            report(armed, at: armed.deadline, via: .timer)
        }
    }

    @MainActor func disarm() {
        center.removePendingNotificationRequests(withIdentifiers: [PreBolusConstants.notificationIdentifier])
        store(nil)
    }

    @MainActor private func disarm(ifArmed id: UUID) {
        guard armID == id, deadline != nil else { return }
        disarm()
    }

    private func store(_ timer: PreBolusArmedTimer?) {
        armed = timer
        deadline = timer?.deadline
        if let timer, let data = try? JSONEncoder().encode(timer) {
            defaults.set(data, forKey: PreBolusConstants.armedTimerKey)
        } else {
            defaults.removeObject(forKey: PreBolusConstants.armedTimerKey)
        }
    }

    private func report(_ timer: PreBolusArmedTimer, at: Date, via: TrioEvent.MealStartVia) {
        let actual = max(Int((at.timeIntervalSince(timer.bolusAt) / 60).rounded()), 0)
        reporter?.report(.mealStarted(
            at: at,
            bolusAt: timer.bolusAt,
            plannedMin: timer.plannedMinutes,
            actualMin: actual,
            via: via
        ))
    }
}
