--!strict
-- Shared HUD surface tokens.  Keep the background readable over the world while
-- leaving text fully opaque; clients use these values for every button state so
-- a hover/disabled/selected transition cannot accidentally restore an opaque fill.

local UiStyle = {}

local buttonTokens: {[string]: number} = {
	normal = 0.35,
	hover = 0.25,
	selected = 0.25,
	disabled = 0.45,
}
UiStyle.button = buttonTokens

local cardTokens: {[string]: number} = {
	normal = 0.35,
	hover = 0.25,
	selected = 0.25,
	disabled = 0.45,
}
UiStyle.card = cardTokens

-- Nested cards need a translucent parent as well; otherwise a transparent
-- button only reveals an opaque cream board behind it.
UiStyle.panelTransparency = 0.2

function UiStyle.buttonTransparency(state: string): number
	return UiStyle.button[state] or UiStyle.button.normal
end

function UiStyle.cardTransparency(state: string): number
	return UiStyle.card[state] or UiStyle.card.normal
end

return UiStyle
