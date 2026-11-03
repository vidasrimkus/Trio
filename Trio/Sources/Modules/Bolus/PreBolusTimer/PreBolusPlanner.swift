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
    case alreadyEating
    case wait(minutes: Int, until: Date)
}

/// How long to wait between the bolus and the meal. Pure; thresholds in `PreBolusConstants`.
/// Order: no carbs → stale CGM → BG < 5.0 (safety first) → rising > 0.5 / 10 min → band × trend, capped.
enum PreBolusPlanner {
    private typealias C = PreBolusConstants

    static func plan(carbs: Decimal, readings: [PreBolusReading], now: Date, note: String? = nil) -> PreBolusPlan {
        guard carbs > 0 else { return .hidden }
        let sorted = readings.sorted { $0.date > $1.date }
        guard let newest = sorted.first, now.timeIntervalSince(newest.date) <= C.freshness else { return .noData }

        let bg = newest.mgdl.asMmolL
        if bg < C.eatNowBelow { return .eatNow }

        if let earlier = reading(in: sorted, near: newest.date.addingTimeInterval(-10 * 60)),
           bg - earlier.mgdl.asMmolL > C.risingDelta10
        {
            return .alreadyEating
        }

        let falling: Bool
        if let earlier = reading(in: sorted, near: newest.date.addingTimeInterval(-15 * 60)) {
            falling = bg - earlier.mgdl.asMmolL <= C.fallingDelta15
        } else {
            falling = true // trend unknown: take the shorter wait
        }

        let base: Int
        if bg < C.lowBandBelow {
            base = falling ? C.minutesLowFalling : C.minutesLow
        } else if bg <= C.midBandUpTo {
            base = falling ? C.minutesMidFalling : C.minutesMid
        } else {
            base = C.minutesHigh
        }
        let minutes = min(max(base + foodAdjustmentMinutes(note: note), 0), C.maxMinutes)
        return .wait(minutes: minutes, until: now.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    /// Stage 2 (not built yet): adjust the wait by food type from the carb entry's note field.
    static func foodAdjustmentMinutes(note _: String?) -> Int { 0 }

    /// The reading closest to `target`, if one lies within `lookbackTolerance`.
    static func reading(in readings: [PreBolusReading], near target: Date) -> PreBolusReading? {
        readings
            .filter { abs($0.date.timeIntervalSince(target)) <= C.lookbackTolerance }
            .min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }
}
