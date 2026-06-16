# Critique Log — Tap-Recreation Coordinator + CrashGuard plan

## Cycle 1 — adversarial review (Opus subagent) + orchestrator self-verification

Reviewer verified ~all `file:line` refs correct (only `ensureTapExists` drifted ~11 lines). Findings and resolutions:

| ID | Sev | Finding | Verified by orchestrator | Resolution |
|----|-----|---------|--------------------------|------------|
| B1 | Blocker | New test files not added to `Package.swift` explicit `sources:` → won't compile | Yes (explicit lists, not globs) | Added P1 + explicit Package.swift edits in Tasks 2 & 7 |
| B2 | Blocker | `init` early-returns under XCTest (`:223`) before callback wiring `Task` (`:225`) → monitor-fired tests unwritable | **Yes — read `:204–288`** | Added P0 driver entry-point seams; tests drive engine internals directly; monitor ordering via HAL-free `emitRestartEvents` seam; corrected the "real wired callbacks" claim |
| B3 | Blocker | `taps` private + existing hook fires pre-construction & carries no flag → criterion-6 unobservable | Yes | Added `muteOriginalForTests(pid:)` seam (P0/Task 5) |
| M1 | Major | Cancelling `switchTasks` doesn't stop suspended `await`; disconnect-path bodies mutate post-`await` w/o `isCancelled` | **Yes — read `:1600–1638`** | Coordinator drains (awaits) cancelled tasks before snapshot; `guard !Task.isCancelled` added before post-`await` mutations (Task 4); criterion 2 reworded |
| M2 | Major | Dropping a genuine restart-time disconnect strands routing on a gone device; recovery unspecified | Yes | Added **reconcile-on-close** (criterion 6, Task 6) — reconcile against current device list, not replay; honors drop-not-replay |
| M3 | Major | `ensureTapExists` line cites off ~11 lines | Yes (method `:1377`, ctor `:1389`) | Corrected in Task 5 |
| M4 | Major | `permissionConfirmed` flips mid-transaction; static test misses it | Yes (`:401–412`) | Task 6 drives permission-loss-during-restart probe flip |
| M5 | Major | Criterion 7 "handler makes zero unsafe calls" degenerate after deletion | Yes | Criterion 8 reworded: no crash handler exists; SIGTERM/SIGINT not signal context |
| m1 | Minor | Untested overlap: real unplug during non-restart recreation | — | Added to Task 4(c) |
| m2 | Minor | `followsDefault` has no persisted counterpart (`isFollowingDefault` derived `:190`) | Yes | Clarified in seam check (in-memory only) |
| m3 | Minor | SettingsManager backing props `:148/:149`; `[String:[String]]` vs `Set` | Yes | Clarified Task 1 + seam check; assert as Set |
| m4 | Minor | False claim is arch-doc `:307`; H4b not in bug-sweep doc | Yes | Task 8 specifics corrected |
| m5 | Minor | Suppression binding / `serviceRestartTask` removal unspecified | Yes | Added "Suppression binding" subsection |
| m6 | Minor | Probe-driven re-entry coalescing untested | Yes | Task 3(b) |

**Reviewer verdict:** directionally sound, well-grounded; not implementable as written without B1–B3 + M1–M2. All adopted. No design choice judged wrong (A/A + refinements stand).

**Outcome:** plan revised. Sent to user for sign-off.

## Cycle 2 — user (Alex) precision review

Design choice unchanged (still A/A); five precision gaps that would make `/implement` fail TDD or implement wrong lifecycle semantics. All adopted.

