# CLAUDE.md — vidasrimkus/Trio

## What this repo is

A fork of nightscout/Trio. **It is the insulin-dosing app on a child's phone.** Every change can
change how much insulin is delivered. Read `CUSTOMIZATIONS.md` before any work.

## Binding rules

1. **Never push to `main` and never run "4. Build Trio" without Vidas's explicit word.** A push to
   `main` is what the next build ships; a build reaches the phone through TestFlight.
2. **Deviate from upstream as little as possible.** Change only what is strictly needed. Never change
   the algorithm or loop behaviour (`OpenAPS/`, `OpenAPSSwift/`, `APSManager` loop/enact logic,
   `Preferences+DosingMode.swift`).
3. **Every commit of ours starts with `[vidas] `.**
4. **Never use GitHub "Sync fork" and never change `SCHEDULED_SYNC`** (it stays `false`). Upstream
   changes come in only through the procedure below.
5. **If an interface with LoopFollow or t1d-monitor changes** (see `CUSTOMIZATIONS.md` §3), say exactly
   what has to change in `vidasrimkus/LoopFollow` and/or `t1d-monitor`.
6. **Two pumps are used: Dana and Omnipod DASH.** Read `CUSTOMIZATIONS.md` §5 before touching anything
   basal- or pump-related: a Dana does not receive Trio's schedule when paired, gets temp basals as a
   percentage of DanaKit's copy, needs whole-hour segments, and truncates some rates. After every Dana
   (re)connection the schedule must be saved from Trio by hand (procedure in §5).
7. Tests run on GitHub, not locally (no Swift toolchain on the Windows machine):
   `gh workflow run unit_tests.yml -R vidasrimkus/Trio --ref <branch>`. Before any merge proposal:
   green tests + a reviewer pass on the final commit.

## Upstream update procedure

a. Read `CUSTOMIZATIONS.md`.
b. Fetch the nightscout/Trio release tag (`git fetch upstream --tags`).
c. Branch `upgrade/vX.Y.Z` from `main`; `git merge vX.Y.Z`.
d. Resolve conflicts keeping our behaviour. If upstream has substantially changed `DosingMode`,
   `CommandPayload`, `TrioRemoteControl` or `NightscoutStatus.dosingMode`, **STOP and explain it to Vidas**
   before resolving anything.
e. Check every interface listed in `CUSTOMIZATIONS.md` §3 against the merged code.
f. Run `unit_tests.yml` on the branch, then the reviewer.
g. Update `CUSTOMIZATIONS.md` (new base version, commits, anything that moved).
h. **Stop before merging to `main`**; show results and wait for Vidas's word.
i. After the build, remind Vidas: install the TestFlight build on the child's phone **during the day**,
   export CSV before, and check after — pump, CGM, loop running, dosing mode. **If a Dana is in use,
   also check the pump's active basal profile (24 hourly rates) against Trio's Basal Profile, and if
   they differ run the manual procedure in `CUSTOMIZATIONS.md` §5.**
