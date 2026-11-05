import Foundation
import UserNotifications

extension TrioRemoteControl {
    @MainActor func handleSetCarbRatiosCommand(_ payload: CommandPayload) async {
        let restoring = payload.commandType == .restorePreviousCarbRatios
        let aps = TrioApp.resolver.resolve(APSManager.self)
        guard let storage = TrioApp.resolver.resolve(FileStorage.self) else {
            await logError("Command rejected: local storage is unavailable.", payload: payload)
            return
        }
        let provider = CarbRatioEditor.Provider(resolver: TrioApp.resolver)
        // The ISF provider normalizes legacy files before the snapshot is taken.
        let current = provider.profile
        let file = OpenAPS.Settings.carbRatios
        guard storage.retrieveRaw(file) != nil else {
            await logError("Command rejected: cannot read the active CR file.", payload: payload)
            return
        }
        let plan: Result<RemoteTherapySchedule.Plan<CarbRatioEntry>, RemoteTherapySchedule.Rejection>
        var restoredRaw: String?
        if restoring {
            let activeHash = RemoteTherapySchedule.carbRatioHash(current.schedule)
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
            guard let previous = CarbRatios(from: raw), previous.units == .grams else {
                await logError("Command rejected: previous backup has invalid units or data.", payload: payload)
                return
            }
            let newHash = RemoteTherapySchedule.carbRatioHash(previous.schedule)
            // An identical raw file means a retry of an already completed restore. No toggle.
            if storage.retrieveRaw(file) == raw {
                await logSuccess("Already restored CR.", payload: payload, customNotificationMessage: "CR jau atkurtas")
                return
            }
            restoredRaw = raw
            // Only this verified on-phone snapshot bypasses the percentage/editor-grid guards.
            plan = .success(.write(name: "Previous CR", entries: previous.schedule, activeHash: activeHash, newHash: newHash))
        } else {
            plan = RemoteTherapySchedule.planCarbRatios(
                schedule: payload.carbRatioSchedule, name: payload.scheduleName,
                expectedHash: payload.expectedActiveHash, looping: aps?.isLooping.value ?? true,
                stored: { current.schedule }
            )
        }

        switch plan {
        case let .failure(rejection):
            await logError(rejection.text, payload: payload)
        case let .success(.alreadyActive(name, _)):
            await logSuccess("Already active: \(name)", payload: payload, customNotificationMessage: "Already active: \(name)")
        case let .success(.write(name, entries, activeHash, newHash)):
            let raw = restoredRaw ?? CarbRatios(units: .grams, schedule: entries).rawJSON
            guard RemoteTherapyBackup.replace(raw, file: file, storage: storage, preservePrevious: !restoring),
                  let saved = CarbRatios(from: raw)
            else {
                await logError("Command rejected: CR backup or file write could not be verified. Check Trio on the child's phone.", payload: payload)
                return
            }
            let summary = RemoteTherapySchedule.changeSummary(
                old: RemoteTherapySchedule.carbRatioSlots(current.schedule), new: RemoteTherapySchedule.carbRatioSlots(saved.schedule)
            )
            let broadcaster = TrioApp.resolver.resolve(Broadcaster.self)
            broadcaster?.notify(CarbRatiosObserver.self, on: .main) { $0.carbRatiosDidChange(saved) }
            let notification = RemoteTherapyBackup.notification(label: "CR", restored: restoring, summary: summary)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "Trio.remoteTherapy." + UUID().uuidString, content: notification, trigger: nil)
            ) { failure in
                if let failure { debug(.remoteControl, "CR notification failed: \(failure)") }
            }
            let nightscout = nightscoutManager
            Task.detached(priority: .low) {
                do { try await nightscout?.uploadProfiles() } catch {
                    debug(.default, "Failed to upload CR to Nightscout: \(error)")
                }
            }
            if let tidepool = TrioApp.resolver.resolve(TidepoolManager.self) {
                Task.detached(priority: .low) { await tidepool.uploadSettings() }
            }
            // Notify the sender before network-dependent Note upload; success means the local file was verified.
            await logSuccess(
                "CR: \(activeHash) → \(newHash)", payload: payload,
                customNotificationMessage: "CR \(restoring ? "atkurtas" : "pritaikytas"): \(name)"
            )
            await nightscoutManager.uploadNoteTreatment(
                note: "CR \(restoring ? "restored" : "activated") remotely: \(name) (\(newHash)). \(summary)"
            )
        }
    }
}
