# Public snapshot manifest

Prepared: 2026-10-08
Project: Tidal Aquarium / 潮汐水族馆
Snapshot scope: source, tests, Rojo project files, current mapped Roblox templates, provenance, and offline helpers.

Included snapshot metrics (excluding ignored `build/` output): 139 regular files, 4,482,004 bytes.
Largest included file: `assets/roblox/FishingArt.rbxmx` (2,484,815 bytes).

Validation completed in this snapshot:

- `make test` with `luau` and `luau-compile` supplied through `PATH`: PASS; 43 source files compiled and all Makefile pure Luau specs passed. Absolute `LUAU`/`LUAU_COMPILE` overrides are also supported.
- `make build` with the same PATH setup: PASS; the five Rojo projects (`default`, `qa`, `fishartqa`, `fishshoreqa`, `npcqa`) also built successfully.
- Static project path check: 5 project files, 0 missing `$path` targets.
- Static hygiene: 0 symlinks, 0 zero-byte files, no credential-like filenames, and no local machine paths or credential values in scanned text.

Runtime and release boundary:

- Roblox Studio, resource preloading, device/mobile, multiplayer, cloud DataStore, and payment checks were not run for this snapshot.
- Public audio IDs are blank; no ElevenLabs/Gemini files are included.
- Third-party source and license boundaries are in `docs/ASSET_PROVENANCE.md`, `docs/licenses/`, and `src/shared/ArtCredits.luau`.
- Keychain/Open Cloud uploaders, account helpers, cloud QA fixtures, raw source archives, logs, screenshots, and generated builds are excluded.
