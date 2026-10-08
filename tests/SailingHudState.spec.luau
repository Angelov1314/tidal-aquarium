local State = require("../src/shared/SailingHudState")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

expect(State.canOpenPage("背包"), "the production bridge must allow the existing backpack page")
for _, page in ipairs({"钓鱼", "水族馆", "出售", ""}) do
	expect(not State.canOpenPage(page), "the bridge must reject non-backpack pages")
end
expect(not State.canOpenPage(nil), "the bridge must reject a missing page")
expect(not State.canOpenPage(7), "the bridge must reject a non-string page")
expect(State.validatedZone(1, 5) == 1, "zone 1 must be accepted")
expect(State.validatedZone(5, 5) == 5, "zone upper bound must be accepted")
expect(State.validatedZone(nil, 5) == 1, "nil projection must fall back to zone 1")
expect(State.validatedZone("2", 5) == 1, "string projection must fall back to zone 1")
expect(State.validatedZone(0, 5) == 1, "zero projection must fall back to zone 1")
expect(State.validatedZone(6, 5) == 1, "out of range projection must fall back to zone 1")
expect(State.validatedZone(2.5, 5) == 1, "noninteger projection must fall back to zone 1")
expect(State.validatedZone(0 / 0, 5) == 1, "NaN projection must fall back to zone 1")
expect(State.validatedZone(math.huge, 5) == 1, "positive infinity projection must fall back to zone 1")
expect(State.validatedZone(-math.huge, 5) == 1, "negative infinity projection must fall back to zone 1")
expect(State.validatedZone(2, 0) == 1, "empty zone contract must fall back to zone 1")
expect(State.validatedZone(2, 5.5) == 1, "noninteger zone count must fall back to zone 1")
expect(State.effectivePanelOpen(true, true, true), "an enabled visible panel is open")
expect(State.effectivePanelOpen(true, true, nil), "legacy panels without an attribute remain open")
expect(not State.effectivePanelOpen(false, true, true), "a disabled ScreenGui cannot block sailing")
expect(not State.effectivePanelOpen(true, false, true), "a hidden panel cannot block sailing")
expect(not State.effectivePanelOpen(true, true, false), "an explicit closed attribute wins")
expect(State.openingAcknowledged(true, true, true, "背包", "背包"), "backpack opening ack needs all visible state")
expect(not State.openingAcknowledged(true, true, false, "背包", "背包"), "closed panel cannot acknowledge opening")
expect(not State.openingAcknowledged(true, true, true, "钓鱼", "背包"), "wrong page cannot acknowledge opening")
local oldGui, replacementGui = {}, {}
expect(State.ownsVisibility(oldGui, "old", oldGui, "old"), "matching instance/token owns visibility")
expect(not State.ownsVisibility(oldGui, "old", replacementGui, "old"), "old token cannot restore a same-name replacement")
expect(not State.ownsVisibility(oldGui, "old", oldGui, "new"), "replaced owner token cannot restore")

local state = State.new()
expect(not State.modalOpen(state) and State.blocksIntent(state), "idle state must not drive")
local idleMap, idleEffect = State.transition(state, {kind = "map", value = true})
expect(idleMap.mapOpen and not idleEffect.neutral, "an idle map must not send a sailing stop")
local effect
state, effect = State.transition(state, {kind = "driving", value = true})
expect(state.driving and not effect.neutral, "entering driving must not send a stop")
expect(not State.blocksIntent(state), "driving state should accept intent")

state, effect = State.transition(state, {kind = "panel", value = true})
expect(state.panelOpen and not state.mapOpen and effect.neutral, "opening the backpack must be modal and neutral")
expect(State.blocksIntent(state), "backpack must block sailing intent")
local beforeClose = state
state, effect = State.transition(state, {kind = "panel", value = true})
expect(state.panelOpen and not effect.changed and not effect.neutral, "repeated panel state must not re-neutralize")

state, effect = State.transition(state, {kind = "map", value = true})
expect(state.mapOpen and not state.panelOpen and effect.neutral, "map must replace the backpack modal")
state, effect = State.transition(state, {kind = "map", value = false})
expect(not State.modalOpen(state) and not effect.neutral, "closing map must clear the modal without a second forced stop")
expect(beforeClose.panelOpen, "state fixture must retain the earlier panel edge")

state, effect = State.transition(state, {kind = "driving", value = false})
expect(not state.driving and not State.modalOpen(state) and effect.neutral, "leaving the boat must reset modal state")
local drivingMap = State.new()
drivingMap, effect = State.transition(drivingMap, {kind = "driving", value = true})
drivingMap, effect = State.transition(drivingMap, {kind = "map", value = true})
drivingMap, effect = State.transition(drivingMap, {kind = "driving", value = false})
expect(not drivingMap.driving and not drivingMap.mapOpen and not drivingMap.panelOpen and effect.neutral,
	"a forced leave while the map is open must clear the map modal and neutralize input")
state, effect = State.transition(state, {kind = "reset"})
expect(not state.driving and not State.modalOpen(state), "reset must be idempotent")

print("SailingHudState.spec: page bridge eligibility, modal exclusivity, input blocking, neutral edges and reset PASS")
