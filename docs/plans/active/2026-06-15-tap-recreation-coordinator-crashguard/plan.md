# Tap-Recreation Coordinator + CrashGuard Async-Signal-Safety — Implementation Plan

> **Execution:** Use `/implement` to execute this plan.

**Goal:** Replace the two overlapping, state-clobbering tap-recreation mechanisms with one serialized recreation *transaction* that snapshots/suppresses **before** restart-time device churn, drains in-flight switch work, reconciles against reality on close, and make the crash signal handler async-signal-safe by removing crash-time HAL cleanup (relying on startup orphan cleanup).
**Type:** Architecture (structural reliability refactor; complex-bug root cause)
**Chosen approach:** H4 = serialized recreation coordinator inside `AudioEngine` (Option A); H5 = drop crash-time HAL cleanup (Option A). H4b (permission-driven mute) folded in. Monitor ordering = `willBegin` hook **and** active-transaction churn suppression (both).
**Plan created:** 2026-06-15 · **Revised:** 2026-06-15 (post adversarial-critique cycle 1)
**Base commit:** 7f55e64 (Finish multi-device startup routing fix)

User-facing? **No.** No UI entry point. **User Access Inventory: N/A** (intentionally omitted).

---

## Acceptance Criteria

Verifiable via `swift test` (FineTuneIntegrationTests target) with mocks; no running Xcode instance. Because `AudioEngine.init` skips all device-callback wiring under XCTest (`AudioEngine.swift:223` early-returns before the wiring `Task` at `:225`), **tests drive the engine's recreation/churn entry points directly via internal `*ForTests` seams (Task P0), not by firing monitor closures.** Monitor event *ordering* is tested separately at the monitor level (Task 2).

**H4 — recreation lifecycle**
1. A coalesced burst of recreation triggers produces **one logical recreation transaction** (`recreationTransactionCountForTests == 1`) — no nested transaction; no stale/cancelled task can clear suppression for the active transaction.
2. After a restart, **all** of the following return to pre-restart values: in-memory `appDeviceRouting`, persisted single-device routing, in-memory `followsDefault`, in-memory selection mode + selected-UID sets (`VolumeState`), and persisted selection mode + selected UIDs (`SettingsManager`). **No switch/update `Task` spawned before the transaction can mutate state after restore.** Canonical order (stated once; all tasks must match): the transaction captures its snapshot **synchronously at `willBegin`** (pristine, before any churn) and cancels in-flight `switchTasks` there; the owning `Task` then **drains (awaits) those cancelled tasks before restore**. Each switch-task body **always** removes its own `switchTasks` entry via a `defer` (so `activeSwitchTaskCountForTests == 0` regardless of cancellation) and guards **only its post-`await` state mutations** (`tap.*`, `appDeviceRouting` revert) with `Task.isCancelled`.
3. A second trigger mid-flight (second restart, or the probe-driven permission downgrade that today calls `recreateAllTaps`) is **coalesced** into the active transaction, never nested. Coalesced reasons are **metadata consumed by the in-flight transaction** (they may extend its recreate/probe work); they do **not** open a second transaction for the same burst, and the `defer` does **not** spawn one. A new transaction opens only for a trigger arriving **after** the `defer` has cleared the active flag. Hence `recreationTransactionCountForTests == 1` for any single burst.
4. The snapshot is taken, suppression is engaged, and in-flight `switchTasks` are cancelled **before** any restart-time disconnect/connect handler runs — i.e., synchronously at `onServiceRestartWillBegin`, not at `onServiceRestarted`.
5. While a transaction is active, `handleDeviceDisconnected`/`handleDeviceConnected` do **not** mutate routing/`followsDefault`/selection state; restart-time transient device events are **dropped** (not replayed), and `routeAllApps` (via `onDefaultDeviceChangedExternally`, `AudioEngine.swift:259`) stays blocked for the entire transaction.
6. **Reconcile-on-close:** after restore, the transaction reconciles each app against the current device list, mirroring `handleDeviceDisconnected` semantics exactly — so dropping a *genuine* restart-time disconnect never strands routing/selection on a gone device. This is reconciliation against current reality, **not** replay of the dropped events. Rules:
   - **Single-mode**, restored routing UID absent → re-resolve to fallback **in-memory only** (do not persist), matching `AudioEngine.swift:1588–1591`.
   - **Multi-mode**, a restored selected UID absent → remove it from the selected set **in-memory and persisted** (`volumeState.setSelectedDeviceUIDs`, matching `:1565–1575`) and update the tap to the remaining devices; if the set empties, fall back to single-mode resolution.

