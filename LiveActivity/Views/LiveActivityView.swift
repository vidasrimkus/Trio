import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isWatchOS) var isWatchOS

    var context: ActivityViewContext<LiveActivityAttributes>

    private var hasStaticColorScheme: Bool {
        context.state.glucoseColorScheme == "staticColor"
    }

    private var glucoseColor: Color {
        let state = context.state
        let isMgdL = state.unit == "mg/dL"

        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = isMgdL ? Decimal(55) : 55.asMmolL
        let hardCodedHigh = isMgdL ? Decimal(220) : 220.asMmolL

        return Color.getDynamicGlucoseColor(
            glucoseValue: Decimal(string: state.bg) ?? 100,
            highGlucoseColorValue: !hasStaticColorScheme ? hardCodedHigh :
                (isMgdL ? state.highGlucose : state.highGlucose.asMmolL),
            lowGlucoseColorValue: !hasStaticColorScheme ? hardCodedLow : (isMgdL ? state.lowGlucose : state.lowGlucose.asMmolL),
            targetGlucose: isMgdL ? state.target : state.target.asMmolL,
            glucoseColorScheme: state.glucoseColorScheme
        )
    }

    var body: some View {
        if isWatchOS, context.state.useDetailedViewWatchOS {
            VStack {
                LiveActivityBGLabelWatchView(context: context, glucoseColor: glucoseColor)
                LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }
            .addLiveActivityModifiers(isWatchOS: true)

        } else if isWatchOS {
            HStack {
                LiveActivityBGLabelLargeView(
                    context: context,
                    glucoseColor: glucoseColor
                )
                Spacer()
                VStack {
                    LiveActivityGlucoseDeltaLabelView(
                        context: context,
                        glucoseColor: .primary
                    )
                    LiveActivityUpdatedLabelView(context: context, isDetailedLayout: false)
                }
            }
            .addLiveActivityModifiers(isWatchOS: true)

        } else if context.state.useDetailedViewIOS {
            VStack {
                LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
                    .frame(height: 80)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            if context.state.detailedViewState.isOverrideActive {
                                Text(context.state.detailedViewState.overrideName)
                                    .font(.footnote)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.purple.opacity(colorScheme == .dark ? 0.6 : 0.8))
                                    }
                            }
                            if context.state.detailedViewState.isTempTargetActive {
                                Text(context.state.detailedViewState.tempTargetName)
                                    .font(.footnote)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color("LoopGreen").opacity(colorScheme == .dark ? 0.6 : 0.8))
                                    }
                            }
                        }
                    }

                HStack {
                    if context.state.detailedViewState.widgetItems.contains(where: { $0 != .empty }) {
                        ForEach(
                            Array(context.state.detailedViewState.widgetItems.enumerated()),
                            id: \.element
                        ) { index, widgetItem in
                            switch widgetItem {
                            case .currentGlucose:
                                VStack {
                                    LiveActivityBGLabelView(
                                        context: context,
                                        additionalState: context.state.detailedViewState
                                    )

                                    HStack {
                                        LiveActivityGlucoseDeltaLabelView(
                                            context: context,
                                            glucoseColor: .primary
                                        )
                                        if !context.isStale, let direction = context.state.direction {
                                            Text(direction).font(.headline)
                                        }
                                    }
                                }
                            case .currentGlucoseLarge:
                                LiveActivityBGLabelLargeView(
                                    context: context,
                                    glucoseColor: glucoseColor
                                )
                            case .iob:
                                LiveActivityIOBLabelView(context: context, additionalState: context.state.detailedViewState)
                            case .cob:
                                LiveActivityCOBLabelView(context: context, additionalState: context.state.detailedViewState)
                            case .updatedLabel:
                                LiveActivityUpdatedLabelView(context: context, isDetailedLayout: true)
                            case .totalDailyDose:
                                LiveActivityTotalDailyDoseView(
                                    context: context,
                                    additionalState: context.state.detailedViewState
                                )
                            case .empty:
                                Text("").frame(width: 50, height: 50)
                            }

                            /// Check if the next item is also non-empty to determine if a divider should be shown
                            if index < context.state.detailedViewState.widgetItems.count - 1 {
                                let currentItem = context.state.detailedViewState.widgetItems[index]
                                let nextItem = context.state.detailedViewState.widgetItems[index + 1]

                                if currentItem != .empty, nextItem != .empty {
                                    Divider()
                                        .foregroundStyle(.primary)
                                        .fontWeight(.bold)
                                        .frame(width: 10)
                                }
                            }
                        }
                    }
                }
                if let mealDeadline = context.state.mealDeadline { // [vidas] CUSTOMIZATIONS §10
                    PreBolusLiveActivityCountdown(deadline: mealDeadline, size: .row) // small: chart + items fill the height
                }
            }
            .addLiveActivityModifiers(isWatchOS: false)
        } else {
            Group {
                if context.state.isInitialState {
                    Text("Live Activity Expired. Open Trio to Refresh").minimumScaleFactor(0.01)
                } else {
                    VStack(spacing: 6) { // [vidas] CUSTOMIZATIONS §10: VStack for the pre-bolus row
                        HStack(spacing: 3) {
                            LiveActivityBGAndTrendView(context: context, size: .expanded, glucoseColor: glucoseColor).font(.title)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                LiveActivityGlucoseDeltaLabelView(
                                    context: context,
                                    glucoseColor: hasStaticColorScheme ? .primary : glucoseColor
                                ).font(.title3)
                                LiveActivityUpdatedLabelView(context: context, isDetailedLayout: false)
                                    .font(.caption)
                                    .foregroundStyle(.primary.opacity(0.7))
                            }
                        }
                        if let mealDeadline = context.state.mealDeadline { // [vidas] CUSTOMIZATIONS §10
                            PreBolusLiveActivityCountdown(deadline: mealDeadline, size: .lockScreen)
                        }
                    }
                }
            }
            .addLiveActivityModifiers(isWatchOS: false)
        }
    }
}

