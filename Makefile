.PHONY: build fishshore-build open serve test compile-check toolchain-check

LUAU ?= luau
LUAU_COMPILE ?= luau-compile
BYTECODE_DIR ?= build/bytecode
DEFAULT_SOURCES := $(shell find src -type f -name '*.luau' -print | sort)

# Fish/shore correction QA is deliberately a separate Rojo place.  It keeps
# the playable default and the existing QA/mobile places unchanged while
# allowing one bounded Studio run to exercise the new waterfront and fish
# presentation checks without UIRepairSmoke sharing the same PlayerGui.
FISH_SHORE_PROJECT ?= fishshoreqa.project.json
FISH_SHORE_BUILD ?= build/FishShoreQA.rbxlx
# The shore contract is the focused pure-Luau suite; presentation coverage is
# a Studio client smoke mapped in fishshoreqa.project.json below.
FISH_SHORE_SPECS := tests/FishingLocation.spec.luau

toolchain-check:
	@luau="$(LUAU)"; \
	if [ ! -x "$$luau" ]; then luau="$$(command -v "$$luau" 2>/dev/null || true)"; fi; \
	if [ -z "$$luau" ] || [ ! -x "$$luau" ]; then echo "Luau executable is unavailable: $(LUAU)" >&2; echo "Set LUAU=/path/to/luau or put luau on PATH." >&2; exit 1; fi; \
	compiler="$(LUAU_COMPILE)"; \
	if [ ! -x "$$compiler" ]; then compiler="$$(command -v "$$compiler" 2>/dev/null || true)"; fi; \
	if [ -z "$$compiler" ] || [ ! -x "$$compiler" ]; then echo "Luau compiler is unavailable: $(LUAU_COMPILE)" >&2; echo "Set LUAU_COMPILE=/path/to/luau-compile or put luau-compile on PATH." >&2; exit 1; fi; \
	"$$luau" --help >/dev/null; \
	"$$compiler" --help >/dev/null; \
	echo "Using Luau: $$luau"; \
	echo "Using Luau compiler: $$compiler"

# Emit real Luau bytecode for every default place source.  This intentionally
# does not use --only-parse: register allocation and code generation failures
# must fail the same CI path as the focused tests.  Override LUAU or
# BYTECODE_DIR for a different recovery compiler/output directory.
compile-check: toolchain-check
	@test -n "$(DEFAULT_SOURCES)" || (echo "No default Luau sources found" >&2; exit 1)
	@set -eu; \
		count=0; \
		for source in $(DEFAULT_SOURCES); do \
			output="$(BYTECODE_DIR)/$${source#src/}.bytecode"; \
			mkdir -p "$$(dirname "$$output")"; \
			"$(LUAU_COMPILE)" --binary "$$source" > "$$output"; \
			count=$$((count + 1)); \
		done; \
		echo "Compiled $$count default Luau sources to $(BYTECODE_DIR)"

build:
	mkdir -p build
	rojo build default.project.json -o build/TidalAquarium.rbxlx

fishshore-build:
	mkdir -p build
	rojo build "$(FISH_SHORE_PROJECT)" -o "$(FISH_SHORE_BUILD)"
open: build
	open -a /Applications/RobloxStudio.app build/TidalAquarium.rbxlx
serve:
	rojo serve default.project.json --address 127.0.0.1 --port 34873
test: compile-check
	"$(LUAU)" tests/Model.spec.luau
	"$(LUAU)" tests/IncomePreview.spec.luau
	"$(LUAU)" tests/IncomePreviewRequest.spec.luau
	"$(LUAU)" tests/IncomePreviewController.spec.luau
	"$(LUAU)" tests/IncomePreviewGate.spec.luau
	"$(LUAU)" tests/IncomePreviewQuery.spec.luau
	"$(LUAU)" tests/ConsumptionProtection.spec.luau
	"$(LUAU)" tests/ModelEdges.spec.luau
	"$(LUAU)" tests/SnapshotPerformance.spec.luau
	"$(LUAU)" tests/BulkSell.spec.luau
	"$(LUAU)" tests/AudioConfig.spec.luau
	"$(LUAU)" tests/CatchFeedback.spec.luau
	"$(LUAU)" tests/UiRepair.spec.luau
	"$(LUAU)" tests/CapacityCycle.spec.luau
	"$(LUAU)" tests/Progression.spec.luau
	"$(LUAU)" tests/ThemeContent.spec.luau
	"$(LUAU)" tests/FishArtCoverage.spec.luau
	"$(LUAU)" tests/WorldLayout.spec.luau
	"$(LUAU)" tests/EnvironmentConfig.spec.luau
	"$(LUAU)" tests/SailingRules.spec.luau
	"$(LUAU)" tests/SailingHudState.spec.luau
	"$(LUAU)" tests/NPCConfig.spec.luau
	"$(LUAU)" tests/ResponsiveLayout.spec.luau
	"$(LUAU)" tests/StorageConcurrency.spec.luau
	"$(LUAU)" tests/RequestValidation.spec.luau
	"$(LUAU)" tests/MutationIntent.spec.luau
	"$(LUAU)" tests/MutationProtocol.spec.luau
	"$(LUAU)" tests/HandshakeFence.spec.luau
	"$(LUAU)" tests/MutationLaneState.spec.luau
	@for spec in $(FISH_SHORE_SPECS); do \
		echo "Running focused fish/shore spec: $$spec"; \
		"$(LUAU)" "$$spec" || exit $$?; \
	done
