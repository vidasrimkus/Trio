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

@Suite("Pre-bolus notifier") @MainActor struct PreBolusNotifierTests {
    let now = Date(timeIntervalSince1970: 1_793_640_000)

    /// Lets the main queue run the `receive(on:)` / `DispatchQueue.main.async` hops.
    func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func armed(_ plan: PreBolusPlan) -> (MockCenter, PreBolusNotifier, CurrentValueSubject<Decimal?, Never>, ((Bool, String) -> Void)?) {
        let center = MockCenter()
        let notifier = PreBolusNotifier(center: center)
        let progress = CurrentValueSubject<Decimal?, Never>(nil)
        let callback = notifier.arm(plan: plan, bolusProgress: progress.eraseToAnyPublisher(), now: now)
        return (center, notifier, progress, callback)
    }

    @Test("A wait schedules one notification at the end of the wait") func schedules() {
        let (center, notifier, _, callback) = armed(.wait(minutes: 15, until: now.addingTimeInterval(900)))
        #expect(callback != nil)
        #expect(center.added.count == 1)
        let request = center.added.first
        #expect(request?.identifier == PreBolusConstants.notificationIdentifier)
        #expect(request?.content.title == "Laikas valgyti")
        #expect((request?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 900)
        #expect(notifier.deadline == now.addingTimeInterval(900))
    }

    @Test("No timer cases schedule nothing", arguments: [PreBolusPlan.hidden, .noData, .eatNow, .alreadyEating])
    func nothingScheduled(plan: PreBolusPlan) {
        let (center, notifier, _, callback) = armed(plan)
        #expect(callback == nil)
        #expect(center.added.isEmpty)
        #expect(notifier.deadline == nil)
    }

    @Test("Failed bolus (callback false) removes it") func failed() async throws {
        let (center, notifier, _, callback) = armed(.wait(minutes: 10, until: now.addingTimeInterval(600)))
        let removalsAfterArm = center.removed.count
        callback?(false, "Error! Failed to enact bolus.")
        try await settle()
        #expect(center.removed.count == removalsAfterArm + 1)
        #expect(notifier.deadline == nil)
    }

    @Test("Successful enact keeps it") func succeeded() async throws {
        let (center, notifier, _, callback) = armed(.wait(minutes: 10, until: now.addingTimeInterval(600)))
        let removalsAfterArm = center.removed.count
        callback?(true, "Bolus enacted successfully.")
        try await settle()
        #expect(center.removed.count == removalsAfterArm)
        #expect(notifier.deadline != nil)
    }

    @Test("Cancelled bolus (progress ends below 100 %) removes it") func cancelled() async throws {
        let (center, notifier, progress, _) = armed(.wait(minutes: 10, until: now.addingTimeInterval(600)))
        let removalsAfterArm = center.removed.count
        progress.send(0)
        progress.send(0.4)
        progress.send(nil)
        try await settle()
        #expect(center.removed.count == removalsAfterArm + 1)
        #expect(notifier.deadline == nil)
    }

    @Test("Finished bolus (progress reaches 100 %) keeps it") func finished() async throws {
        let (center, notifier, progress, _) = armed(.wait(minutes: 10, until: now.addingTimeInterval(600)))
        let removalsAfterArm = center.removed.count
        progress.send(0)
        progress.send(1)
        progress.send(nil)
        try await settle()
        #expect(center.removed.count == removalsAfterArm)
        #expect(notifier.deadline != nil)
    }

    @Test("A new bolus replaces the previous timer") func replaces() async throws {
        let (center, notifier, progress, firstCallback) = armed(.wait(minutes: 10, until: now.addingTimeInterval(600)))
        let second = notifier.arm(plan: .wait(minutes: 20, until: now.addingTimeInterval(1200)), bolusProgress: progress.eraseToAnyPublisher(), now: now)
        #expect(second != nil)
        #expect(center.added.count == 2)
        #expect(notifier.deadline == now.addingTimeInterval(1200))
        // the first bolus failing late must not remove the second timer
        let removals = center.removed.count
        firstCallback?(false, "late failure")
        try await settle()
        #expect(center.removed.count == removals)
        #expect(notifier.deadline == now.addingTimeInterval(1200))
    }
}