// Expanded, minimal, compact view components
struct LiveActivityExpandedLeadingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        LiveActivityBGAndTrendView(context: context, size: .expanded, glucoseColor: glucoseColor).font(.title2)
            .padding(.leading, 5)
    }
}

struct LiveActivityExpandedTrailingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        LiveActivityGlucoseDeltaLabelView(context: context, glucoseColor: glucoseColor).font(.title2)
            .padding(.trailing, 5)
    }
}

struct LiveActivityExpandedBottomView: View {
    var context: ActivityViewContext<LiveActivityAttributes>

    var body: some View {
        if context.state.isInitialState {
            Text("Live Activity Expired. Open Trio to Refresh").minimumScaleFactor(0.01)
        } else {
            VStack(spacing: 4) { // [vidas] CUSTOMIZATIONS §10: pre-bolus countdown above the chart
                if let mealDeadline = context.state.mealDeadline {
                    PreBolusLiveActivityCountdown(deadline: mealDeadline, size: .lockScreen)
                }
                if context.state.useDetailedViewIOS {
                    LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                        .addIsWatchOS()
                }
            }
        }
    }
}

struct LiveActivityExpandedCenterView: View {
    var context: ActivityViewContext<LiveActivityAttributes>

    var body: some View {
        LiveActivityUpdatedLabelView(context: context, isDetailedLayout: false)
            .font(Font.caption)
            .foregroundStyle(Color.secondary)
            .addIsWatchOS()
    }
}

struct LiveActivityCompactLeadingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        LiveActivityBGAndTrendView(context: context, size: .compact, glucoseColor: glucoseColor).padding(.leading, 4)
    }
}

struct LiveActivityCompactTrailingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        if let mealDeadline = context.state.mealDeadline { // [vidas] CUSTOMIZATIONS §10: countdown replaces the delta
            PreBolusLiveActivityCountdown(deadline: mealDeadline, size: .compact).padding(.trailing, 4)
        } else {
            LiveActivityGlucoseDeltaLabelView(context: context, glucoseColor: glucoseColor).padding(.trailing, 4)
        }
    }
}

/// [vidas] CUSTOMIZATIONS §10: the pre-bolus countdown "🍽️ 12:40 iki valgio". The seconds are drawn by the system;
/// it stops at 0:00 until the app's next update removes it (the "Laikas valgyti" notification fires at the deadline).
struct PreBolusLiveActivityCountdown: View {
    enum Size { case compact, row, lockScreen }

    let deadline: Date
    let size: Size

    var body: some View {
        // never an inverted range: a deadline already passed counts from itself (shows 0:00)
        let start = min(Date(), deadline)
        switch size {
        case .compact:
            HStack(spacing: 1) {
                Text(verbatim: "🍽️").font(.caption2)
                Text(timerInterval: start ... deadline, countsDown: true)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            }
        case .row,
             .lockScreen:
            HStack(spacing: 4) {
                Text(verbatim: "🍽️")
                Text(timerInterval: start ... deadline, countsDown: true)
                    .monospacedDigit()
                    .fontWeight(.bold)
                    .fixedSize()
                Text(verbatim: "iki valgio").foregroundStyle(.secondary)
            }
            .font(size == .row ? .footnote : .title3)
        }
    }
}

struct LiveActivityMinimalView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        let (label, characterCount) = bgAndTrend(context: context, size: .minimal, glucoseColor: glucoseColor)
        let adjustedLabel = label.padding(.leading, 5).padding(.trailing, 2)

        if characterCount < 4 {
            adjustedLabel.fontWidth(.condensed)
        } else if characterCount < 5 {
            adjustedLabel.fontWidth(.compressed)
        } else {
            adjustedLabel.fontWidth(.compressed)
        }
    }
}
