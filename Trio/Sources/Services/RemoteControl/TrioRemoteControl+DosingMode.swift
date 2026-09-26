import Foundation

extension TrioRemoteControl {
    @MainActor func handleSetDosingModeCommand(_ payload: CommandPayload) async {
        guard let mode = payload.requestedDosingMode else {
            await logError("Command rejected: invalid dosing mode", payload: payload)
            return
        }

        // Same gate as the Settings screen (Settings.StateModel.hasCgmAndPump()): the mode picker is
        // disabled there until both a CGM and a pump are set up.
        let hasCgm = fetchGlucoseManager.cgmGlucoseSourceType != .none
        let hasPump = deviceDataManager.pumpManager != nil
        guard hasCgm, hasPump else {
            let missing = [hasCgm ? nil : "CGM", hasPump ? nil : "pump"].compactMap { $0 }.joined(separator: " and ")
            await logError(
                "Command rejected: dosing mode can only be changed with a CGM and a pump connected (missing: \(missing)).",
                payload: payload
            )
            return
        }

        let current = settings.settings.dosingMode
        guard current != mode else {
            await logSuccess(
                "Remote command processed successfully. Already in \(mode.displayName); nothing changed.",
                payload: payload,
                customNotificationMessage: "Already in \(mode.displayName)"
            )
            return
        }

        // The same write the Settings picker makes (BaseStateModel.subscribeSetting): SettingsManager's
        // didSet saves the settings and notifies every SettingsObserver on main (APSManager.settingsDidChange
        // and the rest), so the mode change takes the exact path a change made on the phone takes.
        settings.settings.dosingMode = mode

        await logSuccess(
            "Remote command processed successfully. \(payload.humanReadableDescription()) Previous mode: \(current.displayName).",
            payload: payload,
            customNotificationMessage: "Dosing mode: \(current.displayName) → \(mode.displayName)"
        )
    }
}
