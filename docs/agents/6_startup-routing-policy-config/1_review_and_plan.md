# Startup Routing Policy: Review and Plan

**Date:** 2026-02-14
**Agent:** Codex
**Scope:** Resolve startup routing behavior conflict by making policy configurable in main settings.

## Problem Identified

`AudioEngine.applyPersistedSettings()` always replaced persisted explicit per-app routing with the current system default at startup.

Impact:
- Explicit user routing intent was lost on launch.
- Behavior was surprising when users expected app-specific device choices to persist.

## User Decisions Captured

1. Make startup routing configurable.
2. Put control in main settings.
3. Use recommended default behavior.

Selected default:
- `preserveExplicitRouting`

## Implementation Plan

1. Add an app-wide startup policy enum in settings.
2. Persist and decode the policy with backward-compatible defaults.
3. Refactor startup routing resolution in `AudioEngine` to branch by policy.
4. Add Settings UI row in main settings (Audio section).
5. Add fail-first tests and verify behavior.
