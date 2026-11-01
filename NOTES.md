# NOTES.md v1.0.0.1 — rblx game (living project log)

Update this file at the end of every task. Read this FIRST instead of rescanning the codebase.

## Source of truth
- Repo: https://github.com/zoldsold/proj1/tree/main
- Access status (2026-11-01): Claude cannot read GitHub directly (fetch blocked by robots.txt, sandbox network off, repo not found via search; may be private).
  Workaround: upload changed files (.rbxm / .luau / zip) or paste diffs. Keep this file committed in the repo root.

## Project layout (Rojo, from decompiled .rbxm files, 2026-11-01)
`default.project.json` maps `src/ReplicatedStorage`, `src/ServerScriptService`, `src/StarterPlayerScripts`.

| Area | Contents |
|---|---|
| ReplicatedStorage | CombatRemote, DashEvent (RemoteEvents); PetModelBuilder, PetConfig, MagicCircleConfig; PetTamingModules/ (Animations, Helpers, Main, Stats, Cinematic, Config, Util, UI, Circles); PetClientModules/ (Swim, Attack, Helpers, VFX, Cinema, Follow, Motion, PetMotionConfig) |
| ServerScriptService | CombatService (init.server + Animations M1–M4, Block); Data/ (DataService, ProfileSchema, ProfileSchema.spec); DataBootstrap, DevGrant, DashServer, MagicCircleService, PetBootstrap, PetManager, PetTaming_Service |
| StarterPlayerScripts | Camera (disabled), CombatController, DashModeUI, MagicCircleController, PetClient, PetInventoryUI, StatsHUD |

## Conventions
- Version label per file: `v1.0.0.1`, incremented on every edit (four segments).
- Config-driven: new pets/effects added via config, no edits to existing logic.
- Server-authoritative, built for several million players; sequential, concise code.
- Every code output goes through the Quality Gate (Approval Gate → Analysis → Draft → Critique).

## Open issues
### Pet taming
- Camera angles don't fully show the magic circle rising.
- Nickname not reflected in the storage system.
- Swim animation not functioning.
- Taming distance: fixed pet-to-player 5 studs (or better).
- Particles/effects need to be more cinematic; all magic-circle effects (thunder, cloud…) belong in PetTamingConfig; remove the line effect inside circles.
### Pet movement
- Click-follow: travel tween speed depends on pet speed.
- Drag-follow: pet tracks the dragged cursor in real time, no lag in combat, speed-dependent.
- Travel height by pet type (Flying / Ground); extend later.
### Findings
- `DashServer` is a LocalScript inside ServerScriptService (LocalScripts don't run there); likely should be `DashServer.server.luau`. Awaiting approval.
- Version labels inconsistent (some 5-segment like v1.0.0.0.1, six files have no version line). Normalization pending approval.
- Combat Animation `AnimationId` values exported empty; verify in Studio.
- `Camera` LocalScript is Disabled.

## Change log
- 2026-11-01: Decompiled ReplicatedStorage, ServerScriptService, StarterPlayerScripts rbxm into Rojo project (47 files); source round-trip verified. `ReplicatedStorage_1.rbxm` was identical to the first export. Tools: rbxm_parse.py v1.0.0.1, rbxm_export.py v1.0.0.2.

## Next steps (awaiting user)
1. Confirm DashServer rename.
2. Confirm version-label normalization.
3. Pick the next issue to tackle (suggested order: taming distance → nickname storage → swim → movement → VFX).
