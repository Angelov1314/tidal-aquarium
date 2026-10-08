--!strict
-- Pure client HUD state contract.  Roblox instances and remotes stay in
-- Sailing.client; this module only makes modal/input transitions testable.

local SailingHudState = {}

export type State = {
	driving: boolean,
	mapOpen: boolean,
	panelOpen: boolean,
}

export type Effect = {
	changed: boolean,
	neutral: boolean,
}

export type Event = {
	kind: string,
	value: boolean?,
}

function SailingHudState.new(): State
	return {
		driving = false,
		mapOpen = false,
		panelOpen = false,
	}
end

function SailingHudState.canOpenPage(page: any): boolean
	return page == "背包"
end

local function finiteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Main publishes only this bounded scalar projection after its existing
-- MutationLaneState acceptance fence. Sailing uses the same helper when it
-- reads the GUI attribute so malformed or stale values always fail closed to
-- the first configured zone.
function SailingHudState.validatedZone(value: any, zoneCount: any): number
	if not finiteNumber(value) or not finiteNumber(zoneCount)
		or zoneCount < 1 or zoneCount % 1 ~= 0
		or value < 1 or value > zoneCount or value % 1 ~= 0 then
		return 1
	end
	return value
end

-- A legacy modal can exist in the PlayerGui while its ScreenGui is disabled
-- by Sailing.  The bridge must treat that state as closed so the new HUD can
-- explicitly restore it for a real backpack request.
function SailingHudState.effectivePanelOpen(guiEnabled: any, panelVisible: any, advertised: any): boolean
	return guiEnabled == true and panelVisible == true and advertised ~= false
end

function SailingHudState.openingAcknowledged(guiEnabled: any, panelVisible: any, panelOpen: any, activeTab: any, expectedPage: any): boolean
	return guiEnabled == true and panelVisible == true and panelOpen == true and activeTab == expectedPage
end

-- Deferred cleanup may outlive the instance that created it.  Restoration is
-- valid only when both the exact instance and its current owner token match.
function SailingHudState.ownsVisibility(instance: any, token: any, currentInstance: any, currentToken: any): boolean
	return instance ~= nil and token ~= nil and instance == currentInstance and token == currentToken
end

function SailingHudState.blocksIntent(state: State): boolean
	return state.driving ~= true or state.mapOpen == true or state.panelOpen == true
end

function SailingHudState.modalOpen(state: State): boolean
	return state.mapOpen == true or state.panelOpen == true
end

local function bool(value: any): boolean
	return value == true
end

function SailingHudState.transition(current: State, event: Event): (State, Effect)
	local next: State = {
		driving = current.driving == true,
		mapOpen = current.mapOpen == true,
		panelOpen = current.panelOpen == true,
	}
	local kind = if type(event) == "table" then event.kind else ""
	local value = if type(event) == "table" then bool(event.value) else false

	if kind == "driving" then
		next.driving = value
		if not value then
			next.mapOpen = false
			next.panelOpen = false
		end
	elseif kind == "map" then
		next.mapOpen = value
		if value then next.panelOpen = false end
	elseif kind == "panel" then
		next.panelOpen = value
		if value then next.mapOpen = false end
	elseif kind == "reset" then
		next.driving = false
		next.mapOpen = false
		next.panelOpen = false
	end

	local changed = next.driving ~= current.driving or next.mapOpen ~= current.mapOpen or next.panelOpen ~= current.panelOpen
	-- Entering a modal must clear a held input path.  The Sailing client turns
	-- this edge into one neutral RemoteEvent and then clears local holds.
	local wasModal = current.mapOpen == true or current.panelOpen == true
	local isModal = next.mapOpen == true or next.panelOpen == true
	local modalOpened = not wasModal and isModal
	local modalSwitched = isModal and (next.mapOpen ~= current.mapOpen or next.panelOpen ~= current.panelOpen)
	local drivingEnded = current.driving and not next.driving
	return next, {
		changed = changed,
		neutral = (current.driving and (modalOpened or modalSwitched)) or drivingEnded,
	}
end

return SailingHudState
