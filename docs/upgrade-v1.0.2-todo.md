# Upgrade to v1.0.2 — open items (not blocking the build)

- `TrioEventReporter` ignores the new `Bool` result of `uploadNoteTreatment` (v1.0.2 made it `@discardableResult`);
  it could log a failed Note upload. Reason: the line is written to the log anyway (spec §6.1), the log is the backup.
- nightscout/Trio#1669 (some basal rates show as 0.01 U/h in the Basal Profile list): reported on `dev` 4cc5e7b,
  also seen with Tandem Mobi; the editor code is identical in v1.0.1, v1.0.2 and that commit, and the reporter's
  pump never ran 0.01 (`currentBasal` 0.52/0.55/0.8 in the Dana log). Watch upstream. Reason: display only, not new.
- `vidasrimkus/LibreCRKit` is no longer referenced by the build; keep or archive. Reason: harmless.
- v1.0.2 escalates "not looping" alerts on the phone (20…100 min, critical at 120); t1d-monitor `loop-stale`
  alerts in Telegram too. Decide whether to keep both. Reason: duplicate notice, not a fault.
