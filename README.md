# Tidal Aquarium Demo / 潮汐水族馆

This repository is a public source snapshot of a non-commercial Roblox fishing and aquarium prototype. It is a playable demo project, not a production release or a promise that a Roblox experience is currently published. Robux products remain disabled.

The current source contract loads 9 zones, 70 species, and 7 rarities. The public snapshot keeps the authored Luau source, pure Luau tests, Rojo project files, the current Roblox template exports, and the provenance records needed to understand those assets.

## Open the demo

Install Roblox Studio and Rojo, then build the default place:

```sh
make build
# open build/TidalAquarium.rbxlx in Roblox Studio and click Play
```

The default project maps `assets/roblox/FishingArt.rbxmx`, four Quaternius nature templates, and `assets/roblox/NPCTemplates.rbxmx`. World geometry is assembled by the server at runtime. The editor view being mostly empty before Play is expected.

The normal loop starts with starter fish and coins: merge three matching fish, place fish in the aquarium, fish at the dock, upgrade hooks and capacity, and unlock later zones. The current source includes server-authoritative requests, session saves by default in Studio, a DataStore path guarded behind explicit configuration, and disabled payment interfaces.

## Checks

```sh
# Set LUAU and LUAU_COMPILE when they are not on PATH.
make test
make build
make fishshore-build
```

`make test` runs the retained pure Luau suite and compiles default sources to `build/bytecode/`. `make build` only proves that Rojo can assemble the place file. Studio play, resource preloading, mobile layout, multiplayer capacity, real cloud DataStore behavior, and long-running economy behavior require separate Roblox validation. No fresh Studio run is claimed by this snapshot.

The old QA projects are retained as source-level diagnostic fixtures: `qa.project.json`, `fishartqa.project.json`, `fishshoreqa.project.json`, and `npcqa.project.json`. The public `qa.project.json` omits the audio smoke scripts because this snapshot deliberately ships silent audio IDs. These projects are not production places and must not be published as-is.

## Assets and omissions

The included Roblox XML/RBXM files are the assets actually mapped by the default project. Their current MeshId/TextureID references are external Roblox assets, so availability still depends on Roblox Creator permissions and asset moderation. The source and license boundaries are documented in [`docs/ASSET_PROVENANCE.md`](docs/ASSET_PROVENANCE.md), [`src/shared/ArtCredits.luau`](src/shared/ArtCredits.luau), and [`docs/licenses`](docs/licenses).

Raw downloaded source packs, conversion caches, screenshots, build archives, local logs, and the mounted Unity package library are omitted. They were either not needed by the Rojo project, were only candidate material, or had rights/redistribution status that was not established for this snapshot. The source links in `docs/ASSET_PROVENANCE.md` describe how to obtain any raw source that is needed for a future import.

Audio files are deliberately omitted. The workspace audio includes ElevenLabs Free-plan output limited to non-commercial demo use and Gemini output whose account terms were still pending review. Public `AudioConfig` entries are silent, so supply audio that you are authorized to use before enabling sound.

Keychain readers, Open Cloud uploaders, account-specific import helpers, cloud-storage QA fixtures, private paths, and personal configuration are not part of this repository.

## License boundary

There is no blanket open-source license for this project; see [`LICENSE.md`](LICENSE.md). Third-party assets keep their own terms. CC BY assets require attribution, which is retained in `ArtCredits.luau` and the provenance document.
