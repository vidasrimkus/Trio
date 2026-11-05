# CUSTOMIZATIONS — vidasrimkus/Trio

Every difference between this fork and upstream **nightscout/Trio v1.0.2** (`0b29cd534`; merged on branch
`upgrade/v1.0.2` 2026-11-03, before that v1.0.1 `c0160aeaf`).
Read this first before any upstream update (procedure in `CLAUDE.md`).

## 1. Remote command `set_dosing_mode`

**Purpose.** Change Trio's Dosing Mode (Closed Loop / Open Loop / Low Glucose Suspend /
Basal Testing) remotely from LoopFollow through Trio Remote Control, the same way the other
remote commands (bolus, meal, temp target, override) already work.

**Commit.** `1d0aab415` — "Remote Control: add set_dosing_mode command".

**Files.**

| File | Change |
|---|---|
| `Trio/Sources/Models/CommandPayload.swift` | `CommandType.setDosingMode = "set_dosing_mode"` ("Set Dosing Mode"); field `dosingMode: String?` with CodingKey `"dosing_mode"`; computed `requestedDosingMode` (`DosingMode(rawValue:)`, nil when missing or unknown); `humanReadableDescription` names the mode. |
| `Trio/Sources/Services/RemoteControl/TrioRemoteControl+DosingMode.swift` | New. `handleSetDosingModeCommand` (@MainActor). |
| `Trio/Sources/Services/RemoteControl/TrioRemoteControl.swift` | `case .setDosingMode` in the command switch; `@Injected` `DeviceDataManager` and `FetchGlucoseManager` for the CGM/pump gate. |
| `Trio.xcodeproj/project.pbxproj` | Registers the new handler file (app target) and the new test file (TrioTests target). |
| `TrioTests/RemoteDosingModeCommandTests.swift` | New. Payload decoding for all four modes; unknown values (`teleportation`, `Closed`, `closed_loop`, `""`, `" open"`) and a missing `dosing_mode` rejected; `dosing_mode` ignored by other commands. |

**Handler behaviour** (`TrioRemoteControl+DosingMode.swift`), in order:

1. `dosing_mode` missing or not a `DosingMode` rawValue → `logError("Command rejected: invalid dosing mode")`, nothing changed.
2. No CGM or no pump → rejected with the missing part named. Same gate as the Settings picker (`Settings.StateModel.hasCgmAndPump()`).
3. Already in that mode → `logSuccess` "Already in X", nothing changed.
4. Otherwise `settings.settings.dosingMode = mode` on the main actor — the exact write the Settings
   picker makes (`BaseStateModel.subscribeSetting`), so every `SettingsObserver`
   (`APSManager.settingsDidChange`, e.g. cancelling a Trio temp when entering Basal Testing) runs as
   for a change made on the phone. Return notification: "Dosing mode: <old> → <new>".

Every path sends the return notification through the existing `logError` / `logSuccess` helpers.
Encryption, the timestamp window, the algorithm (`OpenAPS/`, `OpenAPSSwift/`),
`Preferences+DosingMode.swift` and all other remote commands are unchanged.

## 2. Fork CI

**Commit.** `1adbced30` — "ci(fork): run unit tests on demand in vidasrimkus/Trio".

`.github/workflows/unit_tests.yml`: added `workflow_dispatch`; removed
`if: github.repository_owner == 'nightscout'` from both jobs (`algorithm-package`, `test`).
Run it with `gh workflow run unit_tests.yml -R vidasrimkus/Trio --ref <branch>`.

**Caches (branch `chore/ci-and-gotchas`, 2026-11-02).** Upstream saves its DerivedData and AlgorithmPackage SPM caches
only on `push` to `dev`; this fork has no `dev` and ran only `workflow_dispatch`, so for two months no cache was ever
written (every run cold, ≈ 20 min). The BuildTools (SwiftFormat) cache step is a no-op in CI — `BuildTools/.build` is
never produced there ("Path Validation Error" in every run) — left as upstream has it. Changes, all marked `[vidas]`:
- the `push` trigger is `main` instead of upstream's `dev` (the fork's `dev` is only a mirror), and `**.yml` is not
  in its `paths-ignore`: every merge — including one that only changes this workflow — gets a full post-merge run
  that writes the cache baseline; a `workflow_dispatch` on `main` writes it too. Only runs on `main` ever save
  (`github.ref == 'refs/heads/main'`); feature branches restore through the `restore-keys` prefixes and never write
  (two entries, 2.2 GB after the trim step, 10 GB repo limit);
- a run with `only_testing` that matches no test fails ("No tests ran") instead of passing with 0 tests, and a green
  partial run is annotated PARTIAL;
- the Xcode/Swift version (`xcodebuild -version`) is part of the DerivedData and AlgorithmPackage cache keys;
- the informational "List available simulators" step (10–43 s) is gone; on a destination error the
  "Available destinations" lines are surfaced by the "Surface build errors" step instead;
- input `only_testing` (ONE identifier, e.g. `TrioTests/LogShipperTests`) runs one target/suite:
  `gh workflow run unit_tests.yml -R vidasrimkus/Trio --ref <branch> -f only_testing=TrioTests/LogShipperTests`.
  The run is annotated as partial; **the full run is still required before a merge** (CLAUDE.md rule 7).
  It reduces noise, not time: "Run tests" is mostly simulator boot and test-host install (29 tests took 295 s,
  800 tests 275 s on warm runs).
