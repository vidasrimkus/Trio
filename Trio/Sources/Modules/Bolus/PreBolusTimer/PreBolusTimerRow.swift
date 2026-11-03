import SwiftUI

/// Bolus screen row under "Recommendation": the food type (4 segments, "Įprastas" by default) and how long to wait
/// before eating. Nothing without carbs. Re-evaluated once a minute (`TimelineView`), only while the row is on screen.
/// The picked type lives in `PreBolusNotifier` so the Enact hook (`arm`) plans with the same type.
struct PreBolusTimerRow: View {
    let carbs: Decimal
    let glucose: [GlucoseStored]
    private let notifier = PreBolusNotifier.shared

    var body: some View {
        if carbs > 0 {
            // Read here, in `body`, so a pick re-renders the row (Observation tracks this access).
            let selected = notifier.mealType()
            VStack(alignment: .leading, spacing: 6) {
                Picker(
                    selection: Binding(get: { selected }, set: { notifier.pickMealType($0) })
                ) {
                    ForEach(PreBolusMealType.allCases, id: \.self) { type in
                        Text(verbatim: type.label).tag(type)
                    }
                } label: {
                    Text(verbatim: PreBolusConstants.mealTypeTitle)
                }
                .pickerStyle(.segmented)

                TimelineView(.everyMinute) { context in
                    let plan = PreBolusPlanner.plan(
                        carbs: carbs,
                        readings: PreBolusReading.from(glucose),
                        now: context.date,
                        mealType: selected
                    )
                    if let text = Self.text(for: plan) {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func text(for plan: PreBolusPlan) -> String? {
        switch plan {
        case .hidden: return nil
        case .noData: return PreBolusConstants.textNoData
        case .eatNow: return PreBolusConstants.textEatNow
        case .bolusWhileEating: return PreBolusConstants.textBolusWhileEating
        case .alreadyEating: return PreBolusConstants.textAlreadyEating
        case let .wait(minutes, until):
            return PreBolusConstants.textWait(minutes: minutes, until: until.formatted(date: .omitted, time: .shortened))
        }
    }
}
