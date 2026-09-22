-- Companion SavedVariables host for AJH.
-- Forever often fails to inject AJH's own SV on login; this tiny addon exists
-- only so AJHStoreDB can load/save reliably (same pattern as SpaceToAccept).
--
-- Never replace a richer loaded table with {}. Forever may call this file
-- after injecting AJHStoreDB — keep whatever is already present.

if type(AJHStoreDB) ~= "table" then
	AJHStoreDB = {}
end
