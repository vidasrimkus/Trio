import Foundation

extension TrioRemoteControl {
    /// `set_carb_ratios`: replace Trio's carb ratio schedule. Rules and checks live in RemoteTherapySchedule; the
    /// save and its follow-ups are the Carb Ratio editor's own (CarbRatioEditor.StateModel.save()). Nothing goes to
    /// the pump.
    @MainActor func handleSetCarbRatiosCommand(_ payload: CommandPayload) async {
        // No APSManager → cannot tell whether a loop runs → treat it as running and refuse (fail closed).
        let aps = TrioApp.resolver.resolve(APSManager.self)
        let provider = CarbRatioEditor.Provider(resolver: TrioApp.resolver)
        // Starts are minutes from midnight in the phone's local time, stored as received (no TimeZone conversion).
        let plan = RemoteTherapySchedule.planCarbRatios(
            schedule: payload.carbRatioSchedule,
            name: payload.scheduleName,
            expectedHash: payload.expectedActiveHash,
            looping: aps?.isLooping.value ?? true,
            stored: { provider.profile.schedule }
        )

        switch plan {
        case let .failure(rejection):
            await logError(rejection.text, payload: payload)
            return
        case let .success(.alreadyActive(activeName, hash)):
            await logSuccess(
                "Remote command processed successfully. Carb ratios \"\(activeName)\" are already active (\(hash)).",
                payload: payload,
                customNotificationMessage: "Already active: \(activeName)"
            )
            return
        case let .success(.write(name, entries, activeHash, newHash)):
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
}
