import Foundation

/// The food type picked on the bolus screen. `rawValue` goes into `meal_started meal_type=`.
enum PreBolusMealType: String, CaseIterable, Codable {
    case fast
    case normal
    case slow
    case fatty

    var label: String {
        switch self {
        case .fast: return "Greitas"
        case .normal: return "Įprastas"
        case .slow: return "Lėtas"
        case .fatty: return "Riebus"
        }
    }

    /// Base wait in minutes.
    var baseMinutes: Int {
        switch self {
        case .fast: return PreBolusConstants.baseFast
        case .normal: return PreBolusConstants.baseNormal
        case .slow: return PreBolusConstants.baseSlow
        case .fatty: return PreBolusConstants.baseFatty
        }
    }
}

/// Every threshold, wait and text of the pre-bolus timer in one place (CUSTOMIZATIONS.md §10).
/// The wait rules follow the user's own pre-bolus system (2026-11-03). Glucose values are mmol/L as Trio shows
/// them (`Int.asMmolL`, one decimal).
enum PreBolusConstants {
    // MARK: Safety first (no timer)

    /// BG below this: eat right away.
    static let eatNowBelow: Decimal = 5.0
    /// Change over the last 15 min at or below this (a drop of ≥ 1.0): eat right away.
    static let eatNowDrop15: Decimal = -1.0
    /// Rise over the last 10 min above this: the meal has already started.
    static let alreadyEatingRise10: Decimal = 1.0

    // MARK: Wait = max(BG × 1.8, base by food type), then the trend correction

    /// minutes_bg = round(BG mmol/L × this) — the first two digits of the mg/dL value.
    static let bgMinutesFactor: Decimal = 1.8
    static let baseFast = 30
    static let baseNormal = 15
    static let baseSlow = 10
    static let baseFatty = 30 // behaves like fast

    /// Change over the last 15 min at or below this: falling.
    static let fallingDelta15: Decimal = -0.3
    /// Change over the last 15 min at or above this: rising.
    static let risingDelta15: Decimal = 0.3

    /// Falling: the wait becomes this (fast and fatty / normal / slow). Slow → 0 = bolus while eating.
    static let fallingFast = 12
    static let fallingNormal = 7
    static let fallingSlow = 0
    /// Rising: fast and fatty add this; normal / slow wait at least this.
    static let risingFastAdd = 5
    static let risingNormal = 22
    static let risingSlow = 17

    static let maxMinutes = 35

    /// Newest CGM reading older than this: no advice.
    static let freshness: TimeInterval = 10 * 60
    /// A reading counts as "15 / 10 min ago" within ± this.
    static let lookbackTolerance: TimeInterval = 3 * 60
    /// The food type picked on the bolus screen falls back to "Įprastas" after this (or after the bolus is enacted).
    static let mealTypeMemory: TimeInterval = 30 * 60

    static let notificationIdentifier = "Trio.preBolusTimer"
    /// UserDefaults: the armed timer (`PreBolusArmedTimer`, JSON), so a relaunch restores it.
    static let armedTimerKey = "PreBolusTimer.armed"
    /// UserDefaults: "Tylus priminimas" — vibration only, no sound. Off by default.
    static let silentReminderKey = "PreBolus.silentReminder"
    /// Half a second of silence (Resources/Sounds): with a sound iOS also vibrates, with `sound = nil` it does not.
    static let silentSoundName = "prebolus_silent.caf"
    /// An expired timer found later than this after its deadline (app not run for hours) ends without `meal_started`.
    static let maxReplayAge: TimeInterval = 6 * 60 * 60

    // Lithuanian on purpose: a single user, and upstream's Localizable.xcstrings stays untouched.
    static let textEatNow = "🍽️ Valgyk iškart"
    static let textBolusWhileEating = "🍽️ Bolusas valgant – valgyk iškart"
    static let textAlreadyEating = "Atrodo, jau valgai – kitą kartą bolusas anksčiau"
    static let textNoData = "Nėra šviežių CGM duomenų – valgyk įprastai"
    static func textWait(minutes: Int, until: String) -> String { "🍽️ Valgyk po \(minutes) min (\(until))" }
    static let mealTypeTitle = "Maistas"
    static let notificationTitle = "Laikas valgyti"
    static let notificationBody = "🍽️ Pre-bolus laikas baigėsi"
    static let actionEating = "Valgau"
    static let actionCancel = "Atšaukti"
    /// Home row and Live Activity: "🍽️ 12:40 iki valgio".
    static let textUntilMeal = "iki valgio"
    /// Posted when `PreBolusNotifier.deadline` changes; the Live Activity pushes the new deadline.
    static let deadlineDidChange = Notification.Name("Trio.preBolusDeadlineDidChange")
    static let settingSilentTitle = "Tylus priminimas"
    static let settingSilentFooter = "Pre-bolus priminimas „Laikas valgyti“: tik vibracija; jei telefonas nevibruoja – tik vizualinis pranešimas."
}
