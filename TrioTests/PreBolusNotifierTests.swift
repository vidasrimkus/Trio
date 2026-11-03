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

@Suite("Pre-bolus notifier") @MainActor struct PreBolusNotifierTests {
    let now = Date(timeIntervalSince1970: 1_793_640_000)

    /// Lets the main queue run the `DispatchQueue.main.async` hops of the callbacks.
    func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func wait(_ minutes: Int) -> PreBolusPlan {
        .wait(minutes: minutes, until: now.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    @Test("A wait schedules one notification at the end of the wait") func schedules() {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        let callback = notifier.arm(plan: wait(15), now: now)
        let hasCallback = callback != nil
        #expect(hasCallback)
        #expect(center.added.count == 1)
        let request = center.added.first
        #expect(request?.identifier == PreBolusConstants.notificationIdentifier)
        #expect(request?.content.title == "Laikas valgyti")
        #expect((request?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 900)
        #expect(notifier.deadline == now.addingTimeInterval(900))
    }

    @Test("No-wait plans schedule nothing", arguments: [PreBolusPlan.hidden, .noData, .eatNow, .alreadyEating])
    func nothingScheduled(plan: PreBolusPlan) {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        let callback = notifier.arm(plan: plan, now: now)
        let isNil = callback == nil
        #expect(isNil)
        #expect(center.added.isEmpty)
        #expect(center.removed.isEmpty)
        #expect(notifier.deadline == nil)
    }

    @Test("A later bolus without a wait (e.g. a correction) leaves the running timer alone") func correctionKeepsTimer() {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        _ = notifier.arm(plan: wait(15), now: now)
        _ = notifier.arm(plan: .hidden, now: now)
        #expect(center.removed.count == 1) // only the replace-clear of the first arm
        #expect(notifier.deadline == now.addingTimeInterval(900))
    }

    @Test("Failed bolus (callback false) removes it") func failed() async throws {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        let callback = notifier.arm(plan: wait(10), now: now)
        callback?(false, "Error! Failed to enact bolus.")
        try await settle()
        #expect(center.removed.count == 2) // the replace-clear inside arm, then the failure
        #expect(notifier.deadline == nil)
    }

    @Test("Successful enact keeps it") func succeeded() async throws {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        let callback = notifier.arm(plan: wait(10), now: now)
        callback?(true, "Bolus enacted successfully.")
        try await settle()
        #expect(center.removed.count == 1)
        #expect(notifier.deadline != nil)
    }

    @Test("Cancel button: a successful cancel removes it, a failed cancel keeps it") func cancel() async throws {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        _ = notifier.arm(plan: wait(10), now: now)
        notifier.cancelCallback(false, "Error! Bolus cancellation failed")
        try await settle()
        #expect(notifier.deadline != nil)
        notifier.cancelCallback(true, "Bolus cancelled successfully.")
        try await settle()
        #expect(notifier.deadline == nil)
        #expect(center.removed.count == 2)
    }

    @Test("Cancelling a later correction keeps the meal timer") func cancelCorrectionKeepsTimer() async throws {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        _ = notifier.arm(plan: wait(15), now: now)
        _ = notifier.arm(plan: .hidden, now: now) // correction enacted
        notifier.cancelCallback(true, "Bolus cancelled successfully.")
        try await settle()
        #expect(notifier.deadline == now.addingTimeInterval(900))
        #expect(center.removed.count == 1)
    }

    @Test("A newer wait replaces the previous timer; the old bolus failing late does not remove it") func replaces() async throws {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        let first = notifier.arm(plan: wait(10), now: now)
        _ = notifier.arm(plan: wait(20), now: now)
        #expect(center.added.count == 2)
        #expect(notifier.deadline == now.addingTimeInterval(1200))
        let removals = center.removed.count
        first?(false, "late failure")
        try await settle()
        #expect(center.removed.count == removals)
        #expect(notifier.deadline == now.addingTimeInterval(1200))
    }
}