The baseline refreshes itself with every merge to `main` (a docs-only merge is ignored by `paths-ignore` and
changes nothing); after an Xcode image bump the first run is cold again.
`build_trio.yml` has no cache and is unchanged.

**Measured 2026-11-02** (`Run Unit Tests` job, macos-26, Xcode 26.2):

| Run | Resolve | Build for testing | Run tests | Job |
|---|---|---|---|---|
| Cold, before (41427506106) | 124 s | 557 s | 396 s | ≈ 20 min |
| Cold + cache save, post-merge push (41462220641) | 175 s | 713 s | 336 s | 23 min (save 120 s) |
| **Warm dispatch on `main` (41466038191)** | 55 s | 222 s | 275 s | **11 min** |
| Warm, `only_testing=TrioTests/LogShipperTests` (41467957343) | 101 s | 332 s | 295 s (29 tests) | 15 min |

Runner variance is large (restore 54 vs 108 s, build 222 vs 332 s between two warm runs); expect 11–15 min warm,
20–23 min cold.

## 3. Interfaces (other systems depend on these)

| Direction | Contract |
|---|---|
| LoopFollow → Trio | `vidasrimkus/LoopFollow` sends `command_type: "set_dosing_mode"` with `dosing_mode` = a `DosingMode` rawValue: `closed`, `open`, `lowGlucoseSuspend`, `basalTesting`. Encrypted exactly like the other TRC commands. Visible alert on the Trio phone: "Remote Command: Dosing Mode → <mode>". |
| Trio → LoopFollow | Result comes back only as the existing return push notification: title "Command Successful" / "Command Failed", body "Dosing mode: X → Y" or "Already in Y" (display names, localized; English on a Lithuanian phone). LoopFollow shows it as a notification; it does not parse it. |
| Trio → Nightscout → t1d-monitor, LoopFollow | Both read devicestatus `openaps.dosingMode` (set from `settingsManager.settings.dosingMode` at upload time, `NightscoutManager.swift`). The new mode appears there with the next loop cycle (≤ ~5 min). |
| LoopFollow → Trio (branch `feat/remote-basal-schedule`, not on main yet) | `command_type: "set_basal_schedule"` with `basal_schedule` = `[{"start":"HH:00","rate":<U/h>}]`, `basal_schedule_name`, `expected_active_hash` (§7). Result: return notification "Basal schedule activated: X (a → b U/d)", "Already active: X", or the error. Nightscout: the updated profile document (existing `uploadProfiles`) plus a Note "Basal schedule activated remotely: X (a → b U/d, <hash>)". |
| LoopFollow → Trio (branch `feat/remote-cr-isf`, not on main yet) | `command_type: "set_carb_ratios"` with `carb_ratio_schedule` = `[{"start":"HH:MM","ratio":<g/U>}]`, `command_type: "set_isf"` with `isf_schedule` = `[{"start":"HH:MM","sensitivity":<integer mg/dL>}]`; both with `schedule_name` and `expected_active_hash` (§11). Result: return notification "Carb ratios activated: X" / "ISF activated: X", "Already active: X", or the error (not parsed). Nightscout: the updated profile document (existing `uploadProfiles`) plus a Note "Carb ratios activated remotely: X (<hash>)" / "ISF activated remotely: X (<hash>)". |
| Trio → t1d-monitor (branch `feature/log-shipper`) | `POST /api/logs`, Bearer token, raw-DEFLATE JSON with the new bytes of `logs/log.txt` and `danakit/dana_log.txt`; response `{"accepted":[…]}`. Full contract in `docs/log-ingest-spec.md` (§8). |
| Trio → Nightscout → t1d-monitor (branch `feature/log-shipper`) | Notes `[trio-event v1] bolus_deleted …`, `bolus_failed …`, `pump_error …` (grammar in `docs/log-ingest-spec.md` §6.1). The same line is written to Trio's log. |

If any of these contracts changes, `vidasrimkus/LoopFollow` and `t1d-monitor` must change too.

## 4. Browser Build (GitHub Actions → TestFlight)

- Repository variables: `SCHEDULED_SYNC=false` (the fork never syncs itself from upstream),
  `ENABLE_NUKE_CERTS=true`.
- Secrets: `TEAMID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`, `FASTLANE_KEY`, `GH_PAT`, `MATCH_PASSWORD`
  (values live in 1Password only; `MATCH_PASSWORD` is shared with LoopFollow and encrypts `vidasrimkus/Match-Secrets`).
- Builds only from `main`. "4. Build Trio" also runs on its schedule (second Sunday of the month rebuilds `main`).
- Bundle `org.nightscout.B9R54LY699.trio`, Team `B9R54LY699` — the same bundle as the earlier Xcode build,
  so a TestFlight install replaces the app in place and keeps settings and pump/CGM pairing.
- First TestFlight build: 1.0.1 (2), 2026-09-26.

## 5. Pumps in use and Dana limitations (not changed by us — upstream/DanaKit behaviour)

Two pumps are used and swapped from time to time: **Dana** (DanaKit, `loopandlearn/DanaKit@e157a86`) and
**Omnipod DASH** (OmnipodKit, `loopandlearn/OmnipodKit@043b91d`). Facts read from the pinned driver sources
(re-checked for the v1.0.2 pins; the facts are unchanged, only line numbers moved):

