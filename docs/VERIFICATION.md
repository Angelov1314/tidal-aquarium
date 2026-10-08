# Verification boundary

## Reproducible local checks

The public source keeps the pure Luau test files and the default source tree. Run:

```sh
make test
make build
```

`make test` compiles default `src/**/*.luau` files and runs the pure model, progression, economy, UI-state, content, mutation, and focused fish/shore specs listed in `Makefile`. It does not start Roblox Studio. `make build` assembles a Rojo place file and does not establish runtime or visual acceptance.

## Historical evidence carried forward

The source workspace had historical evidence for server flows, imported templates, and earlier pure Luau checks. Those records were not copied wholesale because they contain machine paths, screenshots, logs, generated build archives, and stale intermediate counts. They remain evidence about earlier revisions only; they do not certify the current public snapshot.

## Open Roblox checks

A user opening the project still needs to verify, in the current Roblox Studio build:

- Mesh and texture preloading for the 70 mapped species and the seven props.
- The four nature templates and HarborFisher in the current scene, including scale, grounding, animation, and visual quality.
- Touch/mobile layout, multiplayer capacity, low-end performance, and long-running economy behavior.
- Real DataStore isolation/lease behavior in an explicitly configured test Universe and Place.
- Any audio after replacing the intentionally blank public IDs.

Robux products remain disabled and no real cloud or payment acceptance is claimed.
