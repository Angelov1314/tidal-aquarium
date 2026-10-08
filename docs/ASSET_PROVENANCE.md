# Asset provenance and release boundary

This document describes the assets that are actually mapped by the public Rojo projects. It does not turn the snapshot into a self-contained Roblox experience: MeshId/TextureID and any Roblox sound assets remain external Creator-platform resources.

## Included runtime templates

| Snapshot path | Runtime use | Source and status | License record |
| --- | --- | --- | --- |
| `assets/roblox/FishingArt.rbxmx` | 70 fish mappings and 7 prop mappings through `ArtCatalog` | Current imported library; the XML contains 81 direct roots and 82 recursive MeshParts according to the source audit | Mixed sources listed below; current XML is a derived Roblox template export |
| `assets/roblox/NatureArt/*.rbxm` | Four plant templates cloned by `IslandBuilder` | Current default and QA project mappings | Quaternius Ultimate Stylized Nature, CC0 1.0 |
| `assets/roblox/NPCTemplates.rbxmx` | `ServerStorage.NPCTemplates/HarborFisher` | Current selected NPC template; fresh runtime evidence is historical and does not complete product acceptance | Quaternius Universal Base Characters, Modular Character Outfits - Fantasy, and Universal Animation Library, CC0 1.0 |

The four nature templates and the HarborFisher template are retained because the default project maps and uses them. `FishingArt.before-tackle-import.rbxmx` and older build backups are excluded because they are superseded copies.

## Sources represented in FishingArt

- Quaternius Cute Fish and Animated Fish provide the regular and gap fish meshes. The local CC0 evidence is preserved in `docs/licenses/Quaternius-Cute-Fish-CC0.txt` and `docs/licenses/Quaternius-Animated-Fish-CC0.txt`.
- Poly by Google and Steren Giannini sources provide the CC BY 3.0 gap models. Their model links and attribution names are retained in `src/shared/ArtCredits.luau` and `ArtCredits` is the source for the in-game credit data. Raw Poly files are not copied into this public snapshot.
- The Meshy Shark Puppy page is recorded as CC0 in the source record. The current library contains the uploaded/derived Roblox template, while the raw Meshy source is omitted.
- 3DAssets.dev Harbor and Tackle provides the imported fishing rod, lure board, and rod rack under CC0 1.0. Kenney Survival Kit provides the imported bucket under CC0 1.0. The local declarations are preserved in `docs/licenses/3DAssets-Harbor-and-Tackle-CC0.txt` and `docs/licenses/Kenney-Survival-Kit-CC0.txt`.
- Theme fish are local derivatives that reuse the existing imported MeshPart/TextureID and add small inert decorative Parts; they do not introduce another external source.

The original source packs are intentionally not redistributed with this snapshot. Use the source URLs and license evidence in the project history and credit module when making a new import.

## Omitted material

- `assets/audio/` is omitted. The available ElevenLabs files were generated under a Free plan with non-commercial demo limits, and the Gemini music terms were pending review. `src/shared/AudioConfig.luau` therefore contains silent IDs in this public snapshot.
- The mounted Unity asset library was inspected only as a candidate source. Its commercial Unity packages were not mapped by this Roblox project and were not copied.
- Conversion caches, raw FBX/GLB/Blend archives, generated previews, logs, and build archives are omitted.
- Keychain/Open Cloud upload tools and private/account-specific data are omitted.

## Attribution and reuse

Use the CC0 and CC BY terms in `docs/licenses` and `src/shared/ArtCredits.luau` for the applicable third-party pieces. The project has no blanket license; see `LICENSE.md`. Public visibility of this repository does not grant access to Roblox Creator assets or permission to reuse project-authored source.
