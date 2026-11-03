import Foundation
import Testing
@testable import Trio

@Suite("Pre-bolus planner") struct PreBolusPlannerTests {
    let now = Date(timeIntervalSince1970: 1_793_640_000) // fixed clock

    /// mg/dL whose `asMmolL` (what Trio shows) is exactly `mmol`. Searched, not computed: converting the
    /// long-mantissa quotient through NSDecimalNumber → Int is unreliable.
    func mg(_ mmol: String) -> Int {
        guard let target = Decimal(string: mmol, locale: Locale(identifier: "en_US_POSIX")),
              let found = (0 ... 700).first(where: { $0.asMmolL == target })
        else {
            Issue.record("no mg/dL value shows as \(mmol) mmol/L")
            return 0
        }
        return found
    }

    /// Readings every 5 min ending at `now`, oldest first: e.g. ["5.3", "5.2", "5.1", "5.0"].
    func series(_ mmol: [String], newestAgo: TimeInterval = 0) -> [PreBolusReading] {
        mmol.enumerated().map { i, value in
            PreBolusReading(
                date: now.addingTimeInterval(-newestAgo - TimeInterval((mmol.count - 1 - i) * 5 * 60)),
                mgdl: mg(value)
            )
        }
    }

    func minutes(_ plan: PreBolusPlan) -> Int? {
        if case let .wait(m, _) = plan { return m }
        return nil
    }

    func plan(_ mmol: [String], carbs: Decimal = 40) -> PreBolusPlan {
        PreBolusPlanner.plan(carbs: carbs, readings: series(mmol), now: now)
    }

    @Test("Conversion matches what Trio shows: 90 mg/dL is 5.0") func conversion() {
        #expect(90.asMmolL == 5.0)
        #expect(mg("5.0") == 90)
    }

    @Test("No carbs: nothing shown") func noCarbs() {
        #expect(plan(["6.0", "6.0", "6.0", "6.0"], carbs: 0) == .hidden)
    }

    @Test("Stale CGM: no advice") func stale() {
        let readings = series(["7.0", "7.0", "7.0", "7.0"], newestAgo: 11 * 60)
        #expect(PreBolusPlanner.plan(carbs: 40, readings: readings, now: now) == .noData)
        #expect(PreBolusPlanner.plan(carbs: 40, readings: [], now: now) == .noData)
    }

    @Test("Below 5.0: eat now, even when rising") func eatNow() {
        #expect(plan(["4.9", "4.9", "4.9", "4.9"]) == .eatNow)
        #expect(plan(["3.8", "3.9", "4.0", "4.6"]) == .eatNow)
    }

    @Test("Low band 5.0–6.5") func lowBand() {
        #expect(minutes(plan(["5.0", "5.0", "5.0", "5.0"])) == 10)
        #expect(minutes(plan(["5.3", "5.2", "5.1", "5.0"])) == 5) // −0.3 per 15 min: falling
        #expect(minutes(plan(["5.2", "5.1", "5.1", "5.0"])) == 10) // −0.2: not falling
        #expect(minutes(plan(["6.7", "6.6", "6.5", "6.4"])) == 5)
        #expect(minutes(plan(["6.4", "6.4", "6.4", "6.4"])) == 10)
    }

    @Test("Middle band 6.5–9.0") func middleBand() {
        #expect(minutes(plan(["6.5", "6.5", "6.5", "6.5"])) == 15)
        #expect(minutes(plan(["6.8", "6.7", "6.6", "6.5"])) == 10)
        #expect(minutes(plan(["9.0", "9.0", "9.0", "9.0"])) == 15)
        #expect(minutes(plan(["9.3", "9.2", "9.1", "9.0"])) == 10)
    }

    @Test("High band above 9.0: 20 min whatever the trend") func highBand() {
        #expect(minutes(plan(["9.1", "9.1", "9.1", "9.1"])) == 20)
        #expect(minutes(plan(["14.6", "14.4", "14.2", "14.0"])) == 20)
    }

    @Test("Rise over 0.5 in 10 min: already eating, no timer") func alreadyEating() {
        #expect(plan(["7.0", "7.0", "7.0", "7.6"]) == .alreadyEating) // +0.6
        #expect(minutes(plan(["7.0", "7.0", "7.0", "7.5"])) == 15) // +0.5 is not over 0.5
        #expect(plan(["11.0", "11.0", "11.2", "11.8"]) == .alreadyEating)
    }

    @Test("No reading 15 min back: treated as falling (shorter wait)") func unknownTrend() {
        #expect(minutes(plan(["7.0", "7.0"])) == 10)
        #expect(minutes(plan(["5.5"])) == 5)
    }

    @Test("Wait ends now + minutes; never above the cap") func untilAndCap() {
        guard case let .wait(m, until) = plan(["8.0", "8.0", "8.0", "8.0"]) else {
            Issue.record("expected a wait")
            return
        }
        #expect(m == 15)
        #expect(until == now.addingTimeInterval(15 * 60))
        for value in ["5.0", "6.5", "9.0", "9.1", "22.0"] {
            #expect((minutes(plan([value, value, value, value])) ?? 0) <= PreBolusConstants.maxMinutes)
        }
    }

    @Test("Row texts") func texts() {
        #expect(PreBolusTimerRow.text(for: .hidden) == nil)
        #expect(PreBolusTimerRow.text(for: .eatNow) == "🍽️ Valgyk iškart")
        #expect(PreBolusTimerRow.text(for: .alreadyEating) == "Atrodo, jau valgai – kitą kartą bolusas anksčiau")
        #expect(PreBolusTimerRow.text(for: .wait(minutes: 15, until: now))?.hasPrefix("🍽️ Valgyk po 15 min (") == true)
    }
}