**H4b — permission-driven mute (folded in)**
7. When `permissionConfirmed == false`, newly created taps use `muteOriginal: false` (`.unmuted`); when `true`, `.mutedWhenTapped`. The probe-driven permission-loss recovery path produces **unmuted** taps as its final state, not muted ones.

**H5 — crash-time cleanup**
8. After `CrashGuard` removal there is **no crash signal handler** (SIGABRT/SEGV/BUS/TRAP get default behavior → crash report). The only remaining signal handling is the SIGTERM/SIGINT `DispatchSource` graceful-shutdown handlers (`FineTuneApp.swift:116–135`), which run on a dispatch queue — **not** async-signal context. *(Verified by source audit: no async-signal handler remains that calls HAL/IPC/locks/allocation/Swift collections/logger/ObjC.)*
9. A crash does not **permanently** leak aggregate devices — startup `OrphanedTapCleanup` destroys all `FineTune-*` aggregate devices; verified by an **injectable** cleanup test.
10. The `CrashGuard` tracking buffer (`gDeviceSlots`/`gDeviceCount`/`gDeviceLock`), `trackDevice`/`untrackDevice`, and all their call sites are **removed** (no inert complexity). The paired runtime `AudioHardwareDestroyAggregateDevice` teardowns stay. Docs/CHANGELOG corrected.

---

## Prerequisites

**P0 — Test seams (no behavior change). Two kinds:**

*Read-only observation accessors on `AudioEngine` (`internal`, no raw mutable exposure):*
- `var recreationTransactionCountForTests: Int` (monotonic; +1 per opened transaction — proves coalescing)
- `var isInRecreationTransactionForTests: Bool`
- `var suppressesDeviceNotificationsForTests: Bool` (current `shouldSuppressDeviceNotifications`)
- `func followsDefaultSnapshotForTests() -> Set<pid_t>`
- `func appDeviceRoutingSnapshotForTests() -> [pid_t: String]`
- `var activeSwitchTaskCountForTests: Int`
- `func muteOriginalForTests(pid: pid_t) -> Bool?` (reads `taps[pid]?.muteOriginal`; `taps` is `private` at `:23`, so this accessor is **required** — the existing `onTapCreationDeviceUIDsAttemptForTests` fires *before* the controller exists and carries no mute flag)

