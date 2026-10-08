--!strict
-- Pure viewport arithmetic shared by the fishing client and compact-layout tests.
-- Coordinates are relative to the ScreenGui's safe content origin.  Roblox UI
-- instances are still responsible for applying these rectangles.

local ResponsiveLayout = {}

export type Rect = {
	x: number,
	y: number,
	width: number,
	height: number,
}

export type Metrics = {
	width: number,
	height: number,
	safeWidth: number,
	safeHeight: number,
	compact: boolean,
	touch: boolean,
	landscape: boolean,
	scale: number,
	margin: number,
	header: Rect,
	main: Rect,
	content: Rect,
	nav: Rect,
	fishing: Rect,
	audio: Rect,
	compactBag: Rect,
	navButtonWidth: number,
	navButtonHeight: number,
	minTouchTarget: number,
	stackPages: boolean,
	contentScroll: boolean,
	modal: boolean,
}

export type BagDetailMetrics = {
	horizontal: boolean,
	height: number,
	preview: Rect,
	info: Rect,
	actions: {Rect},
}

local function finite(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return fallback end
	return value
end

local function positive(value: any, fallback: number): number
	return math.max(1, finite(value, fallback))
end

local function rect(x: number, y: number, width: number, height: number): Rect
	return {x = x, y = y, width = math.max(1, width), height = math.max(1, height)}
end

-- The threshold deliberately uses both axes: a wide landscape phone is still
-- compact when its short axis cannot hold the desktop header, page and nav.
function ResponsiveLayout.compute(width: number, height: number, insetLeft: number?, insetTop: number?, insetRight: number?, insetBottom: number?, touchEnabled: boolean?, panelOpen: boolean?): Metrics
	local rawWidth = positive(width, 1)
	local rawHeight = positive(height, 1)
	local left = math.max(0, finite(insetLeft, 0))
	local top = math.max(0, finite(insetTop, 0))
	local right = math.max(0, finite(insetRight, 0))
	local bottom = math.max(0, finite(insetBottom, 0))
	local safeWidth = math.max(1, rawWidth - left - right)
	local safeHeight = math.max(1, rawHeight - top - bottom)
	local compact = safeWidth < 800 or safeHeight < 650
	local touch = touchEnabled == true
	local touchTargets = compact or touch
	local landscape = safeWidth > safeHeight
	local margin = if compact then 8 else 16
	-- The economy bar is deliberately shorter on phones.  Keep a little more
	-- vertical room for the three information rows in portrait (or very narrow
	-- landscape) layouts, while the common landscape phone case gets the compact
	-- two-row banner that leaves more of the play space visible.
	local headerWidth = math.min(if compact then 500 else 650, math.max(1, safeWidth - margin * 2))
	local wideCompactLandscape = compact and landscape and headerWidth >= 500
	local headerHeight = if compact then 48 else 66
	local header = rect(left + (safeWidth - headerWidth) * .5, top + (if compact then 8 else 12), headerWidth, headerHeight)
	local navHeight = if compact then 48 else 56
	local navWidth = if compact then math.max(1, safeWidth - margin * 2) else math.min(748, math.max(1, safeWidth - margin * 2))
	local nav = rect(left + (safeWidth - navWidth) * .5, rawHeight - bottom - margin - navHeight, navWidth, navHeight)
	local mainWidth = if compact then math.max(1, safeWidth - margin * 2) else math.min(760, math.max(1, safeWidth - margin * 2))
	local modal = compact and panelOpen == true
	local mainTop = header.y + header.height + 8
	local mainBottom = nav.y - 8
	local mainHeight = if compact then math.max(1, mainBottom - mainTop) else math.min(500, math.max(1, mainBottom - mainTop))
	local main = if modal
		then rect(left + margin, top + margin, math.max(1, safeWidth - margin * 2), math.max(1, safeHeight - margin * 2))
		else rect(left + (safeWidth - mainWidth) * .5, mainTop, mainWidth, mainHeight)
	local contentInset = if compact then 8 else 16
	local content = rect(main.x + contentInset, main.y + (if compact then 58 else 66), math.max(1, main.width - contentInset * 2), math.max(1, main.height - (if compact then 66 else 66)))
	local fishingWidth = if compact then math.min(304, mainWidth) else 360
	local fishingTop = header.y + header.height + 4
	local fishingAvailable = math.max(1, nav.y - 8 - fishingTop)
	local fishingDesired = if compact then 100 else 130
	local fishingHeight = math.min(fishingDesired, fishingAvailable)
	local fishing = rect(left + (safeWidth - fishingWidth) * .5, nav.y - 8 - fishingHeight, fishingWidth, fishingHeight)
	local audioWidth = if compact then math.min(260, math.max(1, safeWidth - margin * 2)) else 240
	local audioY = header.y + header.height + 4
	-- Three desktop toggles use 30px rows at y=36/70/104.  Keep a little
	-- bottom padding instead of letting the last row hang out of the panel.
	local audioHeight = math.min(if compact or touch then 194 else 140, math.max(1, rawHeight - bottom - margin - audioY))
	local audio = rect(left + (safeWidth - audioWidth) * .5, audioY, audioWidth, audioHeight)
	local compactButtonY = if compact then 2 else 10
	local compactBag = rect(header.x + math.max(0, header.width - 114), header.y + compactButtonY, 52, 44)
	return {
		width = rawWidth,
		height = rawHeight,
		safeWidth = safeWidth,
		safeHeight = safeHeight,
		compact = compact,
		touch = touch,
		landscape = landscape,
		scale = 1,
		margin = margin,
		header = header,
		main = main,
		content = content,
		nav = nav,
		fishing = fishing,
		audio = audio,
		compactBag = compactBag,
		navButtonWidth = if compact then 96 else 101,
		navButtonHeight = if touchTargets then 44 else 42,
		minTouchTarget = if touchTargets then 44 else 30,
		stackPages = compact or touch,
		contentScroll = compact or touch,
		modal = modal,
	}
end

-- The selected-fish detail is a vertical page in portrait and on desktop. A
-- wide compact landscape modal has enough width to keep the author preview,
-- readable facts, and four touch actions visible together. Keep this pure so
-- the client and layout tests use the same rectangles.
function ResponsiveLayout.computeBagDetail(width: number, stackPages: boolean, landscape: boolean, modal: boolean): BagDetailMetrics
	local cardWidth = positive(width, 1)
	local horizontal = stackPages and landscape and modal and cardWidth >= 640
	if not horizontal then
		return {
			horizontal = false,
			height = 450,
			preview = rect(0, 0, 100, 100),
			info = rect(0, 0, 1, 1),
			actions = {},
		}
	end
	local padding = 12
	local previewSize = 128
	local actionGap = 8
	local actionHeight = 44
	local actionWidth = math.clamp(math.floor(cardWidth * .42), 260, 340)
	local actionX = math.max(padding + previewSize + 12, cardWidth - padding - actionWidth)
	local infoX = padding + previewSize + 12
	local infoWidth = math.max(1, actionX - infoX - 12)
	local buttonWidth = math.max(1, math.floor((actionWidth - actionGap) * .5))
	local firstY = 20
	local secondY = firstY + actionHeight + actionGap
	return {
		horizontal = true,
		height = 204,
		preview = rect(padding, 18, previewSize, previewSize),
		info = rect(infoX, 12, infoWidth, 180),
		actions = {
			rect(actionX, firstY, buttonWidth, actionHeight),
			rect(actionX + buttonWidth + actionGap, firstY, buttonWidth, actionHeight),
			rect(actionX, secondY, buttonWidth, actionHeight),
			rect(actionX + buttonWidth + actionGap, secondY, buttonWidth, actionHeight),
		},
	}
end

return ResponsiveLayout
