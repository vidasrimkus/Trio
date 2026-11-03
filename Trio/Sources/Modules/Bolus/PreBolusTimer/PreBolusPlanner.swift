import CoreData
import Foundation

/// One CGM value as the planner needs it.
struct PreBolusReading: Equatable {
    let date: Date
    let mgdl: Int

    static func from(_ glucose: [GlucoseStored]) -> [PreBolusReading] {
        glucose.compactMap { stored in stored.date.map { PreBolusReading(date: $0, mgdl: Int(stored.glucose)) } }
    }
}

enum PreBolusPlan: Equatable {
    /// No carbs entered: show nothing.
    case hidden
    /// No CGM reading in the last `freshness`.
    case noData
    case eatNow
    /// Slow food while falling: the wait comes out as 0 — bolus and eat together.
    case bolusWhileEating
    case alreadyEating
    case wait(minutes: Int, until: Date)
}

enum PreBolusTrend: Equatable {
    case falling
    case flat
    case rising
}

/// How long to wait between the bolus and the meal — the user's own pre-bolus system. Pure; numbers in
/// `PreBolusConstants`. Order:
/// 1. no carbs → hidden; newest CGM older than 10 min → no data;
/// 2. safety first: BG < 5.0, or a drop of ≥ 1.0 over 15 min → eat now;
/// 3. rise > 1.0 over 10 min → already eating;
/// 4. wait = max(round(BG × 1.8), base by food type: fast 30 / normal 15 / slow 10 / fatty 30);
/// 5. trend over 15 min — falling (≤ −0.3): fast/fatty → 12, normal → 7, slow → 0 (bolus while eating);
///    flat: unchanged; rising (≥ +0.3): fast/fatty +5, normal at least 22, slow at least 17;
///    no reading ~15 min back: treated as falling (the shorter wait), as before;
/// 6. at most 35 min.
enum PreBolusPlanner {
    private typealias C = PreBolusConstants

    static func plan(carbs: Decimal, readings: [PreBolusReading], now: Date, mealType: PreBolusMealType = .normal)
        -> PreBolusPlan
    {
        guard carbs > 0 else { return .hidden }
        let sorted = readings.sorted { $0.date > $1.date }
        guard let newest = sorted.first, now.timeIntervalSince(newest.date) <= C.freshness else { return .noData }

        let bg = newest.mgdl.asMmolL
        let delta15 = reading(in: sorted, near: newest.date.addingTimeInterval(-15 * 60)).map { bg - $0.mgdl.asMmolL }

        if bg < C.eatNowBelow { return .eatNow }
        if let delta15, delta15 <= C.eatNowDrop15 { return .eatNow }

        if let earlier = reading(in: sorted, near: newest.date.addingTimeInterval(-10 * 60)),
           bg - earlier.mgdl.asMmolL > C.alreadyEatingRise10
        {
            return .alreadyEating
        }

        let trend: PreBolusTrend
        if let delta15 {
            trend = delta15 <= C.fallingDelta15 ? .falling : delta15 >= C.risingDelta15 ? .rising : .flat
        } else {
            trend = .falling // trend unknown: take the shorter wait
        }

        let minutes = min(max(waitMinutes(bg: bg, mealType: mealType, trend: trend), 0), C.maxMinutes)
        if minutes == 0 { return .bolusWhileEating }
        return .wait(minutes: minutes, until: now.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    /// round(BG mmol/L × 1.8), halves up: 7.9 → 14, 7.5 → 14 (13.5), 5.0 → 9.
    static func bgMinutes(_ bg: Decimal) -> Int {
        var product = bg * C.bgMinutesFactor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// Steps 4–5, before the cap.
    static func waitMinutes(bg: Decimal, mealType: PreBolusMealType, trend: PreBolusTrend) -> Int {
        let wait = max(bgMinutes(bg), mealType.baseMinutes)
        switch (trend, mealType) {
        case (.flat, _): return wait
        case (.falling, .fast),
             (.falling, .fatty): return C.fallingFast
        case (.falling, .normal): return C.fallingNormal
        case (.falling, .slow): return C.fallingSlow
        case (.rising, .fast),
             (.rising, .fatty): return wait + C.risingFastAdd
        case (.rising, .normal): return max(wait, C.risingNormal)
        case (.rising, .slow): return max(wait, C.risingSlow)
        }
    }

    /// The reading closest to `target`, if one lies within `lookbackTolerance`.
    static func reading(in readings: [PreBolusReading], near target: Date) -> PreBolusReading? {
        readings
            .filter { abs($0.date.timeIntervalSince(target)) <= C.lookbackTolerance }
            .min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }
}