*Driver entry points on `AudioEngine` (`internal`, because the production wiring `Task` is skipped under XCTest):*
- `func serviceRestartWillBeginForTests()` → calls the same handler `onServiceRestartWillBegin` is wired to
- `func serviceRestartDidCompleteForTests()` → calls the handler `onServiceRestarted` is wired to (`requestTapRecreation(.serviceRestart)`)
- `func deviceDisconnectedForTests(uid:name:)` / `func deviceConnectedForTests(uid:name:)` → call `handleDeviceDisconnected`/`handleDeviceConnected`
- (Alternatively, make those handler methods `internal` and call them directly — implementer's choice, but the seam must exist.)

*Controllable in-flight switch seam (required for the M1 regression test).* `taps` and `switchTasks` are `private` (`AudioEngine.swift:23/:31`) and the disconnect path only spawns a switch task when a *real activated tap* exists (`:1594`), so a test cannot install seeded in-flight switch work via the public surface. First extract the production switch-task structure into a **shared generic, throwing wrapper** `runSwitchTask<T>(pid: pid_t, operation: @escaping () async throws -> T, commit: @escaping (T) -> Void)` that: (i) `defer`s `switchTasks.removeValue(forKey: pid)` so cleanup **always** runs; (ii) `let result = try await operation()`; (iii) `guard !Task.isCancelled else { return }` — **then** `commit(result)`. `operation` is the awaited switch (`tap.switchDevice`/`updateDevices`); `commit` is the post-`await` **state mutation** (`tap.volume`/`isMuted`/`currentDeviceVolume`, routing revert). The Task-4 disconnect bodies are refactored onto this wrapper, instantiating `T` at each call site's return type (`Void` where the switch returns nothing). Then add `func installInFlightSwitchTaskForTests(pid: pid_t, operation: @escaping () async throws -> Void, commit: @escaping () -> Void)` that drives `operation`/`commit` **through the same wrapper with `T == Void`** (adapting the no-arg test `commit` as `{ _ in commit() }`; a non-throwing test `operation` is accepted where `() async throws -> Void` is expected). The test holds `operation` suspended (awaiting a continuation it releases) and passes a `commit` that sets a flag; after open→cancel→drain it asserts the flag stayed false (guard worked) and `activeSwitchTaskCountForTests == 0` (cleanup ran) — proving the **production** guard, with no real `ProcessTapController`.

These seams are added in the task that first needs them (noted per task), each behind no runtime cost in production.

**P1 — `Package.swift` registration.** New test files must be appended to the explicit `sources:` array of `FineTuneIntegrationTests` (`Package.swift:53–89` uses explicit lists, **not** globs) or they will not compile/run. New files: `ServiceRestartCoordinatorTests.swift`, `OrphanedTapCleanupTests.swift`. (Edits are folded into the creating tasks, called out explicitly.)

---

## Approach

### Why Option A (serialized coordinator) over Option B (reentrancy token)
Option B keeps two mechanisms and still needs the `willBegin` ordering hook to fix pre-snapshot churn — not lighter, and leaves two state-sharing mechanisms. Option A makes `AudioEngine` the single owner: one entry `requestTapRecreation(reason:)`, one owning `Task`, one authoritative snapshot, suppression cleared once at transaction end (after the awaited finalize phase). Eliminates the bug *class*. (User-chosen; orchestrator concurs.)

### Why Option A (drop crash HAL) over Option B (watchdog) for H5
`OrphanedTapCleanup.destroyOrphanedDevices()` (`OrphanedTapCleanup.swift:13`) already destroys all `FineTune-*` aggregates by name on every startup (`FineTuneApp.swift:33`), independent of tracked IDs. Crash-time destruction is a "now vs. next-launch" optimization; the residual gap is bounded and self-healing. A watchdog is far more machinery than the risk warrants. (User-chosen; orchestrator concurs.)

### Suppression binding (load-bearing)
The transaction is the single suppression source. The transaction sets `isRecreatingTaps = true` synchronously at `willBegin` and clears it **after `await finalizeTransaction()` returns** (so suppression covers the awaited reconcile); a `defer` clears it as a synchronous safety net should the body throw/early-return. `shouldSuppressDeviceNotifications` (`:135`) keeps reading `isRecreatingTaps || withinGracePeriod` — the grace window (`recreationGracePeriod`, `:70`) is **retained** as the late-async backstop for debounced notifications that land just after the transaction ends. The old `serviceRestartTask` (`:73`) is **removed** — its role is subsumed by the transaction's owning `Task`. `recreationEndedAt` is set at the same point `isRecreatingTaps` is cleared.

### Transaction sequence (one owning `Task`)
`willBegin` (synchronous): set transaction-active + `isRecreatingTaps = true`, `captureTransactionSnapshot()` (pristine, pre-churn), cancel `switchTasks`. → owning `Task`: **drain** (await) the cancelled switch tasks; tear down taps; on `onServiceRestarted`, recreate via `applyPersistedSettings` (taps built with `muteOriginal: permissionConfirmed`); run the permission probe (upgrade/downgrade, the downgrade coalesced, not nested); then **`await finalizeTransaction()`** — `restoreTransactionSnapshot()` followed by **reconcile-on-close** (single/multi rules, criterion 6; multi-mode calls the **async** `updateDevices(to:)`, `ProcessTapController.swift:561`, so finalization must be an awaited phase, **not** a `defer`) — and only after it returns, clear `isRecreatingTaps` + set `recreationEndedAt`. A `defer` is used **only** as a synchronous safety net guaranteeing `isRecreatingTaps` is cleared and `recreationEndedAt` set even if the body throws/early-returns. Coalesced reasons accumulated during the transaction are **consumed as metadata only** — finalization never opens a follow-up transaction for the same burst.

### Architectural seam check
- **`AudioDeviceMonitor` → `AudioEngine`** (`onServiceRestartWillBegin`, no payload): one new ordered callback before churn. Strengthens the contract (explicit begin/refresh-complete phases). Closure only.
- **`AudioEngine` → `SettingsManager`/`VolumeState`** (selection snapshot/restore): value-type snapshots (`Dictionary`/`Set`). `SettingsManager` stores `appSelectedDeviceUIDs` as `[String:[String]]` (`:149`) while `VolumeState` uses `Set<String>` — round-trip converts Array↔Set; tests assert as `Set` (order not preserved). Mirrors `snapshotDeviceRoutings`/`restoreDeviceRoutings` (`:211/:215`).
- **`AudioEngine` → `ProcessTapController`** (`muteOriginal: permissionConfirmed`): `Bool` at construction; supported init param (`ProcessTapController.swift:299`, default `true`).
- `followsDefault` is **in-memory only** — there is no persisted counterpart; `SettingsManager.isFollowingDefault` (`:190`) is *derived* as `appDeviceRouting[id] == nil`. Only the in-memory `Set<pid_t>` (`AudioEngine.swift:29`) needs snapshot/restore.
- All recreation state owned by `AudioEngine` (`@MainActor @Observable`); no new shared mutable state, no locks.

---

## Wiring Map

| # | Boundary | Source → Target | What Crosses | Test Pattern |
|---|----------|-----------------|--------------|--------------|
| W1 | Restart begin ordering | `AudioDeviceMonitor` internal | `onServiceRestartWillBegin` fired before churn | Monitor-level: HAL-free emit seam asserts willBegin precedes disconnect/connect and `onServiceRestarted` |
| W2 | Restart → recreate | engine entry `serviceRestartDidCompleteForTests` | `.serviceRestart` reason | Drives `requestTapRecreation` once per restart → one transaction |
| W3 | Churn during transaction | engine entry `deviceDisconnectedForTests` | uid/name | While transaction active → no routing/selection/`followsDefault` mutation; `activeSwitchTaskCountForTests == 0` |
| W4 | Routing snapshot | `AudioEngine` → `SettingsManager` | persisted routing + selection dicts | Snapshot/restore round-trips persisted routing + selection (assert as Set) |
| W5 | Selection snapshot | `AudioEngine` → `VolumeState` | per-pid mode + UID set | Snapshot/restore round-trips in-memory selection |
| W6 | Permission → mute | `AudioEngine` → `ProcessTapController` | `muteOriginal: permissionConfirmed` | `permissionConfirmed == false` → `muteOriginalForTests(pid) == false` |
| W7 | Reconcile-on-close | `AudioEngine` internal | restored routing vs current device list | Restart with a device genuinely absent → after transaction, routing re-resolved to a present device |
| W8 | Crash cleanup | startup → `OrphanedTapCleanup` | injected lister + destroyer | `FineTune-*` aggregates destroyed; non-FineTune untouched |

Each row → a wiring test task (separate tier from unit tests).

---

## Tasks

> TDD order per task: write test → run → verify FAIL → implement → verify PASS → one commit. Tasks do **not** run `swiftlint`. New test files MUST be appended to `FineTuneIntegrationTests.sources` in `Package.swift` (explicit list) in the same task that creates them.

### Task 1: Snapshot/restore scope expansion (state model first)
**Acceptance criterion:** 2 (W4, W5)
**Files:**
- Modify `FineTune/Settings/SettingsManager.swift` — add `snapshotSelectionState() -> (modes: [String: DeviceSelectionMode], uids: [String: [String]])` and `restoreSelectionState(_:)` mirroring `snapshotDeviceRoutings`/`restoreDeviceRoutings` (`:211/:215`); back onto stored props `settings.appDeviceSelectionMode` (`:148`) and `settings.appSelectedDeviceUIDs` (`:149`, `[String:[String]]`).
- Modify `FineTune/Models/VolumeState.swift` — add `snapshotSelectionState() -> [pid_t: (mode: DeviceSelectionMode, uids: Set<String>)]` and `restoreSelectionState(_:)` over `states` (`:22`).
- Modify `FineTune/Audio/AudioEngine.swift` — replace the `routingSnapshot` tuple (`:100`) with a `RecreationSnapshot` struct: `appDeviceRouting` (`:25`), `followsDefault` (`:29`), persisted routing, persisted selection, in-memory selection. Rename `snapshotRouting`/`restoreRouting` (`:141/:151`) → `captureTransactionSnapshot`/`restoreTransactionSnapshot`.
- Test: extend `testing/tests/SettingsManagerRoutingTests.swift` + `testing/tests/AudioEngineCharacterizationTests.swift` (existing files — no Package.swift change). Round-trip: mutate all fields → snapshot → mutate again → restore → assert equality on every field (UIDs asserted as `Set`).

### Task 2: `AudioDeviceMonitor.onServiceRestartWillBegin` hook (ordering)
**Acceptance criterion:** 4 (W1)
**Files:**
- Modify `FineTune/Audio/AudioDeviceMonitor.swift` — add `var onServiceRestartWillBegin: (() -> Void)?`; fire it at the **top** of `handleServiceRestartedAsync()` (`:275`), before the device reads (`:287`) and churn callbacks (`:305`). Extract the churn-emission logic (the `disconnected/connected` diffing + callback firing, `:305–338`) into an `internal func emitRestartEvents(previousOutput:currentOutput:previousInput:currentInput:)` so a test can drive it with **synthetic** before/after UID sets (the real `readDeviceList`/`readTransportType`/`readDeviceName` are nonisolated HAL calls a test cannot fake — confirmed; this seam avoids HAL entirely).
- **Package.swift:** create `testing/tests/ServiceRestartCoordinatorTests.swift` and append it to `FineTuneIntegrationTests.sources`.
- Test (`ServiceRestartCoordinatorTests.swift`): assert `emitRestartEvents` invokes `onServiceRestartWillBegin` before any `onDeviceDisconnected`/`onDeviceConnected` and before `onServiceRestarted`.

### Task 3: Recreation coordinator — single transaction entry
**Acceptance criterion:** 1, 3 (W2) + P0 driver/observer seams
**Files:**
- Modify `FineTune/Audio/AudioEngine.swift`:
  - Add P0 seams (observation accessors + driver entry points).
  - Add `func requestTapRecreation(reason: TapRecreationReason)` — the **sole** entry. One active transaction (one owning `Task`); if active, **coalesce** the reason (merge into a pending set of *metadata*) — never start a nested transaction, and the `defer` never opens a follow-up for the same burst. Increment `recreationTransactionCountForTests` once per opened transaction.
  - Transaction open (the `willBegin` handler, synchronous): set transaction-active + `isRecreatingTaps = true`, `captureTransactionSnapshot()` (pristine, pre-churn), cancel all `switchTasks` (`:372–373`).
  - Owning `Task` (in order): **drain** (await) the cancelled `switchTasks` to quiescence → teardown → recreate/probe → **`await finalizeTransaction()`** (`restoreTransactionSnapshot()` → reconcile (Task 6), which may `await` `updateDevices` for multi-mode) → clear `isRecreatingTaps` → set `recreationEndedAt`. A `defer` is the **synchronous** safety net only (clears `isRecreatingTaps`/sets `recreationEndedAt` on throw) — it must **not** contain awaited finalization. (Snapshot at open, *before* drain; drain *before* restore — matches criterion 2's canonical order.)
  - Route `recreateAllTaps()` (`:1496`) and the permission-fallback (`:1536`) through `requestTapRecreation`; collapse their unawaited `Task` bodies into the single transaction. Remove `serviceRestartTask` (`:73`); `handleServiceRestarted` (`:361`) splits into the `willBegin` (open) handler and the `onServiceRestarted` (recreate) handler.
- Test (`ServiceRestartCoordinatorTests.swift`, via driver seams): (a) nested triggers — `serviceRestartDidCompleteForTests` fired twice + a permission change → `recreationTransactionCountForTests == 1`; (b) **probe-driven downgrade** re-entry (`recreateAllTaps` from inside the probe) coalesces, not nests; (c) a stale/cancelled task cannot flip `suppressesDeviceNotificationsForTests` false while the active transaction runs.

### Task 4: Churn suppression + switch-task quiescence during transaction
**Acceptance criterion:** 2, 5 (W3)
**Files:**
- Modify `FineTune/Audio/AudioEngine.swift`:
  - Top of `handleDeviceDisconnected` (`:1545`) and `handleDeviceConnected` (`:1642`): if a transaction is active, **return early** — no mutation of `appDeviceRouting` (`:1591`), `followsDefault` (`:1592`), `volumeState.setSelectedDeviceUIDs` (`:1575`); spawn no `switchTasks`.
  - Refactor the disconnect-path switch bodies (`:1602–1609` `updateDevices`, `:1615–1629` `switchDevice`) so that: (i) `switchTasks.removeValue(forKey: pid)` runs in a `defer` at the **top** of the task body — it **always** runs, even when cancelled (keeps `activeSwitchTaskCountForTests == 0`); (ii) `guard !Task.isCancelled else { return }` is placed **only before the state mutations** (`tap.volume`/`tap.isMuted`/`tap.currentDeviceVolume` at `:1618–1623`, and the `updateDevices` post-`await` work) — **not** before the cleanup. Route both bodies through the shared wrapper used by `installInFlightSwitchTaskForTests` (P0) so the seam exercises the production path.
- Test (`ServiceRestartCoordinatorTests.swift`): (a) `serviceRestartWillBeginForTests` → `deviceDisconnectedForTests(routedUID)` → assert `appDeviceRouting`, `followsDefault`, in-memory + persisted selected UIDs unchanged and `activeSwitchTaskCountForTests == 0`; (b) via `installInFlightSwitchTaskForTests`, a pre-open in-flight switch task is cancelled, drained, leaves `activeSwitchTaskCountForTests == 0`, and its guarded body does **not** mutate state after restore (hold it suspended, open the transaction, release it, advance, re-assert); (c) **non-restart** hot-unplug path (no active transaction) still reroutes normally; (d) overlap: a real unplug during a *non-restart* recreation is dropped and recovered by reconcile (criterion 6).

### Task 5: H4b — permission-driven mute behavior at tap creation
**Acceptance criterion:** 7 (W6)
**Files:**
- Modify `FineTune/Audio/AudioEngine.swift` — in the array overload `ensureTapExists(for:deviceUIDs:…)` (method at **`:1377`**), change the `ProcessTapController(...)` construction (**`:1389`**) to pass `muteOriginal: permissionConfirmed` (default param `true` at `ProcessTapController.swift:299`).
- **Test seams (required — the existing path is unobservable in tests):** `taps[app.id]` is assigned only *after* `try tap.activate()` succeeds (`:1400→:1401`), and `activate()` calls real CoreAudio (`AudioHardwareCreateProcessTap`, `ProcessTapController.swift:476`), which fails under `swift test` — so the tap is never stored and `muteOriginalForTests(pid:)` returns nil. Therefore add: (a) `func setPermissionConfirmedForTests(_ value: Bool)` (since `permissionConfirmed` is `private`, `:59`); and (b) `var onTapConstructedForTests: ((AudioApp, Bool) -> Void)?` fired **immediately after the constructor at `:1389` and before `activate()`**, carrying `muteOriginal`. `muteOriginalForTests(pid:)` remains for integration cases where a tap is actually stored.
- Test (`AudioEngineCharacterizationTests.swift`, existing file): `setPermissionConfirmedForTests(false)` → trigger a recreation → `onTapConstructedForTests` reports `muteOriginal == false`; with `true` → `== true`. Fail-first (current code always `true`).

### Task 6: Reconcile-on-close + end-to-end restart integrity
**Acceptance criterion:** 1–7 combined, esp. 6 (W7)
**Files:**
- Modify `FineTune/Audio/AudioEngine.swift` — implement the reconcile step inside the **awaited `finalizeTransaction()` phase** (after `restoreTransactionSnapshot`, before clearing suppression — **not** in a `defer`, since multi-mode reconcile awaits `updateDevices(to:)`, `ProcessTapController.swift:561`) per criterion 6's single/multi rules: single-mode absent UID → in-memory fallback (mirror `:1547–1558`, no persist); multi-mode absent UID → remove from set in-memory + persisted (`volumeState.setSelectedDeviceUIDs`, mirror `:1565–1575`) + `await` update tap to remaining (empty set → single fallback).
- Test (`ServiceRestartCoordinatorTests.swift`): full sequence with `serviceRestartDelay = .zero`, pre-state with single + multi-mode apps:
  - **(integrity)** willBegin → disconnect a routed + a multi-set device (both still *present* post-restart) → serviceRestarted → exactly one transaction; all routing/selection/`followsDefault` restored; no surviving switch task mutating after a clock advance.
  - **(reconcile single / criterion 6)** a single-mode app's routed device genuinely **absent** post-restart → after the transaction, routing re-resolved to a present device (in-memory), persisted preference untouched.
  - **(reconcile multi / criterion 6)** a multi-mode app with one selected UID genuinely **absent** post-restart → after the transaction, that UID removed from the selected set **in-memory and persisted**, remaining devices retained; a multi-set that fully empties falls back to single resolution.
  - **(permission flip / M4)** `permissionConfirmed` starts `true`, probe finds no audio (no confirming diagnostics) → final taps `muteOriginalForTests == false`. Drain/advance before asserting final state.

### Task 7: H5 — remove crash-time HAL cleanup; injectable orphan cleanup
**Acceptance criterion:** 8, 9, 10 (W8)
**Files:**
- Delete `FineTune/Audio/CrashGuard.swift`.
- Remove call sites: `FineTune/FineTuneApp.swift:34`; `FineTune/Audio/ProcessTapController.swift:500,808,856,871,1139,1156,1168,1181`; `FineTune/Audio/Tap/TapResources.swift:38,81`. The paired runtime `AudioHardwareDestroyAggregateDevice` calls (`ProcessTapController.swift:857,872,1157,1169,1182`, `TapResources`) **stay**.
- Modify `FineTune/Audio/OrphanedTapCleanup.swift` — make `destroyOrphanedDevices` injectable: parameters (defaulted to production impls) for the device-lister, transport/name readers, and destroyer, so a test supplies fakes.
- **Package.swift:** create `testing/tests/OrphanedTapCleanupTests.swift`, append to `FineTuneIntegrationTests.sources`; confirm `CrashGuard.swift` is not referenced in any `sources:`/`exclude:` list (it currently isn't).
- Test (`OrphanedTapCleanupTests.swift`): injected list with `FineTune-*` aggregates + non-FineTune devices → only `FineTune-*` aggregates passed to the destroyer; others untouched.
- **Source-audit note (criterion 8):** after this task, grep confirms no async-signal handler remains; SIGTERM/SIGINT handlers are `DispatchSource`-based (not signal context).

### Task 8: Docs + CHANGELOG
**Acceptance criterion:** 10
**Files:**
- `CHANGELOG.md` — recreation coordinator + expanded transaction snapshot + reconcile-on-close; H4b permission-driven mute; crash-time HAL cleanup removed (now next-launch `OrphanedTapCleanup`).
- **Update/remove ALL current non-historical CrashGuard architecture references** (not one line). Run `grep -rni 'crashguard\|async-signal\|trackDevice\|untrackDevice\|crash-safe' docs/architecture/ | grep -v older/` and fix every hit. Known sites: `docs/architecture/finetune-architecture.md:10,127,179–180,246,305–308,431` (esp. correct the false "Uses only async-signal-safe operations" at `:307`) and `docs/architecture/audio-path.txt:220,232,241,288,668,680`. Describe the new model: no crash signal handler; next-launch `OrphanedTapCleanup` is the cleanup path; SIGTERM/SIGINT graceful shutdown retained.
- `docs/known_issues/bug-sweep-remaining-risks-2026-06-16.md` — move H4 (`:18`) and H5 (`:19`) to resolved (reference this plan); **add a new resolved entry for H4b** (not currently listed).
- Leave `docs/ai-chat-history/*` and `docs/architecture/older/*` (historical) untouched.

---

## Execution Notes

**Parallel groups:**
- Task 1 (snapshot model) ∥ Task 2 (monitor hook) — independent.
- Task 7 (H5) is fully independent of H4 → ∥ Tasks 1–6.
- Sequential: Task 3 → 4 → 6 (coordinator → churn-suppression+quiescence → reconcile/integration). Task 5 (H4b) depends only on `ensureTapExists` → ∥ 3/4, must land before Task 6.
- Task 8 (docs) last.

**Risk areas (highest first):**
1. **Switch-task quiescence (Tasks 3+4, M1):** cancel alone does not stop a suspended `await tap.switchDevice` (cooperative cancellation; bodies at `:1602/:1615` mutate post-`await`). Canonical order: snapshot at `willBegin`, then the coordinator **drains (awaits) cancelled tasks before restore** (not before snapshot); the shared `runSwitchTask` wrapper always cleans up via `defer` and runs its `commit` only when `!Task.isCancelled`. Both the drain and the guarded-commit wrapper, or criterion 2 fails.
2. **Coalescing + `defer`-once (Task 3):** single owning `Task`; pending reasons merge, never spawn nested `Task`. The probe-driven downgrade (`:401–412`) re-enters from *within* the transaction — must coalesce. Verify via `recreationTransactionCountForTests`.
3. **Reconcile vs. drop-not-replay (Task 6, M2):** dropping a genuine restart-time disconnect would strand routing on a gone device; the reconcile-on-close (against the *current* device list, not the dropped events) is what makes drop-not-replay safe. Test the device-genuinely-gone case explicitly.
4. **`willBegin` ordering (Task 2):** if `handleServiceRestartedAsync` is ever refactored to read devices before emitting `willBegin`, criterion 4 silently breaks — the ordering test guards it.
5. **Test wiring under XCTest (B2):** `init` skips callback wiring at `:223`; all engine-level tests drive internal `*ForTests` entry points, not monitor closures. Monitor ordering is tested via the HAL-free `emitRestartEvents` seam.
6. **`trackDevice`/`untrackDevice` removal (Task 7):** many ProcessTapController sites — each removal must leave the paired real destroy call intact.
