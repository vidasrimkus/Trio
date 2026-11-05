import Foundation

extension TrioRemoteControl {
    /// `set_carb_ratios`: replace Trio's carb ratio schedule. Rules live in RemoteTherapySchedule; the save and its
    /// follow-ups are the Carb Ratio editor's own (CarbRatioEditor.StateModel.save()). Nothing goes to the pump.
    @MainActor func handleSetCarbRatiosCommand(_ payload: CommandPayload) async {
        guard let segments = payload.carbRatioSchedule, let name = payload.scheduleName,
              let expectedHash = payload.expectedActiveHash
        else {
            await logError("Command rejected: carb ratio schedule data is incomplete.", payload: payload)
            return
        }

        // No APSManager → cannot tell whether a loop runs → treat it as running and refuse (fail closed).
        let aps = TrioApp.resolver.resolve(APSManager.self)
        if let rejection = RemoteTherapySchedule.precheck(looping: aps?.isLooping.value ?? true) {
            await logError("Command rejected: \(rejection.text)", payload: payload)
            return
        }

        let entries: [CarbRatioEntry]
        switch RemoteTherapySchedule.validateCarbRatios(name: name, segments: segments) {
        case let .success(valid): entries = valid
        case let .failure(rejection):
            await logError("Command rejected: \(rejection.text)", payload: payload)
            return
        }

        let provider = CarbRatioEditor.Provider(resolver: TrioApp.resolver)
        let current = provider.profile.schedule
        let activeHash = RemoteTherapySchedule.carbRatioHash(current)
        let newHash = RemoteTherapySchedule.carbRatioHash(entries)

        // Re-sending the schedule that is already in force is safe and changes nothing.
        guard RemoteTherapySchedule.carbRatioSlots(entries) != RemoteTherapySchedule.carbRatioSlots(current) else {
            await logSuccess(
                "Remote command processed successfully. Carb ratios \"\(name)\" are already active (\(newHash)).",
                payload: payload,
                customNotificationMessage: "Already active: \(name)"
            )
            return
        }
        guard expectedHash == activeHash else {
            await logError(
                "Command rejected: the active carb ratios changed since they were read (expected \(expectedHash), active \(activeHash)). Refresh and try again.",
                payload: payload
            )
            return
        }

        // Same save and follow-up as CarbRatioEditor.StateModel.save().
        let profile = CarbRatios(units: .grams, schedule: entries)
        provider.saveProfile(profile)

        let broadcaster = TrioApp.resolver.resolve(Broadcaster.self)
        broadcaster?.notify(CarbRatiosObserver.self, on: .main) { $0.carbRatiosDidChange(profile) }
        let nightscout = nightscoutManager
        Task.detached(priority: .low) {
            do { try await nightscout?.uploadProfiles() } catch {
                debug(.default, "Failed to upload CRs to Nightscout: \(error)")
            }
        }
        if let tidepool = TrioApp.resolver.resolve(TidepoolManager.self) {
            Task.detached(priority: .low) { await tidepool.uploadSettings() }
        }
        await nightscoutManager.uploadNoteTreatment(note: "Carb ratios activated remotely: \(name) (\(newHash))")

        await logSuccess(
            "Remote command processed successfully. Carb ratios \"\(name)\" activated (\(activeHash) → \(newHash)).",
            payload: payload,
            customNotificationMessage: "Carb ratios activated: \(name)"
        )
    }
}