1. **Trio's basal schedule is NOT written to a Dana when it is paired.** Trio passes its schedule as initial
   settings (`PumpConfigStateModel.swift:20-35`), DanaKit only stores it in its own state
   (`DanaUICoordinator.swift:73-74`). The only code that writes a schedule to the pump is
   `syncBasalRateSchedule` (`DanaKitPumpManager.swift:1097`), called by Trio's Basal Profile editor (and Autotune).
   Until then the pump runs whatever profile it already had; Trio does not detect a difference
   (`syncDeliveryLimits` reads the pump's rates but keeps only `maxBasal`, `DanaKitPumpManager.swift:1203-1279`).
2. **Trio's temp basals reach a Dana as a percentage** of the schedule DanaKit holds
   (`absoluteBasalRateToPercentage`, `DanaKitPumpManager.swift:1361-1380`); the pump applies that
   percentage to its own active profile. If the two differ, every non-zero temp delivers a different
   amount than Trio intended (0 % temps are unaffected).
3. **Only whole-hour segments are safe on a Dana.** `convertBasal` (`DanaKitPumpManagerState.swift:390-407`)
   maps the schedule onto 24 hourly rates; a segment starting off the hour (e.g. 02:30) stops the index
   from advancing, so every later hour gets the previous rate on the pump. Trio's editor allows a
   30-minute grid, so this can happen from the phone too.
4. **Rates are encoded as `UInt16(rate * 100)`** (`DanaBasalSetProfileRate.swift`; unchanged in e157a86 — its
   "round to 2 decimals" fix is for temp basals only), which truncates some
   values by 0.01 U/h (e.g. 0.29 → 0.28; at 0.05 steps 1.15, 2.05, 2.30, 2.55, 4.10, 4.35, 4.60, 4.85). The full
   list for 0.01–5.00 U/h on Trio's Decimal path (65 values) is the Dana truncation vector in §7.
5. Omnipod DASH, by contrast, stops all delivery (`cancelDelivery(.all)`) before programming a new schedule
   (`OmniPumpManager.swift:1882-1960`); a broken connection between the two steps leaves the pod suspended
   until it is resumed on the phone.

**Manual procedure after every Dana (re)connection** (new pairing, or back from Omnipod DASH):
Trio → Therapy → Basal Profile → change one value, Save, change it back, Save (Save stays disabled
without a change; each save writes the whole schedule to pump profile 0 and activates it). Then check on
the pump screen that the active profile's 24 hourly rates match Trio. t1d-monitor sends a Telegram
reminder when it sees a Dana connect (`dana-connected` rule).

## 6. Considered and REJECTED

**Forced loop right after a remote mode change** (branch `feat/remote-mode-immediate-loop`, commit
`d5054fe`, deleted). Idea: call `apsManager.heartbeat(date:)` after the write so the new mode reaches
Nightscout at once. Rejected after review: when switching into Basal Testing,
`APSManager.settingsDidChange` cancels the Trio temp in its own `Task` while the forced loop may enact a
temp at the same moment (`basalTesting.automation == .hypoSuspendOnly`, so the loop does enact) — two
unordered temp-basal commands to the pump; a protective zero temp could be overwritten. Decision: Trio's
behaviour stays as upstream; the remote change is confirmed by the Trio push notification, and the new
mode reaches Nightscout with the next regular cycle.

## 7. Remote command `set_basal_schedule` — Dana only (branch `feat/remote-basal-schedule`)

**Purpose.** Write a whole basal schedule to the pump and make it Trio's basal profile from LoopFollow.
Named profiles live in LoopFollow; Trio keeps its single `settings/basal_profile.json` as upstream.

**Files.** `Trio/Sources/Services/RemoteControl/RemoteBasalSchedule.swift` (new: pure rules),
`TrioRemoteControl+BasalSchedule.swift` (new: handler), `CommandPayload.swift` (`setBasalSchedule`,
`basal_schedule`, `basal_schedule_name`, `expected_active_hash`), `TrioRemoteControl.swift` (switch),
`project.pbxproj`, `TrioTests/RemoteBasalScheduleTests.swift`. No change to `APSManager`, `NightscoutManager`,
DanaKit or OmnipodKit.

**Order in the handler.**
1. Incomplete payload → rejected.
2. Pre-checks: pump must be a `DanaKitPumpManager` (Omnipod DASH → rejected with the explanation that the
   pod briefly stops all delivery and could not be resumed remotely; any other pump → rejected); not
   suspended/suspending/resuming; no bolus in progress (`bolusTrigger`); no loop running (`isLooping`).
   Nothing is queued — the sender retries.
3. Validation (`RemoteBasalSchedule.validate`): name 1–30 characters, no quotes or control characters;
   1–24 segments; first at 00:00; strictly increasing; **whole hours only** (`HH:00`); rate > 0 and ≤ Max
   Basal; rate a whole number of hundredths that is in the pump's `supportedBasalRates`; for a Dana,
   `UInt16(Double(rate) * 100)` must equal the hundredths (the Decimal → Double path the editor uses, then
   DanaKit's encoding) — otherwise rejected.
4. New schedule's hash == active hash → "Already active: X", nothing written (re-sending is safe). The hash
   is of what the schedule delivers, so this holds however either side splits it into entries.
5. `expected_active_hash` ≠ active hash → rejected ("the active basal schedule changed since it was read").
6. Write through the Basal Profile editor's own path, `BasalProfileEditor.Provider.saveProfile` (pump first,
   local file only on success). On failure nothing is saved in Trio and the error reads
   "Pompa galėjo priimti dalį pakeitimų. Pakartokite tą patį aktyvavimą arba patikrinkite pompą." — the
   expected hash is still the old active one, so the same command can simply be sent again.
7. On success the editor's follow-up: `basalProfileDidChange` broadcast, Nightscout `uploadProfiles`, Tidepool
   settings; plus a Nightscout Note "Basal schedule activated remotely: X (a → b U/d, <hash>)".

**Schedule hash (shared with LoopFollow) — depends on the schedule, not on how it is split.**
1. Sort the entries by start (minutes from midnight).
2. For each of the 48 half-hours `slot = 0 … 47` (minute `slot × 30`: 00:00, 00:30, … 23:30), take the rate of
   the entry with the latest start ≤ that minute; if there is none (schedule not starting at 00:00), take the
   last entry (a daily schedule wraps).
3. Convert each rate to whole hundredths of U/h: `rate × 100`, rounded half-up to an integer (Trio: Decimal
   `NSDecimalRound(.plain)`; LoopFollow: the same on Decimal, or `Int((rate × 100).rounded())` for Nightscout
   doubles — identical for 2-decimal rates).
4. Join the 48 integers with `;` (no spaces, no trailing separator).
5. Hash = lowercase hex of the first 8 bytes of SHA-256 over the UTF-8 bytes of that string (16 hex characters).

Works for any stored schedule, including one with 30-minute segments saved on the phone (which
`set_basal_schedule` itself does not accept). Vectors (tested in Trio `RemoteBasalScheduleTests` and LoopFollow
`BasalProfileTests`):

| Schedule | Canonical (48 values) | Hash | Daily total |
|---|---|---|---|
| V1: 00:00 0.40, 02:00 0.55, 03:00 0.55, 05:00 0.60, 06:00 0.60, 08:00 0.60, 10:00 0.70, 13:00 0.40, 19:00 0.45 | 40×4, 55×6, 60×10, 70×6, 40×12, 45×10 | `5c367b5397636149` | 12.2 U |
| V1 merged: 00:00 0.40, 02:00 0.55, 05:00 0.60, 10:00 0.70, 13:00 0.40, 19:00 0.45 | same | `5c367b5397636149` | 12.2 U |
| V2: 00:00 1.00 | 100×48 | `946f8ef5ec7fc61e` | 24 U |
| V3: 00:00 0.35, 07:00 1.20, 22:00 0.45 | 35×14, 120×30, 45×4 | `eabd566dccabc3e6` | — |
| V4 (30-min segment): 00:00 0.40, 02:30 0.50, 05:00 0.60 | 40×5, 50×5, 60×38 | `acff0d328fca2e73` | — |
| V5: 00:00 0.40, 02:00 0.55 (= 00:00 0.40, 02:00 0.55, 03:00 0.55) | 40×4, 55×44 | `b692201fbdc3d38e` | — |
| V6 (not starting at 00:00 — wraps; `set_basal_schedule` validation refuses it): 06:00 0.50, 20:00 0.30 | 30×12, 50×28, 30×8 | `69f813145c518801` | — |

("40×4" = the value 40 repeated in 4 consecutive slots.)

**Dana truncation vector (shared with LoopFollow).** Every rate from 0.01 to 5.00 U/h (1–500 hundredths), built as a
Decimal from its "D.DD" string, converted with `Double(truncating: rate as NSNumber)` (Trio's `Double(Decimal)`
extension, `Helpers/Decimal+Extensions.swift`) and encoded as DanaKit does, `UInt16(value × 100)`. These 65
hundredths come out different and are refused for a Dana (determined in CI on the real Foundation path; a plain
Double literal differs — e.g. 0.57 is truncated as a literal but not on this path):

`7, 14, 28, 29, 33, 56, 58, 66, 87, 91, 107, 111, 112, 115, 116, 132, 157, 174, 179, 182, 199, 205, 207, 214, 222,
224, 230, 232, 239, 247, 249, 255, 264, 289, 314, 323, 333, 339, 348, 358, 364, 373, 383, 389, 398, 403, 410, 414,
419, 423, 428, 435, 439, 444, 448, 453, 460, 464, 469, 473, 478, 485, 489, 494, 498`

Trio `RemoteBasalScheduleTests.danaTruncationTable` runs the full validation over all 500 and LoopFollow
`BasalProfileTests.danaTruncationTable` its own check; both must equal this list.

## 8. Log shipping to t1d-monitor and Trio event Notes (branch `feature/log-shipper`)

**Purpose.** See the Trio and DanaKit logs on our own server in near real time (after every loop cycle, ≈ 5 min)
instead of waiting for a "Share Logs" export, and get a Nightscout Note at once for the events that matter most
(a bolus deleted from History, a failed bolus, a pump error). Server contract: `docs/log-ingest-spec.md`.
**Off by default**; enabled in Settings → Support & Community → Log Shipper.

**Files.** New `Trio/Sources/Services/LogShipper/`:

| File | What |
|---|---|
| `LogShipper.swift` | `LogShipper` protocol, `BaseLogShipper` (scheduling, HTTP, backoff, offsets in `UserDefaults`, URL/token in Keychain), wire-format types (`LogShipmentPayload`, `LogShipmentCodec`, `LogShipperResponse`, `BackoffPolicy`). |
| `LogTailReader.swift` | Pure: next unsent bytes of a log file; follows the daily rename by `inode:creationDate`; flags gaps (missed rotation, truncation). |
| `LogRedactor.swift` | Pure: Dana keys in every DanaKit form (`pairingKey:`, `Pairing key:`, `random pairing key:`, `random sync key:`), passkey packets, APNS device token, query-string secrets, bearer tokens; every packet dump (`Data:`, `Receiving data:`, `Encoded data:`) within 20 lines before / 150 lines after a pairing line (the per-connect "Setting encryption keys" line is not a pairing line). |
| `TrioEventNotes.swift` | `TrioEvent`, the `[trio-event v1]` line format, `EventThrottle`. |
| `TrioEventReporter.swift` | Nightscout Notes through the existing `uploadNoteTreatment`; sources `apsManager.lastError` and `BolusFailureObserver`; the same line goes into Trio's log. |
| `LogShipperConfigView.swift` | Settings screen (URL, token, on/off, status, Send now). Not localized. |

Existing files: `ServiceAssembly.swift` (+2 registrations), `TrioApp.swift` (+2 eager resolves),
`HistoryStateModel.swift` (+1 injection), `HistoryStateModel+Insulin.swift` (`deleteInsulinFromServices` returns the
deleted bolus and reports it after the save), `SettingsRootView.swift` (+4: NavigationLink), `project.pbxproj`,
`TrioTests/ContainerResolutionTests.swift` (+2), new `TrioTests/LogShipperTests.swift`.
**No change to `APSManager`, `NightscoutManager`, `FetchGlucoseManager`, `OpenAPS*`, DanaKit or OmnipodKit.**

**Behaviour.**
- Trigger: `apsManager.isLooping` true → false (end of every loop, success or failure) → shipment 10 s later (lets
  DanaKit's log queue flush). Fallback: `glucoseStorage.updatePublisher` after every glucose store → shipment 15 s
  later (15 s + the 15 s request fit the ~30 s of background time iOS grants); if a loop is running at that moment it steps aside and the
  loop end ships the complete cycle, otherwise it ships (pump unreachable, no loop). At most once per minute: a request
  that comes sooner is deferred when the wait fits in the background grant (≤ 15 s), otherwise left to the next trigger;
  one that arrives while a shipment runs always runs right after it. The background task is taken before the delay
  (the reachability check comes after it — `docs/log-shipper-todo.md`); a running shipment is never cancelled. The loop
  never waits for it.
- Both files are read from their last accepted offset (`LogTailReader`), cut at a newline, ≤ 1 MB per stream per
  shipment (a day's backlog catches up in ≈ 80 min), redacted, JSON + raw DEFLATE, `POST` with Bearer token, 15 s timeout.
- The log files are the buffer: nothing is copied. Offline or server down → offsets stay; data survives until the
  phone's own rotation drops it (24–48 h), after which the next batch carries `gap_before: true`.
- Responses: 200 moves the offsets (a 2xx that accepts none of the sent batches counts as a failure); 401/403 pauses
  until settings are saved again; 413 halves the batch limit (floor 64 KB; doubles back towards 1 MB after three
  successful shipments in a row, resets on Save); 429/5xx → backoff 5 → 60 min (`Retry-After` honoured, seconds or
  HTTP date). A transport error (no route, request cut by iOS suspending the process) is only recorded — no backoff,
  the next trigger retries. First install ships
  from the start of the current day's files. A rotated (`_prev`) file is shipped to its last byte even without a
  trailing newline.
- Trio's log gets one line only on state changes (enabled/disabled, token refused, backoff entered/left, 413).
  Everything else is `os_log` only, so the shipper cannot feed its own log.
- Events: `bolus_deleted` (History → `deleteInsulinFromServices`, after the Core Data save; `delivered=true` for a
  finalized pump record, `false` for a pending one, absent for external insulin), `bolus_failed kind=manual`
  (`BolusFailureObserver`, paired with the preceding `lastError` text: held 3 s for it, or the most recent error
  within 30 s when the main thread was slower), `pump_error`
  (every other `lastError`; same text at most once per 30 min). SMB failures are `pump_error` — the amount follows in
  the log (decision: 0 lines in `APSManager`).

**What is not covered / accepted.**
- `uploadNoteTreatment` does not retry: a Note sent while offline is lost. The same line is in Trio's log, which
  the server extracts into `log_events`.
- iOS gives no guaranteed background time; the real cadence shows in the server's `from`/`to` continuity. A request
  that would have to wait more than 15 s (inside the 60 s minimum interval) is dropped, the next trigger ships; one
  that waited for a running shipment runs right after it regardless of the interval.
- Which error belongs to a failed manual bolus is a timing heuristic (`lastError` held 3 s for `bolusDidFail()`, or
  the most recent pump error within 30 s): a loop error in that window can be named instead. The exact fix is an
  `error` parameter on `BolusFailureObserver.bolusDidFail()` in `APSManager` — rule 2, decision: not done.
- A pairing split across two shipments can leak packet hex in the second one (own server, accepted).
- The Keychain token lets its holder post junk to `/api/logs`, nothing more. Rotate it on the server and the phone
  together; a rotation on the server alone pauses shipping (401) until the phone is updated.
- Battery not measured; ≈ 288 small HTTPS requests/day at the same moments as the Nightscout uploads.

**After installing a build with this:** open Settings → Log Shipper, enter URL and token, enable, press Send now,
check the status rows and the server's `log_batches`. Then confirm pump, CGM, loop and dosing mode as for any build.

## 9. Submodules hosted under `vidasrimkus`

History: on 2026-11-02 `loopandlearn/LibreCRKit` (in upstream v1.0.1's `.gitmodules`) returned 404, so every
checkout with submodules failed; we moved it to `vidasrimkus/LibreCRKit` and, as insurance, the pump/loop
submodules too. Upstream v1.0.2 replaced LibreCRKit with RoundWhiteDiscKit; with the upgrade (2026-11-03)
LibreCRKit is gone from the build (`vidasrimkus/LibreCRKit` stays, unused) and the same rule now covers the two
Libre submodules v1.0.2 changed.

**Rule:** same pinned commits as upstream; the `.gitmodules` URL is our only change. On an upstream upgrade, keep
our URLs and move the pinned commits (the forks copy all upstream branches, check the new pin is on one of them).

| Submodule | Our fork (of) | Pinned commit (v1.0.2) | Moved |
|---|---|---|---|
| DanaKit | `vidasrimkus/DanaKit` (loopandlearn/DanaKit) | `e157a861c` | 2026-11-02 |
| OmnipodKit | `vidasrimkus/OmnipodKit` (loopandlearn/OmnipodKit) | `043b91dbf` | 2026-11-02 |
| LoopKit | `vidasrimkus/LoopKit` (loopandlearn/LoopKit) | `f974241f5` | 2026-11-02 |
| LoopAlgorithm | `vidasrimkus/LoopAlgorithm` (loopandlearn/LoopAlgorithm) | `4604ee36f` | 2026-11-02 |
| RoundWhiteDiscKit (branch `main`) | `vidasrimkus/RoundWhiteDiscKit` (loopandlearn/RoundWhiteDiscKit) | `e66da6cc3` | 2026-11-03 |
| LibreLoop (branch `legacy-loopkit-compat`) | `vidasrimkus/LibreLoop` (loopandlearn/LibreLoop) | `c6e9cc158` | 2026-11-03 |

The other 11 submodules and all SPM packages still point at their upstream owners (decision 2026-11-02). The full
list with URLs and pinned revisions is `docs/dependencies.md`; t1d-monitor checks it daily.

Existing clones keep the old URLs in `.git/config` until `git submodule sync --recursive` is run once after
pulling a `.gitmodules` change (CI and the browser build clone fresh, so they are unaffected).

## 10. Pre-bolus timer (branch `feature/prebolus-timer`)

On the bolus screen, under "Recommendation", when carbs > 0: how long to wait between the bolus and the meal
("🍽️ Valgyk po 15 min (18:52)"). On "Enact bolus" one local notification "Laikas valgyti" is scheduled for that
time, and Home shows a countdown "🍽️ 12:40" (mm:ss) under the IOB/COB row until then.

The wait follows **the user's own pre-bolus system** (given 2026-11-03; it replaced the first BG-band table).
The bolus row has a food-type picker — 4 segments **Greitas / Įprastas / Lėtas / Riebus**, "Įprastas" by default
(a pick holds 30 min or until a meal bolus uses it).

1. **Safety first** (no timer): BG < 5.0, or a drop of ≥ 1.0 over the last 15 min → "🍽️ Valgyk iškart".
   Rise > 1.0 over the last 10 min → "Atrodo, jau valgai – kitą kartą bolusas anksčiau".
2. **Wait = max(minutes_bg, base)**, minutes_bg = round(BG mmol/L × 1.8) (the first two digits of mg/dL; halves
   up), base: Greitas 30 / Įprastas 15 / Lėtas 10 / Riebus 30 min.
3. **Trend** = Δ over the last 15 min:

| Food type | falling (≤ −0.3) | flat | rising (≥ +0.3) |
|---|---|---|---|
| Greitas, Riebus | 12 min | unchanged | +5 |
| Įprastas | 7 min | unchanged | 22 min (at least) |
| Lėtas | 0 → "🍽️ Bolusas valgant – valgyk iškart", no timer | unchanged | 17 min (at least) |

4. **Cap 35 min.**

Interpretation choices (the system did not say): rising for Įprastas/Lėtas never shortens the wait — "→ 22 / 17"
is applied as "at least 22 / 17" (BG ≥ 12.5 already gives more); falling sets the value (always shorter). No
reading ~15 min back (± 3 min) → treated as falling (the shorter wait), as in v1; the ≥ 1.0 drop rule then cannot
fire. Newest CGM older than 10 min → "Nėra šviežių CGM duomenų", no timer. All numbers and texts:
`PreBolusConstants.swift`. The chosen food type is stored with the armed timer and sent as `meal_type=`.

- Code: `Trio/Sources/Modules/Bolus/PreBolusTimer/` — `PreBolusPlanner` (pure), `PreBolusNotifier` (one
  `UNUserNotificationCenter` request `Trio.preBolusTimer`, `deadline` = the one source of truth for the Home
  countdown), `PreBolusTimerRow`, `PreBolusCountdownView`, `PreBolusConstants`.
- Existing files, one line each: `TreatmentsRootView.swift` (row after "Recommendation"),
  `TreatmentsStateModel.addPumpInsulin` (`enactBolus` callback `nil` → `PreBolusNotifier.shared.arm(…)`),
  `HomeRootView.swift` (`.overlay(alignment: .bottom)` on the meal-panel slot), and the two Cancel buttons
  (`HomeStateModel.cancelBolus`, `TreatmentsStateModel.cancelBolus`: `cancelBolus(nil)` →
  `cancelBolus(PreBolusNotifier.shared.cancelCallback)`). Plus `project.pbxproj`.
- Disarmed when the bolus fails before reaching the pump (enactBolus callback `false` after verifyStatus or with
  no pump); a pump error after the command (`APSError.pumpError` on `apsManager.lastError`, delivery
  uncertain) keeps the reminder (decision 2026-11-03). Also disarmed when a
  Cancel button cancels successfully, or when a newer wait replaces it. A later bolus without a wait (a
  correction, carbs 0, eat now…) leaves a running timer alone. Cancellation is not inferred from
  `bolusProgress` (a finished bolus can end below 100 % — rejected in review). `APSManager` unchanged.
- Notification: Trio's existing permission and `willPresent` delegate; deliberately not `TrioAlertManager`
  (its alert history would replay an unacknowledged "Laikas valgyti" after an app restart). Only with a pump
  bolus — not with External Insulin or carbs alone.
- Battery: the countdown seconds are drawn by the system (`Text(timerInterval:)`), the app runs no timer; one
  `TimelineView` wake-up at the deadline removes it, and only while Home is visible. The bolus-screen row
  re-evaluates once a minute while it is on screen.
- Tests: `TrioTests/PreBolusPlannerTests.swift`, `TrioTests/PreBolusNotifierTests.swift`.

v2 (branch `feature/prebolus-timer-v2`) — the meal start:
- Tap on the Home countdown → `confirmationDialog` "Valgau" / "Atšaukti" / "Uždaryti"; the 44 pt slot layout is
  unchanged. "Valgau" (`markEating`) ends the timer, removes the pending notification and records the meal start =
  now. "Atšaukti" (`cancel`) removes both and records nothing. The timer running out records meal start = its
  deadline (`finalizeIfExpired`): called by the countdown at the deadline while Home is visible and by
  `BaseTrioEventReporter` at the end of every loop cycle (`apsManager.isLooping` → false), so in the background it is
  noticed within one loop cycle, with the exact deadline as `at`. A "Valgau" tapped after the deadline counts as
  the timer's end. A bolus failure, a bolus Cancel, or a newer wait (before the old one ran out) record nothing;
  a newer wait after an old one ran out first reports the old one.
- Event: `[trio-event v1] meal_started at=<ISO> bolus_at=<ISO> planned_min=<n> actual_min=<n> via=button|timer
  meal_type=fast|normal|slow|fatty`
  (`TrioEvent.mealStarted`, `TrioEventNote.format`), sent through `TrioEventReporter.report` like the other
  events: Nightscout Note + `DEV:` log line (`docs/log-ingest-spec.md` §6.1). `bolus_at` = the "Enact bolus" tap.
- The armed timer (`deadline`, `bolusAt`, `plannedMinutes`) is kept in UserDefaults `PreBolusTimer.armed`: a
  relaunch restores the countdown and still reports the meal start. Found more than 6 h after its deadline it ends
  without an event. Not `TrioAlertManager`: nothing is shown again, only this state is restored.
- "Tylus priminimas" (Settings → Log Shipper → Pre-bolus, UserDefaults `PreBolus.silentReminder`, off by default):
  the notification uses `prebolus_silent.caf` (0.5 s of silence, `Resources/Sounds`) instead of the default sound.
  With `sound = nil` iOS shows the banner without vibrating whatever the interruption level (`.timeSensitive` only
  breaks through Focus); with a (silent) sound it vibrates per the system haptics setting — to be confirmed on the
  phone; footer text: "tik vibracija; jei telefonas nevibruoja – tik vizualinis pranešimas". In the foreground the
  existing `willPresent` shows it with the same (silent) sound — no extra app vibration. Read when a timer is armed.
  `interruptionLevel` stays `.active`.
- After a relaunch a bolus Cancel no longer removes the restored timer (the bolus that armed it is long finished);
  "Atšaukti" does.
- Files: `PreBolusNotifier.swift`, `PreBolusCountdownView.swift`, `PreBolusConstants.swift`, `TrioEventNotes.swift`,
  `TrioEventReporter.swift`, `LogShipperConfigView.swift`, `Resources/Sounds/prebolus_silent.caf` +
  `project.pbxproj` (IDs `B0B05E1A…18` / `…28`). No upstream file changed beyond v1's hooks.
- Rejected: moving the carb entry's time to the meal start — see `docs/prebolus-timer-todo.md`.

Stage 2 (not built):
- ~~Food type from the carb entry's note field~~ — done differently: the food-type picker on the bolus row.
- Live Activity countdown: needs a field in the shared `ContentState` (`LiveActivityAttributes.swift` and
  `LiveActitiyAttributes.swift`), `LiveActivityManager` to push it, and `LiveActivity/Views/LiveActivityView.swift`
  (synchronized folder, no pbxproj) — 4 upstream files, and upstream `dev` is actively reworking Live Activity
  (754d441c5), so a high rebase cost.

## 11. Remote commands `set_carb_ratios` and `set_isf` (branch `feat/remote-cr-isf`)

**Purpose.** Replace Trio's carb ratio or ISF schedule from LoopFollow (two separate commands and screens; named
profiles live in LoopFollow). CR/ISF are Trio-only files (`OpenAPS.Settings.carbRatios`,
`OpenAPS.Settings.insulinSensitivities`); nothing is written to the pump, so there is **no pump restriction**
(Dana and Omnipod DASH both accepted).

**Files.** `Trio/Sources/Services/RemoteControl/RemoteTherapySchedule.swift` (new: pure rules — validation, 48
slots, hashes, pre-check), `TrioRemoteControl+CarbRatios.swift` and `TrioRemoteControl+ISF.swift` (new: handlers),
`CommandPayload.swift` (`setCarbRatios = "set_carb_ratios"`, `setISF = "set_isf"`, keys `carb_ratio_schedule`,
`isf_schedule`, `schedule_name`; `expected_active_hash` shared with basal), `TrioRemoteControl.swift` (switch),
`project.pbxproj`, `TrioTests/RemoteTherapyScheduleTests.swift`. Basal (`set_basal_schedule`, §7) unchanged; no change
to `APSManager`, `NightscoutManager`, the editors or any pump driver.

**Order in the handler** (both commands).
1. Incomplete payload (schedule, `schedule_name` or `expected_active_hash` missing) → rejected.
2. Loop running (`isLooping`; no `APSManager` → treated as running) → rejected, nothing queued (sender retries).
   No pump check.
3. Validation: name 1–30 characters after trimming spaces, no quotes or control characters (the basal rule);
   1–48 entries; first `00:00`; every start `HH:00` or `HH:30` (two digits each), < 24:00; strictly increasing.
   CR: 1.0 ≤ ratio ≤ 50.0 and a whole number of tenths (the editor grid). ISF: a whole number of mg/dL, 9…540 (the
   editor picker).
4. The 48 half-hour slots of the new schedule equal the stored ones **exactly** (Decimal per slot; CR g/U, ISF
   mg/dL) → "Already active: X", nothing written.
5. `expected_active_hash` ≠ hash of the stored schedule (CR hash / ISF Nightscout-form hash in the **current**
   `settings.units`) → rejected ("the active … changed since it was read").
6. Save exactly as the editor: `CarbRatios(units: .grams, schedule:)` / `InsulinSensitivities(units: .mgdL,
   userPreferredUnits: .mgdL, sensitivities:)`, entries `start "HH:MM:00"`, `offset` = minutes, through
   `CarbRatioEditor.Provider` / `ISFEditor.Provider.saveProfile` (the ISF provider's legacy mmol → mg/dL migration
   runs on read, as when the editor opens).
7. Editor follow-up: `CarbRatiosObserver.carbRatiosDidChange` / `InsulinSensitivitiesObserver.insulinSensitivitiesDidChange`
   on main, Nightscout `uploadProfiles`, Tidepool `uploadSettings`; plus a Nightscout Note "Carb ratios activated
   remotely: X (<new hash>)" / "ISF activated remotely: X (<new hash>)".
8. Return notification "Carb ratios activated: X" / "ISF activated: X" / "Already active: X" / the error.

**Slots and hashes (shared with LoopFollow).** Slots as in §7 steps 1–2 (48 half-hours, latest start ≤ the minute,
else the last entry — daily wrap). Hash = lowercase hex of the first 8 bytes of SHA-256 over the UTF-8 canonical
string; values rounded half-up (`NSDecimalRound(.plain)`), joined with `;`:
- CR: `"cr;"` + 48 × `ratio × 10`.
- ISF Nightscout form (what `uploadProfiles` sends as `sens`): units mg/dL → `"isf-mgdl;"` + 48 × mg/dL; units
  mmol/L → `"isf-mmol;"` + 48 × `asMmolL(mg/dL) × 10` (`asMmolL` = × 0.0555, one decimal, half-up, `BloodGlucose.swift`).
  Lossy in mmol/L (46 and 47 mg/dL are both 2.6), hence only a guard; "Already active" compares exact mg/dL.

| Schedule | Canonical | Hash |
|---|---|---|
| CR1: 00:00 10.0, 06:00 8.5, 11:00 12.0, 17:00 10.5 | cr; 100×12, 85×10, 120×12, 105×14 | `d0f731e0166dbc52` |
| CR2: 00:00 10 | cr; 100×48 | `eb0120f2d30d1482` |
| CR3: 00:00 9.0, 07:30 7.5, 20:00 11.0 (also split with 03:00 9.0) | cr; 90×15, 75×25, 110×8 | `82bc62b67556f34a` |
| CR4 wraps (validation refuses it): 06:00 8.0, 21:00 12.0 | cr; 120×12, 80×30, 120×6 | `ae96c8ecc9e86a8b` |
| ISF1 mg/dL form: 00:00 180, 08:00 150, 22:00 200 | isf-mgdl; 180×16, 150×28, 200×4 | `88ce4c3c77da0c2b` |
| ISF1 mmol/L form (NS shows 10.0 / 8.3 / 11.1) | isf-mmol; 100×16, 83×28, 111×4 | `2d0d147868c7adf5` |
| ISF2 mg/dL form: 00:00 46, 12:30 47 | isf-mgdl; 46×25, 47×23 | `4701d2c3453569ad` |
| ISF2 mmol/L form (both 2.6) | isf-mmol; 26×48 | `39a70ffcfeb762f2` |

Tested in Trio `RemoteTherapyScheduleTests`; LoopFollow must test the same vectors.

**Known edge.** In mmol/L, Trio's ISF editor offers only the smallest mg/dL of each 0.1 mmol/L bucket
(`PickerSettingsProvider.generatePickerValues`); a remotely set value such as 47 (shown 2.6) is not one of them. The
editor then shows the closest picker value; saving on the phone after changing *another* row rewrites that row to the
picker's mg/dL (same mmol/L on screen, ≤ 1 mg/dL difference).
