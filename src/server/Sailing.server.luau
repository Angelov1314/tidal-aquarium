-- Sailing is a separate server bootstrap so the large fishing service and its
-- existing remotes remain untouched. BoatService waits for the world builder
-- before creating dock prompts and owns its own BoatRemotes folder.
local BoatService = require(script.Parent:WaitForChild("BoatService"))
BoatService.start()
