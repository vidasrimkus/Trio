import Foundation
import UserNotifications

extension TrioRemoteControl {
    @MainActor func handleSetISFCommand(_ payload: CommandPayload) async {
        let restoring = payload.commandType == .restorePreviousISF
        let aps = TrioApp.resolver.resolve(APSManager.self)
        guard let storage = TrioApp.resolver.resolve(FileStorage.self) else {
            await logError("Command rejected: local storage is unavailable.", payload: payload)
            return
        }
        let provider = ISFEditor.Provider(resolver: TrioApp.resolver)
        // The ISF provider normalizes legacy files before the snapshot is taken.
        let current = provider.profile
        let file = OpenAPS.Settings.insulinSensitivities
        guard storage.retrieveRaw(file) != nil else {
            await logError("Command rejected: cannot read the active ISF file.", payload: payload)
            return
        }
        let plan: Result<RemoteTherapySchedule.Plan<InsulinSensitivityEntry>, RemoteTherapySchedule.Rejection>
        var restoredRaw: String?
        if restoring {
            let activeHash = RemoteTherapySchedule.sensitivityNightscoutHash(current.sensitivities, units: settings.settings.units)
            let raw: String
            switch RemoteTherapyBackup.restoreRaw(
                file: file, storage: storage, expectedHash: payload.expectedActiveHash,
                activeHash: activeHash, looping: aps?.isLooping.value ?? true
            ) {
            case let .failure(rejection):
                await logError(rejection.text, payload: payload)
                return
            case let .success(value): raw = value
            }
            guard let previous = InsulinSensitivities(from: raw), previous.units == .mgdL && previous.userPreferredUnits == .mgdL else {
                await logError("Command rejected: previous backup has invalid units or data.", payload: payload)
                return
            }
            let newHash = RemoteTherapySchedule.sensitivityNightscoutHash(previous.sensitivities, units: settings.settings.units)
            // An identical raw file means a retry of an already completed restore. No toggle.
            if storage.retrieveRaw(file) == raw {
                await logSuccess("Already restored ISF.", payload: payload, customNotificationMessage: "ISF jau atkurtas")
                return
            }
            restoredRaw = raw
            // Only this verified on-phone snapshot bypasses the percentage/editor-grid guards.
            plan = .success(.write(name: "Previous ISF", entries: previous.sensitivities, activeHash: activeHash, newHash: newHash))
        } else {
            plan = RemoteTherapySchedule.planSensitivities(
                schedule: payload.isfSchedule, name: payload.scheduleName,
                expectedHash: payload.expectedActiveHash, looping: aps?.isLooping.value ?? true,
                units: settings.settings.units, stored: { current.sensitivities }
            )
        }

        switch plan {
        case let .failure(rejection):
            await logError(rejection.text, payload: payload)
        case let .success(.alreadyActive(name, _)):
            await logSuccess("Already active: \(name)", payload: payload, customNotificationMessage: "Already active: \(name)")
        case let .success(.write(name, entries, activeHash, newHash)):
            let raw = restoredRaw ?? RemoteTherapySchedule.sensitivityProfile(entries).rawJSON
            guard RemoteTherapyBackup.replace(raw, file: file, storage: storage, preservePrevious: !restoring),
                  let saved = InsulinSensitivities(from: raw)
            else {
                await logError("Command rejected: ISF backup or file write could not be verified. Check Trio on the child's phone.", payload: payload)
                return
            }
            let summary = RemoteTherapySchedule.changeSummary(
                old: RemoteTherapySchedule.sensitivitySlots(current.sensitivities), new: RemoteTherapySchedule.sensitivitySlots(saved.sensitivities)
            )
            let broadcaster = TrioApp.resolver.resolve(Broadcaster.self)
            broadcaster?.notify(InsulinSensitivitiesObserver.self, on: .main) { $0.insulinSensitivitiesDidChange(saved) }
            let notification = RemoteTherapyBackup.notification(label: "ISF", restored: restoring, summary: summary)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "Trio.remoteTherapy." + UUID().uuidString, content: notification, trigger: nil)
            ) { failure in
                if let failure { debug(.remoteControl, "ISF notification failed: \(failure)") }
            }
            let nightscout = nightscoutManager
            Task.detached(priority: .low) {
                do { try await nightscout?.uploadProfiles() } catch {
                    debug(.default, "Failed to upload ISF to Nightscout: \(error)")
                }
            }
            if let tidepool = TrioApp.resolver.resolve(TidepoolManager.self) {
                Task.detached(priority: .low) { await tidepool.uploadSettings() }
            }
            // Notify the sender before network-dependent Note upload; success means the local file was verified.
            await logSuccess(
                "ISF: \(activeHash) → \(newHash)", payload: payload,
                customNotificationMessage: "ISF \(restoring ? "atkurtas" : "pritaikytas"): \(name)"
            )
            await nightscoutManager.uploadNoteTreatment(
                note: "ISF \(restoring ? "restored" : "activated") remotely: \(name) (\(newHash)). \(summary)"
            )
        }
    }
}
