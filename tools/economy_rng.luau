-- Shared deterministic source for offline economy tools.
-- Keep this small so existing and session simulations consume identical draws.
local function rngFor(seed)
	if type(seed) ~= "number" or seed ~= seed or seed == math.huge or seed == -math.huge or math.floor(seed) ~= seed then
		error("seed must be an integer", 0)
	end
	local state = seed % 2147483647
	if state <= 0 then state = 1 end
	return function()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

return rngFor
