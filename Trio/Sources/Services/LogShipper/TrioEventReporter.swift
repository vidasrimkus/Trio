import Combine
import Foundation
import Swinject

/// Sends `TrioEvent`s as Nightscout Notes through the existing `uploadNoteTreatment` path and
/// writes the same line into Trio's log (so it also reaches the server with the next shipment).
///
/// Sources, none of which required a change in `APSManager`:
/// - `apsManager.lastError` — every loop / pump error (`processError`, `enactBolus`, `cancelBolus`).
/// - `BolusFailureObserver.bolusDidFail()` — manual bolus failures (`enactBolus`, `isSMB == false`).
/// - `report(_:)` — called by History when a bolus is deleted.
///
/// A manual bolus failure arrives as a `lastError` followed by `bolusDidFail()` on the main queue a
/// moment later, so a `lastError` is held for a short time: if `bolusDidFail()` follows, one
/// `bolus_failed kind=manual` Note goes out instead of a `pump_error` plus a `bolus_failed`.
protocol TrioEventReporter: AnyObject {
    func report(_ event: TrioEvent)
}

final class BaseTrioEventReporter: TrioEventReporter, Injectable, BolusFailureObserver {
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var apsManager: APSManager!
    @Injected() private var broadcaster: Broadcaster!

    enum Config {
        static let throttleWindow: TimeInterval = 30 * 60
        /// How long a `lastError` waits for a `bolusDidFail()`; the pairing window is the same value.
        static let holdInterval: TimeInterval = 3
        static let pairingWindow: TimeInterval = holdInterval
    }

    private let queue = DispatchQueue(label: "BaseTrioEventReporter.queue")
    private var throttle = EventThrottle(window: Config.throttleWindow)
    private var pending: (text: String, at: Date)?
    private var generation = 0
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        broadcaster.register(BolusFailureObserver.self, observer: self)
        apsManager.lastError
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] error in self?.errorOccurred(error) }
            .store(in: &subscriptions)
    }

    func report(_ event: TrioEvent) {
        queue.async { self.emit(event) }
    }

    // MARK: - BolusFailureObserver

    func bolusDidFail() {
        queue.async {
            let now = Date()
            if let pending = self.pending, now.timeIntervalSince(pending.at) <= Config.pairingWindow {
                self.pending = nil
                self.generation += 1
                self.emit(.bolusFailed(kind: .manual, error: pending.text))
            } else {
                self.emit(.bolusFailed(kind: .manual, error: nil))
            }
        }
    }

    // MARK: - Private

    private func errorOccurred(_ error: Error) {
        let text = error.localizedDescription
        queue.async {
            // A second error inside the hold (e.g. SMB enact failure, then the loop's own failure)
            // must not swallow the first one.
            if let previous = self.pending, previous.text != text {
                self.emit(.pumpError(error: previous.text))
            }
            self.pending = (text, Date())
            self.generation += 1
            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + Config.holdInterval) {
                guard generation == self.generation, let pending = self.pending else { return }
                self.pending = nil
                self.emit(.pumpError(error: pending.text))
            }
        }
    }

    private func emit(_ event: TrioEvent) {
        let note = TrioEventNote.format(event)
        if case .pumpError = event, !throttle.allow(note) {
            return
        }
        debug(.service, note)
        let nightscoutManager = self.nightscoutManager
        Task {
            await nightscoutManager?.uploadNoteTreatment(note: note)
        }
    }
}
