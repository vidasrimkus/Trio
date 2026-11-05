import Foundation

extension TrioRemoteControl {
    /// `set_isf`: replace Trio's insulin sensitivity schedule (always sent and stored in mg/dL). Rules and checks live
    /// in RemoteTherapySchedule; the save and its follow-ups are the ISF editor's own (ISFEditor.StateModel.save()).
    /// Nothing goes to the pump.
    @MainActor func handleSetISFCommand(_ payload: CommandPayload) async {
        // No APSManager → cannot tell whether a loop runs → treat it as running and refuse (fail closed).
        let aps = TrioApp.resolver.resolve(APSManager.self)
        // The editor's provider (it also migrates a legacy mmol/L file to mg/dL on read, as opening the editor does).
        let provider = ISFEditor.Provider(resolver: TrioApp.resolver)
        // Starts are minutes from midnight in the phone's local time, stored as received (no TimeZone conversion).
        // The guard hash is of what Nightscout shows, i.e. in the units Trio uploads with right now.
        let plan = RemoteTherapySchedule.planSensitivities(
            schedule: payload.isfSchedule,
            name: payload.scheduleName,
            expectedHash: payload.expectedActiveHash,
            looping: aps?.isLooping.value ?? true,
            units: settings.settings.units,
            stored: { provider.profile.sensitivities }
        )

        switch plan {
        case let .failure(rejection):
            await logError(rejection.text, payload: payload)
            return
        case let .success(.alreadyActive(activeName, hash)):
            await logSuccess(
                "Remote command processed successfully. ISF \"\(activeName)\" is already active (\(hash)).",
                payload: payload,
                customNotificationMessage: "Already active: \(activeName)"
            )
            return
        case let .success(.write(name, entries, activeHash, newHash)):
            // Same save and follow-up as ISFEditor.StateModel.save(): the file is always mg/dL.
            let profile = RemoteTherapySchedule.sensitivityProfile(entries)
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
}
