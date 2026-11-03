import Foundation
import Testing
@testable import Trio

/// The user's pre-bolus system (CUSTOMIZATIONS §10): wait = max(round(BG × 1.8), base by food type), then the
/// 15-min trend correction; safety rules first; cap 35 min.
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

    func d(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }

    /// Readings every 5 min ending at `now`, oldest first: e.g. ["8.3", "8.2", "8.1", "8.0"] = −0.3 over 15 min.
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

    func plan(_ mmol: [String], _ type: PreBolusMealType = .normal, carbs: Decimal = 40) -> PreBolusPlan {
        PreBolusPlanner.plan(carbs: carbs, readings: series(mmol), now: now, mealType: type)
    }

    let flat8 = ["8.0", "8.0", "8.0", "8.0"] // BG 8.0 → 14 min
    let falling8 = ["8.4", "8.3", "8.2", "8.0"] // −0.4 / 15 min
    let rising8 = ["7.6", "7.7", "7.8", "8.0"] // +0.4 / 15 min, +0.3 / 10 min

    @Test("Conversion matches what Trio shows: 90 mg/dL is 5.0") func conversion() {
        #expect(90.asMmolL == 5.0)
        #expect(mg("5.0") == 90)
    }

    @Test("BG minutes = round(BG × 1.8), halves up") func bgMinutes() {
        #expect(PreBolusPlanner.bgMinutes(d("5.0")) == 9)
        #expect(PreBolusPlanner.bgMinutes(d("7.5")) == 14) // 13.5
        #expect(PreBolusPlanner.bgMinutes(d("7.9")) == 14) // 14.22
        #expect(PreBolusPlanner.bgMinutes(d("8.3")) == 15) // 14.94
        #expect(PreBolusPlanner.bgMinutes(d("13.9")) == 25)
        #expect(PreBolusPlanner.bgMinutes(d("19.4")) == 35) // 34.92
        #expect(PreBolusPlanner.bgMinutes(d("22.0")) == 40)
    }

    @Test("No carbs: nothing shown") func noCarbs() {
        #expect(plan(flat8, carbs: 0) == .hidden)
    }

    @Test("Stale CGM: no advice") func stale() {
        let readings = series(flat8, newestAgo: 11 * 60)
        #expect(PreBolusPlanner.plan(carbs: 40, readings: readings, now: now) == .noData)
        #expect(PreBolusPlanner.plan(carbs: 40, readings: [], now: now) == .noData)
    }

    // MARK: - Safety first

    @Test("Below 5.0: eat now, whatever the type or trend", arguments: PreBolusMealType.allCases)
    func belowFive(type: PreBolusMealType) {
        #expect(plan(["4.9", "4.9", "4.9", "4.9"], type) == .eatNow)
        #expect(plan(["3.8", "3.9", "4.0", "4.6"], type) == .eatNow)
        #expect(minutes(plan(["5.0", "5.0", "5.0", "5.0"], type)) != nil)
    }

    @Test("Drop of 1.0 or more over 15 min: eat now; 0.9 is only falling", arguments: PreBolusMealType.allCases)
    func bigDrop(type: PreBolusMealType) {
        #expect(plan(["9.0", "8.6", "8.3", "8.0"], type) == .eatNow) // −1.0
        #expect(plan(["12.5", "11.0", "10.0", "9.0"], type) == .eatNow) // −3.5, BG still high
        #expect(plan(["8.9", "8.6", "8.3", "8.0"], type) != .eatNow) // −0.9
    }

    @Test("Rise over 1.0 in 10 min: already eating; exactly 1.0 is not") func alreadyEating() {
        #expect(plan(["7.0", "7.0", "7.0", "8.1"]) == .alreadyEating)
        #expect(plan(["7.0", "7.0", "7.0", "8.0"]) != .alreadyEating)
        #expect(plan(["11.0", "11.0", "11.2", "12.6"], .slow) == .alreadyEating)
    }

    // MARK: - Every type × 3 trends (BG 8.0 → 14 min)

    @Test("Flat: max(BG minutes, base)") func flatTrend() {
        #expect(minutes(plan(flat8, .fast)) == 30)
        #expect(minutes(plan(flat8, .normal)) == 15)
        #expect(minutes(plan(flat8, .slow)) == 14)
        #expect(minutes(plan(flat8, .fatty)) == 30)
    }

    @Test("Falling: fast 12, normal 7, slow bolus while eating, fatty as fast") func fallingTrend() {
        #expect(minutes(plan(falling8, .fast)) == 12)
        #expect(minutes(plan(falling8, .normal)) == 7)
        #expect(plan(falling8, .slow) == .bolusWhileEating)
        #expect(minutes(plan(falling8, .fatty)) == 12)
    }

    @Test("Rising: fast +5, normal 22, slow 17, fatty as fast") func risingTrend() {
        #expect(minutes(plan(rising8, .fast)) == 35)
        #expect(minutes(plan(rising8, .normal)) == 22)
        #expect(minutes(plan(rising8, .slow)) == 17)
        #expect(minutes(plan(rising8, .fatty)) == 35)
    }

    @Test("Trend thresholds: −0.3 falling, −0.2 flat, +0.3 rising, +0.2 flat") func trendThresholds() {
        #expect(minutes(plan(["8.3", "8.2", "8.1", "8.0"])) == 7)
        #expect(minutes(plan(["8.2", "8.1", "8.1", "8.0"])) == 15)
        #expect(minutes(plan(["7.7", "7.8", "7.9", "8.0"])) == 22)
        #expect(minutes(plan(["7.8", "7.9", "7.9", "8.0"])) == 15)
    }

    @Test("BG minutes win over the base when higher") func bgWins() {
        let flat139 = ["13.9", "13.9", "13.9", "13.9"] // 25 min
        #expect(minutes(plan(flat139, .normal)) == 25)
        #expect(minutes(plan(flat139, .slow)) == 25)
        #expect(minutes(plan(flat139, .fast)) == 30)
        // rising never shortens: normal/slow wait at least 22/17, but 25 stays 25
        #expect(minutes(plan(["13.5", "13.6", "13.7", "13.9"], .normal)) == 25)
        #expect(minutes(plan(["13.5", "13.6", "13.7", "13.9"], .slow)) == 25)
    }

    @Test("Cap 35 min", arguments: PreBolusMealType.allCases) func cap(type: PreBolusMealType) {
        #expect(minutes(plan(["22.0", "22.0", "22.0", "22.0"], type)) == 35)
        #expect((minutes(plan(["19.0", "19.1", "19.2", "19.4"], type)) ?? 0) == 35)
        for value in ["5.0", "8.0", "12.0", "16.7", "25.0"] {
            #expect((minutes(plan([value, value, value, value], type)) ?? 0) <= PreBolusConstants.maxMinutes)
        }
    }

    @Test("No reading 15 min back: treated as falling (shorter wait)") func unknownTrend() {
        #expect(minutes(plan(["8.0", "8.0"], .normal)) == 7)
        #expect(minutes(plan(["8.0"], .fast)) == 12)
        #expect(plan(["8.0"], .slow) == .bolusWhileEating)
    }

    @Test("Wait ends now + minutes; default type is normal") func untilAndDefault() {
        guard case let .wait(m, until) = PreBolusPlanner.plan(carbs: 40, readings: series(flat8), now: now) else {
            Issue.record("expected a wait")
            return
        }
        #expect(m == 15)
        #expect(until == now.addingTimeInterval(15 * 60))
    }

    @Test("Row texts") func texts() {
        #expect(PreBolusTimerRow.text(for: .hidden) == nil)
        #expect(PreBolusTimerRow.text(for: .eatNow) == "🍽️ Valgyk iškart")
        #expect(PreBolusTimerRow.text(for: .bolusWhileEating) == "🍽️ Bolusas valgant – valgyk iškart")
        #expect(PreBolusTimerRow.text(for: .alreadyEating) == "Atrodo, jau valgai – kitą kartą bolusas anksčiau")
        #expect(PreBolusTimerRow.text(for: .wait(minutes: 15, until: now))?.hasPrefix("🍽️ Valgyk po 15 min (") == true)
    }

    @Test("Food type labels and bases") func mealTypes() {
        #expect(PreBolusMealType.allCases.map(\.label) == ["Greitas", "Įprastas", "Lėtas", "Riebus"])
        #expect(PreBolusMealType.allCases.map(\.baseMinutes) == [30, 15, 10, 30])
        #expect(PreBolusMealType.allCases.map(\.rawValue) == ["fast", "normal", "slow", "fatty"])
    }
}
