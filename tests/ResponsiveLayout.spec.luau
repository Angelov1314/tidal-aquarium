local Layout = require("../src/client/ResponsiveLayout")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function within(rect, width, height)
	return rect.x >= 0 and rect.y >= 0 and rect.x + rect.width <= width + .001 and rect.y + rect.height <= height + .001
end

local targets = {
	{320, 568}, {360, 800}, {390, 844}, {736, 414}, {852, 393}, {393, 852}, {844, 390}, {1024, 768}, {1280, 720},
}

for _, target in ipairs(targets) do
	local width, height = target[1], target[2]
	local layout = Layout.compute(width, height)
	expect(within(layout.header, width, height), string.format("header escapes %dx%d", width, height))
	expect(within(layout.main, width, height), string.format("main escapes %dx%d", width, height))
	expect(within(layout.nav, width, height), string.format("nav escapes %dx%d", width, height))
	expect(layout.main.y + layout.main.height <= layout.nav.y + .001, string.format("main overlaps nav at %dx%d", width, height))
	if layout.compact then
		expect(layout.header.height <= 48 and layout.header.width <= 500, "mobile economy bar too large")
		expect(layout.fishing.height <= 100 and layout.fishing.width <= 304, "mobile fishing card too large")
		-- Only the menu handle remains while playing. Expanded pages/navigation
		-- are intentional overlays, not part of the permanent scene obstruction.
		local hudArea = layout.header.width * layout.header.height + layout.fishing.width * layout.fishing.height + 64 * 44
		expect(hudArea / (width * height) <= .28, string.format("permanent mobile HUD %.3f at %dx%d", hudArea / (width * height), width, height))
		expect(layout.scale == 1, string.format("compact layout must not globally shrink at %dx%d", width, height))
		expect(layout.navButtonHeight >= 44 and layout.minTouchTarget >= 44, string.format("compact touch target too small at %dx%d", width, height))
		expect(layout.compactBag.width >= 44 and layout.compactBag.height >= 44, string.format("compact bag target too small at %dx%d", width, height))
		expect(layout.stackPages and layout.contentScroll, string.format("compact pages must stack and scroll at %dx%d", width, height))
		expect(layout.content.width <= layout.main.width and layout.content.width > 0, string.format("content width invalid at %dx%d", width, height))
	else
		expect(layout.scale == 1 and not layout.stackPages, string.format("desktop composition changed at %dx%d", width, height))
		expect(layout.navButtonWidth == 101 and layout.navButtonHeight == 42, string.format("desktop nav contract changed at %dx%d", width, height))
	end
end

local inset = Layout.compute(390, 844, 4, 28, 4, 12)
expect(inset.safeWidth == 382 and inset.safeHeight == 804, "safe inset arithmetic must be applied once")
expect(within(inset.main, 390, 844), "inset main must remain inside raw viewport")
expect(inset.main.y + inset.main.height <= inset.nav.y + .001, "inset main must still stop before nav")

local shortLandscape = Layout.compute(844, 390, 4, 36, 4, 34)
expect(shortLandscape.main.height > 0 and shortLandscape.main.y + shortLandscape.main.height <= shortLandscape.nav.y + .001, "short landscape must use available height for scrollable page")
expect(shortLandscape.fishing.width <= 360, "landscape fishing card must not cover touch side regions")
expect(shortLandscape.fishing.y >= shortLandscape.header.y + shortLandscape.header.height + 4 - .001, "short landscape fishing card must clear header")
expect(shortLandscape.fishing.y + shortLandscape.fishing.height <= shortLandscape.nav.y - 8 + .001, "short landscape fishing card must clear nav")
expect(shortLandscape.audio.y + shortLandscape.audio.height <= 390 - 34 + .001, "audio overlay must stay inside safe bottom")

local modalLandscape = Layout.compute(844, 390, 4, 36, 4, 34, true, true)
expect(modalLandscape.modal, "compact panel-open layout must enter modal safe area")
expect(within(modalLandscape.main, 844, 390), "modal main must remain inside raw viewport")
expect(modalLandscape.content.height > shortLandscape.content.height + 100, "modal inventory must recover vertical content space")
expect(modalLandscape.main.y >= 36 - .001 and modalLandscape.main.y + modalLandscape.main.height <= 390 - 34 + .001, "modal main must honor safe insets")

local horizontalDetail = Layout.computeBagDetail(modalLandscape.content.width, modalLandscape.stackPages, modalLandscape.landscape, modalLandscape.modal)
expect(horizontalDetail.horizontal, "wide compact landscape detail must use the horizontal first-screen layout")
expect(horizontalDetail.height == 204, "horizontal detail height must fit the modal viewport")
expect(horizontalDetail.preview.x >= 0 and horizontalDetail.preview.x + horizontalDetail.preview.width <= modalLandscape.content.width + .001, "detail preview escapes card")
expect(horizontalDetail.info.x >= horizontalDetail.preview.x + horizontalDetail.preview.width, "detail info must follow the preview")
expect(horizontalDetail.info.width >= 180 and horizontalDetail.info.height - 44 >= 130, "detail info area must fit readable grouped facts and state lines")
expect(#horizontalDetail.actions == 4, "detail must expose four action rectangles")
for i, action in horizontalDetail.actions do
	 expect(action.height >= 44, string.format("detail action %d is below the touch target", i))
	 expect(action.width >= 126, string.format("detail action %d is too narrow for a wrapped label", i))
	 expect(action.x >= 0 and action.y >= 0 and action.x + action.width <= modalLandscape.content.width + .001 and action.y + action.height <= horizontalDetail.height + .001, string.format("detail action %d escapes card", i))
	 for j = i + 1, #horizontalDetail.actions do
		 local other = horizontalDetail.actions[j]
		 local overlaps = action.x < other.x + other.width and action.x + action.width > other.x and action.y < other.y + other.height and action.y + action.height > other.y
		 expect(not overlaps, string.format("detail actions %d and %d overlap", i, j))
	 end
end

local portraitDetail = Layout.computeBagDetail(374, true, false, true)
expect(not portraitDetail.horizontal and portraitDetail.height == 450, "portrait detail must retain the vertical scroll page")
local narrowLandscapeDetail = Layout.computeBagDetail(600, true, true, true)
expect(not narrowLandscapeDetail.horizontal and narrowLandscapeDetail.height == 450, "narrow landscape must retain readable vertical detail")

local touchTablet = Layout.compute(1024, 768, nil, nil, nil, nil, true)
expect(not touchTablet.compact and touchTablet.touch, "wide touch viewport should keep desktop composition")
expect(touchTablet.minTouchTarget >= 44 and touchTablet.navButtonHeight >= 44, "wide touch viewport must keep readable target sizes")
expect(touchTablet.stackPages and touchTablet.contentScroll, "wide touch pages should keep readable stacked controls")

print("ResponsiveLayout.spec: target bounds, compact touch sizes, safe insets and desktop preservation PASS")
