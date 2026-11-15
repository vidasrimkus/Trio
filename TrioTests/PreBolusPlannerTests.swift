import CoreData
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

    /// Loop target in mg/dL whose `asMmolL` is `mmol`.
    func target(_ mmol: String) -> Decimal { Decimal(mg(mmol)) }

    /// The older tests' target: 4.0 mmol/L, below every BG they use, so their rules stay exactly as before.
    var lowTarget: Decimal { target("4.0") }

    func plan(
        _ mmol: [String],
        _ type: PreBolusMealType = .normal,
        carbs: Decimal = 40,
        target loopTarget: Decimal? = nil,
        noTarget: Bool = false
    ) -> PreBolusPlan {
        PreBolusPlanner.plan(
            carbs: carbs,
            readings: series(mmol),
            now: now,
            mealType: type,
            loopTargetMgdl: noTarget ? nil : (loopTarget ?? lowTarget)
        )
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
        #expect(PreBolusPlanner.plan(carbs: 40, readings: readings, now: now, loopTargetMgdl: lowTarget) == .noData)
        #expect(PreBolusPlanner.plan(carbs: 40, readings: [], now: now, loopTargetMgdl: lowTarget) == .noData)
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
        guard case let .wait(m, until) = PreBolusPlanner.plan(carbs: 40, readings: series(flat8), now: now, loopTargetMgdl: lowTarget) else {
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
        #expect(PreBolusTimerRow.text(for: .noTarget) == "Nėra galiojančio loop tikslo – laukimo patarimo nėra")
        #expect(PreBolusTimerRow.text(for: .wait(minutes: 15, until: now))?.hasPrefix("🍽️ Valgyk po 15 min (") == true)
    }

    @Test("Food type labels and bases") func mealTypes() {
        #expect(PreBolusMealType.allCases.map(\.label) == ["Greitas", "Įprastas", "Lėtas", "Riebus"])
        #expect(PreBolusMealType.allCases.map(\.baseMinutes) == [30, 15, 10, 30])
        #expect(PreBolusMealType.allCases.map(\.rawValue) == ["fast", "normal", "slow", "fatty"])
    }

    // MARK: - Rise at or below the loop target (CUSTOMIZATIONS §10, v4)

    /// 2026-11-15 11:51 (bolus of the 12:13 meal): 4.8 → 4.9 → 5.3 → 5.4, loop target 5.8.
    let today = ["4.8", "4.9", "5.3", "5.4"] // +0.6 / 15 min, +0.5 / 10 min

    @Test("2026-11-15: BG 5.4 rising, target 5.8 → 15 min (was 22)") func todayAtTarget() {
        #expect(target("5.8").asMmolL == d("5.8"))
        #expect(minutes(plan(today, .normal, target: target("5.8"))) == 15)
        #expect(minutes(plan(today, .normal)) == 22) // the same readings with a target below them: unchanged rule
    }

    @Test("BG equal to the target: a rise adds nothing; food minimums stay") func equalTarget() {
        let toTarget = ["5.2", "5.4", "5.6", "5.8"] // +0.6 / 15 min, +0.4 / 10 min
        #expect(minutes(plan(toTarget, .normal, target: target("5.8"))) == 15)
        #expect(minutes(plan(toTarget, .slow, target: target("5.8"))) == 10) // max(round(5.8 × 1.8), 10)
        #expect(minutes(plan(toTarget, .fast, target: target("5.8"))) == 30) // flat: base 30, no +5
        #expect(minutes(plan(toTarget, .fatty, target: target("5.8"))) == 30)
    }

    @Test("BG above the target: rising rules unchanged") func aboveTarget() {
        let above = ["5.4", "5.6", "5.8", "6.0"] // +0.6 / 15 min
        #expect(minutes(plan(above, .normal, target: target("5.8"))) == 22)
        #expect(minutes(plan(above, .slow, target: target("5.8"))) == 17)
        #expect(minutes(plan(above, .fast, target: target("5.8"))) == 35)
        #expect(minutes(plan(above, .fatty, target: target("5.8"))) == 35)
    }

    @Test("Only a rise changes: falling and flat at or below the target are unchanged") func otherTrendsAtTarget() {
        #expect(minutes(plan(["6.0", "5.9", "5.8", "5.6"], .normal, target: target("5.8"))) == 7) // falling
        #expect(plan(["6.0", "5.9", "5.8", "5.6"], .slow, target: target("5.8")) == .bolusWhileEating)
        #expect(minutes(plan(["5.6", "5.6", "5.6", "5.6"], .normal, target: target("5.8"))) == 15) // flat
    }

    @Test("Temporary target: the higher target in force decides") func temporaryTarget() {
        let rising74 = ["6.8", "7.0", "7.2", "7.4"] // +0.6 / 15 min, BG 7.4
        #expect(minutes(plan(rising74, .normal, target: target("5.8"))) == 22) // profile target: above it
        #expect(minutes(plan(rising74, .normal, target: target("8.3"))) == 15) // temp target 8.3: at or below it
    }

    @Test("No target in force: no wait advice, nothing guessed") func missingTarget() {
        #expect(plan(today, .normal, noTarget: true) == .noTarget)
        #expect(plan(flat8, .fast, noTarget: true) == .noTarget)
        #expect(PreBolusPlanner.plan(carbs: 40, readings: series(flat8), now: now, loopTargetMgdl: 0) == .noTarget)
    }

    @Test("Low BG and drop checks come first, with or without a target") func safetyFirstWithTarget() {
        let low = ["4.3", "4.5", "4.7", "4.9"] // rising, but BG < 5.0
        let drop = ["9.0", "8.6", "8.3", "8.0"] // −1.0 / 15 min
        #expect(plan(low, .normal, target: target("5.8")) == .eatNow)
        #expect(plan(low, .normal, noTarget: true) == .eatNow)
        #expect(plan(drop, .normal, target: target("8.3")) == .eatNow)
        #expect(plan(drop, .normal, noTarget: true) == .eatNow)
        #expect(plan(["7.0", "7.0", "7.0", "8.1"], .normal, noTarget: true) == .alreadyEating)
        #expect(plan([], .normal, noTarget: true) == .noData)
        #expect(plan(today, .normal, carbs: 0, noTarget: true) == .hidden)
    }
}

