# LogShipper — deferred work

Review findings that were not fixed before the first TestFlight build (rule: after the second review round only
findings that can break Trio / dosing, lose or corrupt data, or leak secrets are fixed before a build; the rest is
listed here and taken up after the feature has run on the real phone). Sources: `Trio/Sources/Services/LogShipper/`,
behaviour in `CUSTOMIZATIONS.md` §8, server contract in `docs/log-ingest-spec.md`.

Check first what the real phone shows (server `log_batches`: `from`/`to` continuity, `received_at - sent_at`,
batches per day, bytes per batch; iOS Battery screen for Trio before/after) — several items below may turn out not
to matter.

## Cadence / background time

1. **Fallback wins over the loop end.** Glucose store at T schedules the fallback (due T+15). When the loop ends at
   T+14 the loop-end request (due T+24) is later than the sleeping fallback and is dropped; the fallback ships ~1 s
   after `isLooping` went false, before DanaKit's log queue and `finalizeLoop`'s own lines ("Loop succeeded", the
   enacted upload) are written — they ship one cycle late, every cycle. Fix: let a loop-end request replace a sleeping
   fallback (carry a priority with the pending request), or have the fallback wait `settleDelay` after the last loop
   end before shipping. (`LogShipper.swift`, `requestShipment`.)
2. **Background task before the checks.** `beginBackgroundTask` is taken before the enabled/reachability guards, so
   offline the process is kept awake 10–15 s per trigger for a "No network, skipped". Move the guards (except `force`)
   before the task. Measure first: it is ~25 s of awake time per cycle only while there is no network at all.
3. **Suspension-safe upload.** The 15 s request can still be cut when iOS suspends the process (transport error,
   retried on the next trigger — no backoff). The root fix is a `URLSessionConfiguration.background` session, which
   completes after suspension; worth it only if `received_at - sent_at` or missing batches show it on the real phone.
4. **Bolus error attribution is a timing heuristic** (`TrioEventReporter`: `lastError` held 3 s for `bolusDidFail()`,
   or the most recent pump error within 30 s). A loop error inside that window can be named instead of the bolus's.
   Exact fix: an `error` parameter on `BolusFailureObserver.bolusDidFail()` at `APSManager.swift:649/693` — rule 2
   (no `APSManager` change) says no for now; revisit if the Notes mislead in practice.

## Small / cleanup

5. `TrioEventNote.isoFormatter` duplicates `Formatter.iso8601` (`Trio/Sources/Helpers/Formatters.swift`); use the
   shared one for `at=` and `sent_at`.
6. `LogRedactor.isPairingMarker` runs twice per line (forward and reverse pass); compute the marker flags once.
7. `docs/dependencies.md` `generated_from` says `5c6b74a84` (generated before its own commit `7b92dea9b`); the
   content is right. Regenerate on the next dependency change.
8. The pairing-window redaction is line-count based (20 before / 150 after); a pairing split across two shipments
   lets the second shipment's first packets through. Acceptable for our own server; tighten only if the server
   ever leaves our control.

## To verify on the phone (not code)

- Battery: ≈ 288 HTTPS requests/day at the same moments as the Nightscout uploads — compare the iOS Battery screen
  for a day with shipping off and a day with it on.
- Real cadence: in `log_batches`, `to - from` per batch and the gap between consecutive `received_at` for each
  stream; expect ≈ 5 min, with `gap_before` only after offline periods longer than a day.
- Dana stream size with the Omnipod DASH in use (should drop to zero) and with the Dana during a re-pairing (the
  `[redacted:pairing]` window should cover the handshake and nothing else).
