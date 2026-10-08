-- Original source names are preserved so imported models remain traceable.
return {
    Fish = {
        white_koi = "Koi", sand_goby = "RedSnapper", mint_molly = "Tetra",
        reed_carp = "Koi", sunny_dace = "Goldfish", pearl_sardine = "Tuna",
        jade_tetra = "Tetra", coral_butterfly = "ButterflyFish", seafoam_dory = "BlueTang",
        moss_catfish = "ArmoredCatfish", lime_angelfish = "MoorishIdol", kelp_rabbitfish = "Tang",
        stripe_clownfish = "Clownfish", cobalt_parrotfish = "ParrotFish",
        violet_lionfish = "Lionfish", amethyst_tuna = "Tuna", deep_crownfish = "FlowerHorn",
        golden_arowana = "Goldfish", amber_swordfish = "Swordfish", sun_crowned_koi = "Koi",
        royal_marlin = "Swordfish", crimson_dragonfish = "Betta", scarlet_leviathan = "GoblinShark",
        rainbow_kirin = "MandarinFish", dream_coral_dragon = "Lionfish", celestial_koi = "Koi",
        eternal_phoenixfish = "Betta", rose_hammerhead = "SharkPuppy",
        azure_seahorse = "Seahorse", crystal_ray = "EagleRay",
        moon_jellyfish = "Jellyfish", glacier_eel = "Eel",
        orchid_octopus = "Octopus", star_manta = "MantaRay",
        twilight_squid = "Squid", treasure_turtle = "Turtle",
        aurora_whale = "Whale", ember_lobster = "Lobster",
        blood_moon_ray = "MantaRay", volcanic_serpent = "SeaSerpent",
        prism_narwhal = "Narwhal", nebula_jelly = "Jellyfish",

        -- Themed derivatives retain their source mesh/texture while adding
        -- inert, authored geometry for their zone.  These keys are generated
        -- by tools/generate_theme_fish_assets.py and must stay stable.
        mystic_lake_lotus_carp = "MysticLake_LotusCarp",
        mystic_lake_lantern_goby = "MysticLake_LanternGoby",
        mystic_lake_moonfin = "MysticLake_Moonfin",
        mystic_lake_spirit_koi = "MysticLake_SpiritKoi",
        mystic_lake_oracle_eel = "MysticLake_OracleEel",
        mystic_lake_moon_whale = "MysticLake_MoonWhale",
        mystic_lake_aurora_dragon = "MysticLake_AuroraDragon",
        lava_fishing_cinder_guppy = "LavaFishing_CinderGuppy",
        lava_fishing_ash_puffer = "LavaFishing_AshPuffer",
        lava_fishing_magma_tetra = "LavaFishing_MagmaTetra",
        lava_fishing_basalt_lionfish = "LavaFishing_BasaltLionfish",
        lava_fishing_ember_swordfish = "LavaFishing_EmberSwordfish",
        lava_fishing_volcano_ray = "LavaFishing_VolcanoRay",
        lava_fishing_inferno_serpent = "LavaFishing_InfernoSerpent",
        alien_waters_ring_minno = "AlienWaters_RingMinno",
        alien_waters_neon_molly = "AlienWaters_NeonMolly",
        alien_waters_comet_tetra = "AlienWaters_CometTetra",
        alien_waters_void_octopus = "AlienWaters_VoidOctopus",
        alien_waters_prism_narwhal = "AlienWaters_PrismNarwhal",
        alien_waters_quasar_manta = "AlienWaters_QuasarManta",
        alien_waters_galaxy_whale = "AlienWaters_GalaxyWhale",
        chemistry_lab_buffer_betta = "ChemistryLab_BufferBetta",
        chemistry_lab_catalyst_carp = "ChemistryLab_CatalystCarp",
        chemistry_lab_phosphor_eel = "ChemistryLab_PhosphorEel",
        chemistry_lab_crystal_jelly = "ChemistryLab_CrystalJelly",
        chemistry_lab_mercury_tuna = "ChemistryLab_MercuryTuna",
        chemistry_lab_reactor_ray = "ChemistryLab_ReactorRay",
        chemistry_lab_quanta_dragon = "ChemistryLab_QuantaDragon",
    },
    -- Every gameplay species now resolves to an imported template.  The
    -- 15 unmapped regular templates remain library-only and do not change
    -- species, economy, or progression data.
    -- The three prop names are the exact Studio template names.
    Props = {
        Palm = "Palm", Dock = "Dock", Boat = "Boat", FishingBucket = "FishingBucket",
        FishingRod = "FishingRod", LureDisplayBoard = "LureDisplayBoard", RodRack = "RodRack",
    },
    -- Quaternius Ultimate Stylized Nature is kept as a separate authored
    -- library. These names match ReplicatedStorage.NatureArt children and do
    -- not redirect existing gameplay props or navigation geometry.
    NatureArt = {
        PlantFlowers = "PlantFlowers",
        Bush = "Bush",
        FlowerClump = "FlowerClump",
        GrassSmall = "GrassSmall",
    },
}
