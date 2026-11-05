import Foundation

extension TrioRemoteControl {
    /// `set_isf`: replace Trio's insulin sensitivity schedule (always sent in mg/dL). Rules live in
    /// RemoteTherapySchedule; the save and its follow-ups are the ISF editor's own (ISFEditor.StateModel.save()).
    /// Nothing goes to the pump.
    @MainActor func handleSetISFCommand(_ payload: CommandPayload) async {
        guard let segments = payload.isfSchedule, let name = payload.scheduleName,
              let expectedHash = payload.expectedActiveHash
        else {
            await logError("Command rejected: ISF schedule data is incomplete.", payload: payload)
            return
        }

        // No APSManager → cannot tell whether a loop runs → treat it as running and refuse (fail closed).
        let aps = TrioApp.resolver.resolve(APSManager.self)
        if let rejection = RemoteTherapySchedule.precheck(looping: aps?.isLooping.value ?? true) {
            await logError("Command rejected: \(rejection.text)", payload: payload)
            return
        }

        let entries: [InsulinSensitivityEntry]
        switch RemoteTherapySchedule.validateSensitivities(name: name, segments: segments) {
        case let .success(valid): entries = valid
        case let .failure(rejection):
            await logError("Command rejected: \(rejection.text)", payload: payload)
            return
        }

        // The editor's provider (it also migrates a legacy mmol/L file to mg/dL, as opening the editor does).
        let provider = ISFEditor.Provider(resolver: TrioApp.resolver)
        let current = provider.profile.sensitivities
        // The guard hash is of what Nightscout shows, i.e. in the units Trio uploads with right now.
        let units = settings.settings.units
        let activeHash = RemoteTherapySchedule.sensitivityNightscoutHash(current, units: units)
        let newHash = RemoteTherapySchedule.sensitivityNightscoutHash(entries, units: units)

        // Exact mg/dL comparison: the Nightscout form is lossy in mmol/L (46 and 47 mg/dL are both 2.6).
        guard RemoteTherapySchedule.sensitivitySlots(entries) != RemoteTherapySchedule.sensitivitySlots(current) else {
            await logSuccess(
                "Remote command processed successfully. ISF \"\(name)\" is already active (\(newHash)).",
                payload: payload,
                customNotificationMessage: "Already active: \(name)"
            )
            return
        }
        guard expectedHash == activeHash else {
            await logError(
                "Command rejected: the active ISF changed since it was read (expected \(expectedHash), active \(activeHash)). Refresh and try again.",
                payload: payload
            )
            return
        }

        // Same save and follow-up as ISFEditor.StateModel.save().
        let profile = InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: entries)
        provider.saveProfile(profile)

        let broadcaster = TrioApp.resolver.resolve(Broadcaster.self)
        broadcaster?.notify(InsulinSensitivitiesObserver.self, on: .main) { $0.insulinSensitivitiesDidChange(profile) }
        let nightscout = nightscoutManager
        Task.detached(priority: .low) {
            do { try await nightscout?.uploadProfiles() } catch {
                debug(.default, "Failed to upload ISF to Nightscout: \(error)")
            }
        }
        if let tidepool = TrioApp.resolver.resolve(TidepoolManager.self) {
            Task.detached(priority: .low) { await tidepool.uploadSettings() }
        }
        await nightscoutManager.uploadNoteTreatment(note: "ISF activated remotely: \(name) (\(newHash))")

        await logSuccess(
            "Remote command processed successfully. ISF \"\(name)\" activated (\(activeHash) → \(newHash)).",
            payload: payload,
            customNotificationMessage: "ISF activated: \(name)"
        )
    }
}