/// `PreBolusLoopTarget`: the newest determination's `currentTarget`, only while it is at most 30 min old.
@Suite("Pre-bolus loop target", .serialized) struct PreBolusLoopTargetTests {
    let now = Date(timeIntervalSince1970: 1_793_640_000)

    /// Determinations newest first, `ago` seconds before `now`; the lookup runs on the objects' context.
    func target(_ specs: [(ago: TimeInterval, target: Decimal?)]) async throws -> Decimal? {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let now = self.now
        defer { withExtendedLifetime(stack) {} }
        return await context.perform {
            let objects = specs.map { spec -> OrefDetermination in
                let d = OrefDetermination(context: context)
                d.id = UUID()
                d.deliverAt = now.addingTimeInterval(-spec.ago)
                d.currentTarget = spec.target.map { NSDecimalNumber(decimal: $0) }
                return d
            }
            return PreBolusLoopTarget.mgdl(from: objects, now: now)
        }
    }

    @Test("Newest fresh determination: its target (a temp target included)") func fresh() async throws {
        let value = try await target([(ago: 4 * 60, target: 150), (ago: 9 * 60, target: 105)])
        #expect(value == 150)
    }

    @Test("Age 0…30 min counts (both edges); older or in the future is no target") func age() async throws {
        let fresh = try await target([(ago: 0, target: 105)])
        let edge = try await target([(ago: 30 * 60, target: 105)])
        let stale = try await target([(ago: 30 * 60 + 1, target: 105)])
        let future = try await target([(ago: -1, target: 105)])
        let farFuture = try await target([(ago: -10 * 60, target: 105)])
        #expect(fresh == 105)
        #expect(edge == 105)
        #expect(stale == nil)
        #expect(future == nil)
        #expect(farFuture == nil)
    }

    @Test("No determination, no target value, or 0: no target") func missing() async throws {
        let none = try await target([])
        let empty = try await target([(ago: 60, target: nil)])
        let zero = try await target([(ago: 60, target: 0)])
        #expect(none == nil)
        #expect(empty == nil)
        #expect(zero == nil)
    }
}
