-- Companion SavedVariables host for AJH.
-- Same pattern as SpaceToAccept: LoadSavedVariablesFirst + bind a real table.
-- AJH mirrors live progress into AJHStoreDB as a second copy.

if type(AJHStoreDB) ~= "table" then
	AJHStoreDB = {}
end