| ID | Sev | Finding | Verified | Resolution |
|----|-----|---------|----------|------------|
| C2-1 | Blocker | Coalescing contradictory: defer "process coalesced pending reason" vs `count == 1` | — (spec) | Criteria 1/3 + sequence + Task 3: coalesced reasons are **metadata consumed within the current transaction**; `defer` never opens a follow-up for the same burst; new transaction only after active flag clears |
| C2-2 | Blocker | M1 drain/snapshot order self-contradictory; `isCancelled` before `removeValue` leaks `switchTasks` | Yes (`:1602/:1615`) | Stated canonical order once (snapshot@willBegin → drain-before-restore); cleanup **always** via `defer`, `isCancelled` guard only around state mutations |
| C2-3 | Major | "fake in-flight switch" test not implementable (`taps`/`switchTasks` private `:23/:31`; switch needs real tap `:1594`) | Yes | Added `installInFlightSwitchTaskForTests` seam wrapping the shared production switch structure |
| C2-4 | Major | Reconcile-on-close ignored multi-device selection (disconnect persists UID removal `:1565/:1575`) | Yes | Criterion 6 + Task 6 split into single (in-memory) vs multi (in-memory + persisted) rules + tests |
| C2-5 | Major | Docs task under-scoped (CrashGuard refs across `audio-path.txt:220,232,241,288,668,680` + many in `finetune-architecture.md`) | **Yes (grep)** | Task 8 now grep-driven over all non-historical CrashGuard refs |

**Outcome:** plan revised (cycle 2). Sent to user.

## Cycle 3 — user (Alex) implementability review

Design unchanged. Three implementability gaps + one stale contradiction. All adopted; verified against code.

| ID | Sev | Finding | Verified | Resolution |
|----|-----|---------|----------|------------|
| C3-1 | Blocker | Task 5 untestable: `permissionConfirmed` private (`:59`); tap stored only after `activate()` (`:1401`) which calls real CoreAudio (`:476`) → nil in tests | **Yes (read `:1386–1401`)** | Added `setPermissionConfirmedForTests(_:)` + `onTapConstructedForTests((AudioApp,Bool))` fired at constructor before activate |
| C3-2 | Blocker | Async reconcile placed in `defer`; `updateDevices(to:)` is `async` (`:561`) — `defer` can't `await` | **Yes (read `:561`)** | Reworked to an awaited `finalizeTransaction()` phase (restore→reconcile) before clearing suppression; `defer` = synchronous safety net only. Updated criterion-2 order, sequence, Tasks 3 & 6, suppression-binding, Approach |
| C3-3 | Major | `installInFlightSwitchTaskForTests` couldn't prove the guard (arbitrary body mutates after its own await) | — (spec) | Shared `runSwitchTask(pid:operation:commit:)` wrapper separates awaited `operation` from guarded `commit`; seam + production bodies share it; test proves `commit` didn't run |
| C3-4 | Major | Stale contradiction: Risk Area 1 still said "drain before snapshot" | Yes | Corrected to "drain before restore (snapshot at willBegin)"; also fixed two residual "cleared in defer" mentions (Approach, suppression-binding) |

**Outcome:** plan revised (cycle 3); consistency sweep clean (no "drain before snapshot", no awaited finalization in `defer`, all required headings present). Awaiting user sign-off (Gate 5).

## Cycle 3.5 — Gate 5 sign-off + one precision nit

Reviewer (second session) signed Gate 5: no remaining blocker/major; Cycle-3 fixes line up with source constraints (snapshot/cancel at `willBegin`, awaited drain/finalize before suppression clears, no awaited work in `defer`, constructor-time `muteOriginal` observability before CoreAudio activation, shared switch wrapper proves the production cancellation guard).

| ID | Sev | Finding | Resolution |
|----|-----|---------|------------|
| C3.5-1 | Nit (optional) | Plan `:58` spelled `runSwitchTask(pid:operation:commit:)` with prose `let result = try await operation()` (throwing, result-returning) but described the test seam's `operation` as `() async -> Void` — signature inconsistent/implementer-inferable | Spelled the wrapper as generic + throwing: `runSwitchTask<T>(pid:operation:commit:)`, `operation: () async throws -> T`, `commit: (T) -> Void`; noted disconnect bodies instantiate `T` per call-site return type, and the test seam drives it with `T == Void` (adapting the no-arg test `commit` as `{ _ in commit() }`; non-throwing test `operation` accepted where `() async throws -> Void` expected) |

**Outcome:** Gate 5 signed. Plan ready for `/implement` (or autonomous Codex handoff). No source touched.
