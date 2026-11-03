import Combine
import Foundation
import Testing
import UserNotifications
@testable import Trio

private final class MockCenter: PreBolusNotificationCenter {
    var added: [UNNotificationRequest] = []
    var removed: [[String]] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        added.append(request)
        completionHandler?(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removed.append(identifiers)
    }
}

private final class MockReporter: TrioEventReporter {
    var events: [TrioEvent] = []

    func report(_ event: TrioEvent) {
        events.append(event)
    }
}

@Suite("Pre-bolus notifier") @MainActor struct PreBolusNotifierTests {
    let now = Date(timeIntervalSince1970: 1_793_640_000)

    /// Own UserDefaults per test: the armed timer is persisted, so the standard domain would leak between tests.
    private final class Fixture {
        let center = MockCenter()
        let reporter = MockReporter()
        let suiteName = "PreBolusNotifierTests.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suiteName)!
        lazy var notifier = makeNotifier()

        /// A fresh notifier on the same defaults — what a relaunch sees.
        func makeNotifier() -> PreBolusNotifier {
            let notifier = PreBolusNotifier(center: center, defaults: defaults)
            notifier.reporter = reporter
            return notifier
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    /// Lets the main queue run the `DispatchQueue.main.async` hops of the callbacks.
    func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func wait(_ minutes: Int) -> PreBolusPlan {
        .wait(minutes: minutes, until: now.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func minutes(_ value: Double) -> Date {
        now.addingTimeInterval(value * 60)
    }

    // MARK: - v1: arming and removal

    @Test("A wait schedules one notification at the end of the wait") func schedules() {
        let f = Fixture()
        let callback = f.notifier.arm(plan: wait(15), now: now)
        let hasCallback = callback != nil
        #expect(hasCallback)
        #expect(f.center.added.count == 1)
        let request = f.center.added.first
        #expect(request?.identifier == PreBolusConstants.notificationIdentifier)
        #expect(request?.content.title == "Laikas valgyti")
        #expect(request?.content.sound != nil)
        #expect((request?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 900)
        #expect(f.notifier.deadline == now.addingTimeInterval(900))
    }

    @Test("No-wait plans schedule nothing", arguments: [PreBolusPlan.hidden, .noData, .eatNow, .bolusWhileEating, .alreadyEating])
    func nothingScheduled(plan: PreBolusPlan) {
        let f = Fixture()
        let callback = f.notifier.arm(plan: plan, now: now)
        let isNil = callback == nil
        #expect(isNil)
        #expect(f.center.added.isEmpty)
        #expect(f.center.removed.isEmpty)
        #expect(f.notifier.deadline == nil)
    }

    @Test("A later bolus without a wait (e.g. a correction) leaves the running timer alone") func correctionKeepsTimer() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        _ = f.notifier.arm(plan: .hidden, now: now)
        #expect(f.center.removed.count == 1) // only the replace-clear of the first arm
        #expect(f.notifier.deadline == now.addingTimeInterval(900))
    }

    @Test("Failed bolus (callback false) removes it, without a meal start") func failed() async throws {
        let f = Fixture()
        let callback = f.notifier.arm(plan: wait(10), now: now)
        callback?(false, "Error! Failed to enact bolus.")
        try await settle()
        #expect(f.center.removed.count == 2) // the replace-clear inside arm, then the failure
        #expect(f.notifier.deadline == nil)
        #expect(f.reporter.events.isEmpty)
    }

    @Test("Pump error after the command (delivery uncertain) keeps the reminder") func uncertainDelivery() async throws {
        let f = Fixture()
        let lastError = CurrentValueSubject<Error?, Never>(nil)
        let callback = f.notifier.arm(plan: wait(10), lastError: lastError.eraseToAnyPublisher(), now: now)
        lastError.send(APSError.pumpError(NSError(domain: "pump", code: 1)))
        callback?(false, "Error! Bolus failed with error: …")
        try await settle()
        #expect(f.notifier.deadline == now.addingTimeInterval(600))
        #expect(f.center.removed.count == 1) // only the replace-clear inside arm
    }

    @Test("Pre-check failure (no bolus sent) removes it, also with a stale pump error from before") func preCheckFailure() async throws {
        let f = Fixture()
        let lastError = CurrentValueSubject<Error?, Never>(APSError.pumpError(NSError(domain: "old", code: 2)))
        let callback = f.notifier.arm(plan: wait(10), lastError: lastError.eraseToAnyPublisher(), now: now)
        lastError.send(APSError.invalidPumpState(message: "Pump suspended"))
        callback?(false, "Error! Failed to enact bolus.")
        try await settle()
        #expect(f.notifier.deadline == nil)
        #expect(f.center.removed.count == 2)
    }

    @Test("Successful enact keeps it") func succeeded() async throws {
        let f = Fixture()
        let callback = f.notifier.arm(plan: wait(10), now: now)
        callback?(true, "Bolus enacted successfully.")
        try await settle()
        #expect(f.center.removed.count == 1)
        #expect(f.notifier.deadline != nil)
    }

    @Test("Bolus Cancel button: a successful cancel removes it, a failed cancel keeps it; no meal start") func cancelBolus() async throws {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(10), now: now)
        f.notifier.cancelCallback(false, "Error! Bolus cancellation failed")
        try await settle()
        #expect(f.notifier.deadline != nil)
        f.notifier.cancelCallback(true, "Bolus cancelled successfully.")
        try await settle()
        #expect(f.notifier.deadline == nil)
        #expect(f.center.removed.count == 2)
        #expect(f.reporter.events.isEmpty)
    }

    @Test("Cancelling a later correction keeps the meal timer") func cancelCorrectionKeepsTimer() async throws {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        _ = f.notifier.arm(plan: .hidden, now: now) // correction enacted
        f.notifier.cancelCallback(true, "Bolus cancelled successfully.")
        try await settle()
        #expect(f.notifier.deadline == now.addingTimeInterval(900))
        #expect(f.center.removed.count == 1)
    }

    @Test("A newer wait replaces the previous timer; the old bolus failing late does not remove it") func replaces() async throws {
        let f = Fixture()
        let first = f.notifier.arm(plan: wait(10), now: now)
        _ = f.notifier.arm(plan: wait(20), now: now)
        #expect(f.center.added.count == 2)
        #expect(f.notifier.deadline == now.addingTimeInterval(1200))
        let removals = f.center.removed.count
        first?(false, "late failure")
        try await settle()
        #expect(f.center.removed.count == removals)
        #expect(f.notifier.deadline == now.addingTimeInterval(1200))
        #expect(f.reporter.events.isEmpty) // a replaced timer that had not run out records nothing
    }

    // MARK: - v2: meal start

    @Test("„Valgau“: meal starts now, notification removed, one event") func eatingButton() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        f.notifier.markEating(now: minutes(10.6))
        #expect(f.notifier.deadline == nil)
        #expect(f.center.removed.count == 2)
        #expect(f.reporter.events == [
            .mealStarted(at: minutes(10.6), bolusAt: now, plannedMin: 15, actualMin: 11, via: .button, mealType: "normal")
        ])
        f.notifier.markEating(now: minutes(11))
        f.notifier.finalizeIfExpired(now: minutes(30))
        #expect(f.reporter.events.count == 1)
    }

    @Test("Timer runs out: meal start = deadline, sent once, not before") func timerExpires() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        f.notifier.finalizeIfExpired(now: minutes(14.9))
        #expect(f.reporter.events.isEmpty)
        #expect(f.notifier.deadline != nil)
        f.notifier.finalizeIfExpired(now: minutes(19))
        #expect(f.reporter.events == [
            .mealStarted(at: minutes(15), bolusAt: now, plannedMin: 15, actualMin: 15, via: .timer, mealType: "normal")
        ])
        #expect(f.notifier.deadline == nil)
        f.notifier.finalizeIfExpired(now: minutes(25))
        #expect(f.reporter.events.count == 1)
    }

    @Test("„Valgau“ tapped after the deadline counts as the timer's end") func eatingAfterDeadline() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(10), now: now)
        f.notifier.markEating(now: minutes(12))
        #expect(f.reporter.events == [
            .mealStarted(at: minutes(10), bolusAt: now, plannedMin: 10, actualMin: 10, via: .timer, mealType: "normal")
        ])
    }

    @Test("„Atšaukti“: timer and notification removed, nothing recorded, later finalize does nothing") func cancelTimer() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        f.notifier.cancel()
        #expect(f.notifier.deadline == nil)
        #expect(f.center.removed.count == 2)
        f.notifier.finalizeIfExpired(now: minutes(30))
        #expect(f.reporter.events.isEmpty)
        #expect(f.defaults.data(forKey: PreBolusConstants.armedTimerKey) == nil)
        #expect(f.makeNotifier().deadline == nil)
    }

    @Test("A new wait after an expired, unreported timer first reports the old meal") func expiredThenNewArm() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(10), now: now)
        let later = minutes(120)
        _ = f.notifier.arm(plan: .wait(minutes: 5, until: later.addingTimeInterval(300)), now: later)
        #expect(f.reporter.events == [
            .mealStarted(at: minutes(10), bolusAt: now, plannedMin: 10, actualMin: 10, via: .timer, mealType: "normal")
        ])
        #expect(f.notifier.deadline == later.addingTimeInterval(300))
    }

    @Test("Relaunch: an armed timer is restored and reported once by the new instance") func relaunch() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        let relaunched = f.makeNotifier()
        #expect(relaunched.deadline == now.addingTimeInterval(900))
        relaunched.finalizeIfExpired(now: minutes(40))
        #expect(f.reporter.events == [
            .mealStarted(at: minutes(15), bolusAt: now, plannedMin: 15, actualMin: 15, via: .timer, mealType: "normal")
        ])
        #expect(f.makeNotifier().deadline == nil)
    }

    @Test("Relaunch: a bolus Cancel (another bolus by then) keeps the restored timer; „Atšaukti“ removes it")
    func relaunchCancelBolus() async throws {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        let relaunched = f.makeNotifier()
        relaunched.cancelCallback(true, "Bolus cancelled successfully.")
        try await settle()
        #expect(relaunched.deadline == now.addingTimeInterval(900))
        relaunched.cancel()
        #expect(relaunched.deadline == nil)
    }

    @Test("Found more than 6 h after the deadline: ends without a meal start") func tooLate() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(15), now: now)
        f.notifier.finalizeIfExpired(now: minutes(15 + 6 * 60 + 1))
        #expect(f.reporter.events.isEmpty)
        #expect(f.notifier.deadline == nil)
    }

    // MARK: - Food type

    @Test("Food type: „Įprastas“ by default, a pick holds 30 min") func mealTypePick() {
        let f = Fixture()
        #expect(f.notifier.mealType(now: now) == .normal)
        f.notifier.pickMealType(.slow, now: now)
        #expect(f.notifier.mealType(now: minutes(29)) == .slow)
        #expect(f.notifier.mealType(now: minutes(31)) == .normal)
    }

    @Test("Food type: a meal bolus uses the pick up (any plan for carbs); a no-carbs bolus keeps it") func mealTypeReset() {
        let f = Fixture()
        f.notifier.pickMealType(.fast, now: now)
        _ = f.notifier.arm(plan: .hidden, now: now) // correction without carbs
        #expect(f.notifier.mealType(now: now) == .fast)
        _ = f.notifier.arm(plan: .eatNow, mealType: .fast, now: now)
        #expect(f.notifier.mealType(now: now) == .normal)
    }

    @Test("A timer saved without a food type (older build) restores as „normal“") func legacyArmedTimer() throws {
        let f = Fixture()
        let legacy = #"{"deadline":0,"bolusAt":-900,"plannedMinutes":15}"#
        f.defaults.set(Data(legacy.utf8), forKey: PreBolusConstants.armedTimerKey)
        let notifier = f.makeNotifier()
        #expect(notifier.deadline == Date(timeIntervalSinceReferenceDate: 0))
        notifier.finalizeIfExpired(now: Date(timeIntervalSinceReferenceDate: 60))
        #expect(f.reporter.events == [.mealStarted(
            at: Date(timeIntervalSinceReferenceDate: 0), bolusAt: Date(timeIntervalSinceReferenceDate: -900),
            plannedMin: 15, actualMin: 15, via: .timer, mealType: "normal"
        )])
    }

    @Test("Food type goes into meal_started and survives a relaunch") func mealTypeInEvent() {
        let f = Fixture()
        _ = f.notifier.arm(plan: wait(20), mealType: .fatty, now: now)
        f.makeNotifier().finalizeIfExpired(now: minutes(21))
        #expect(f.reporter.events == [
            .mealStarted(at: minutes(20), bolusAt: now, plannedMin: 20, actualMin: 20, via: .timer, mealType: "fatty")
        ])
    }

    // MARK: - v2: silent reminder

    @Test("Silent reminder: off by default; on uses the silent sound file, never no sound") func silentSetting() {
        let f = Fixture()
        #expect(f.notifier.isSilent == false)
        #expect(PreBolusNotifier.soundName(silent: false) == nil)
        f.defaults.set(true, forKey: PreBolusConstants.silentReminderKey)
        #expect(f.notifier.isSilent)
        #expect(PreBolusNotifier.soundName(silent: true) == "prebolus_silent.caf")
        _ = f.notifier.arm(plan: wait(10), now: now)
        let request = f.center.added.first
        #expect(request?.content.sound != nil)
        #expect(request?.content.interruptionLevel == .active)
    }

    @Test("The silent sound file is in the app bundle") func silentSoundBundled() {
        #expect(Bundle.main.url(forResource: "prebolus_silent", withExtension: "caf") != nil)
    }
}
