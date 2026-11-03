import Foundation

/// Every threshold, wait and text of the pre-bolus timer in one place (CUSTOMIZATIONS.md §10).
/// Glucose values are mmol/L as Trio shows them (`Int.asMmolL`, one decimal).
enum PreBolusConstants {
    /// BG below this: eat right away, no timer.
    static let eatNowBelow: Decimal = 5.0
    /// 5.0 ≤ BG < `lowBandBelow` is the low band.
    static let lowBandBelow: Decimal = 6.5
    /// `lowBandBelow` ≤ BG ≤ `midBandUpTo` is the middle band; above it the high band.
    static let midBandUpTo: Decimal = 9.0
    /// Change over the last 15 min at or below this counts as falling.
    static let fallingDelta15: Decimal = -0.3
    /// Rise over the last 10 min above this: the meal has already started.
    static let risingDelta10: Decimal = 0.5

    static let minutesLowFalling = 5
    static let minutesLow = 10
    static let minutesMidFalling = 10
    static let minutesMid = 15
    static let minutesHigh = 20
    static let maxMinutes = 20

    /// Newest CGM reading older than this: no advice.
    static let freshness: TimeInterval = 10 * 60
    /// A reading counts as "15 / 10 min ago" within ± this.
    static let lookbackTolerance: TimeInterval = 3 * 60

    static let notificationIdentifier = "Trio.preBolusTimer"

    // Lithuanian on purpose: a single user, and upstream's Localizable.xcstrings stays untouched.
    static let textEatNow = "🍽️ Valgyk iškart"
    static let textAlreadyEating = "Atrodo, jau valgai – kitą kartą bolusas anksčiau"
    static let textNoData = "Nėra šviežių CGM duomenų – valgyk įprastai"
    static func textWait(minutes: Int, until: String) -> String { "🍽️ Valgyk po \(minutes) min (\(until))" }
    static let notificationTitle = "Laikas valgyti"
    static let notificationBody = "🍽️ Pre-bolus laikas baigėsi"
}
