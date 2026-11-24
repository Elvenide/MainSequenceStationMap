# AGENTS.md — Elvenide's Station Map for *Main Sequence*

## Project Overview

**Elvenide's Station Map** is a standalone, client-side UE4SS Lua mod for the Unreal Engine game *Main Sequence*.
It is an interactive fullscreen 2D station map for **Main Sequence** with floor switching, live machine/player tracking, copy-paste, delete, and ghost build planning, while keeping gameplay faithful to vanilla *Main Sequence*.

### Repository Structure
- `Scripts/main.lua` — Mod entrypoint; registers feature modules and lifecycle hooks.
- `Scripts/core.lua` — Shared UE4SS utilities, config persistence, keybind registry, `Core.VERSION`, and safe reflection helpers.
- `Scripts/station_data.lua` — Shared station, floor, machine, wall collider, and port data extraction & caching layer.
- `Scripts/features/*.lua` — Feature implementation module(s).
- `docs/get-started.md` — Installation and getting-started guide.

---

## Mandatory Policies

1. **100% Save-Safe / Zero Save Dependency**:
   - This mod MUST NEVER make a player's save file dependent on the mod.
   - Do **not** add custom blocks, custom items, custom recipes, custom serialized UObject classes, or persistent world/save-game mutations that cannot be cleanly undone simply by removing the mod folder.
   - Removing `MainSequenceStationMap` at any time must leave the save file 100% playable in vanilla *Main Sequence*.
2. **Never Modify or Commit `config.json`**:
   - `config.json` stores the user's local runtime settings and keybinds. It is gitignored and must never be modified or staged by agents.
3. **Auto-Increment Patch Version on Every Commit**:
   - On every commit, automatically increment the patch version in `Core.VERSION` inside `Scripts/core.lua` (e.g., `0.1.0` -> `0.1.1` -> `0.1.2`) and include `Scripts/core.lua` in the commit.
4. **Conventional Commits Required**:
   - Every commit MUST follow [Conventional Commits](https://www.conventionalcommits.org/) syntax: `<type>(<optional scope>): <description>` (e.g., `feat: add initial release`, `fix: handle nil controller on map load`, `docs: update installation guide`).
   - Allowed types: `feat`, `fix`, `perf`, `refactor`, `docs`, `style`, `chore`, `ci`. Use `!` after the type/scope or a `BREAKING CHANGE:` footer for breaking changes. Automated GitHub Release changelogs are generated directly from these commits via `git-cliff`.

---

## Development & Verification Best Practices

- **Prefer Native Game Commands (`UInputCommand` / `DMSPlayerController`)**:
  - When mutating simulation state, always prefer the game's native `DMSPlayerController` command pathways so changes remain deterministic and multiplayer-safe.
- **Keep UI & Rendering Incremental**:
  - Never synchronously construct hundreds of UMG widgets on a single frame or run heavy `FindAllOf` scans on hot paths; use cached UMG classes, targeted `NotifyOnNewObject` watchers, and time-budgeted frame streaming (`ExecuteInGameThreadAfterFrames`).
  - Never perform heavy work or call `ExecuteInGameThread` synchronously inside `WBP_Button_C` click hooks; defer with `ExecuteInGameThreadWithDelay(10, ...)`.
- **Defensive Lua & UE4SS Validation**:
  - Always guard UE4SS object/property accesses with `Core.IsValidObj(...)` and `pcall(...)`.
  - After every edit to any `.lua` file, run a Lua syntax and block-balance validator before committing.
- **Clean Commits**:
  - Stage only the files relevant to the task and verify `git status --short` before committing.