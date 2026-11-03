import SwiftUI

/// Bolus screen row under "Recommendation": how long to wait before eating. Nothing without carbs.
/// Re-evaluated once a minute (`TimelineView`), only while the row is on screen.
struct PreBolusTimerRow: View {
    let carbs: Decimal
    let glucose: [GlucoseStored]

    var body: some View {
        if carbs > 0 {
            TimelineView(.everyMinute) { context in
                let plan = PreBolusPlanner.plan(carbs: carbs, readings: PreBolusReading.from(glucose), now: context.date)
                if let text = Self.text(for: plan) {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func text(for plan: PreBolusPlan) -> String? {
        switch plan {
        case .hidden: return nil
        case .noData: return PreBolusConstants.textNoData
        case .eatNow: return PreBolusConstants.textEatNow
        case .alreadyEating: return PreBolusConstants.textAlreadyEating
        case let .wait(minutes, until):
            return PreBolusConstants.textWait(minutes: minutes, until: until.formatted(date: .omitted, time: .shortened))
        }
    }
}
