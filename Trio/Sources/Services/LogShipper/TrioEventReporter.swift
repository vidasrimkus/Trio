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
        /// How long a `lastError` waits for a `bolusDidFail()` before it goes out as `pump_error`.
        static let holdInterval: TimeInterval = 3
        /// A `bolusDidFail()` that comes later than the hold (busy main thread) still names the
        /// most recent error if it is this fresh; the `pump_error` already sent stays.
        static let pairingWindow: TimeInterval = 30
    }

    private let queue = DispatchQueue(label: "BaseTrioEventReporter.queue")
    private var throttle = EventThrottle(window: Config.throttleWindow)
    private var pending: (text: String, at: Date)?
    private var lastError: (text: String, at: Date)?
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
            if let pending = self.pending {
                self.pending = nil
                self.lastError = nil
                self.generation += 1
                self.emit(.bolusFailed(error: pending.text))
            } else if let last = self.lastError, now.timeIntervalSince(last.at) <= Config.pairingWindow {
                self.lastError = nil
                self.emit(.bolusFailed(error: last.text))
            } else {
                self.emit(.bolusFailed(error: nil))
            }
        }
    }

    // MARK: - Private

    private func errorOccurred(_ error: Error) {
        let text = error.localizedDescription
        // Only the errors `enactBolus` itself sends can belong to a manual bolus failure
        // (`pumpError` from the pump, `invalidPumpState` from `verifyStatus`). Anything else
        // (glucose, algorithm, manual temp) goes out at once and never displaces a held one.
        let pairable: Bool = {
            guard let apsError = error as? APSError else { return false }
            switch apsError {
            case .invalidPumpState,
                 .pumpError: return true
            default: return false
            }
        }()
        queue.async {
            guard pairable else {
                self.emit(.pumpError(error: text))
                return
            }
            // A second pairable error inside the hold (e.g. the loop's own failure right after a
            // bolus error) goes out at once as pump_error (the throttle dedupes the same text);
            // the held one stays, because a pending bolusDidFail() belongs to the earlier error.
            if self.pending != nil {
                self.emit(.pumpError(error: text))
                return
            }
            self.pending = (text, Date())
            self.lastError = self.pending
            self.generation += 1
            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + Config.holdInterval) {
                guard generation == self.generation, let pending = self.pending else { return }
                self.pending = nil
                // `lastError` stays: a bolusDidFail() that arrives after the hold (busy main
                // thread) still names this error, so the Note carries the cause.
                self.emit(.pumpError(error: pending.text))
            }
        }
    }

    private func emit(_ event: TrioEvent) {
        let note = TrioEventNote.format(event)
        if case let .pumpError(text) = event, !throttle.allow(TrioEventNote.throttleKey(forPumpError: text)) {
            return
        }
        debug(.service, note)
        let nightscoutManager = self.nightscoutManager
        Task {
            await nightscoutManager?.uploadNoteTreatment(note: note)
        }
    }
}
