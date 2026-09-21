local ADDON_NAME, ns = ...
local LibEditMode = ns and ns.LibEditMode

-- Keybind display names. Bindings.xml is auto-loaded by filename — do NOT
-- list it in the TOC (that parses it as UI XML → "Unrecognized XML: Binding").
BINDING_HEADER_AJH = "Archindula's Jump Habit"
BINDING_NAME_AJH_TOGGLE = "Toggle Archindula's Jump Habit"

local MAX_LEVEL = 99
local XP_PER_JUMP = 1
local CAMP_XP_MULTIPLIER = 2
local ADDON_PREFIX = "AJH"
local ROW_HEIGHT = 22
local FROG_ICON = "Interface\\Icons\\Spell_Shaman_Hex"

-- Local testing only. Enabled when Interface/AddOns/AJH/AJH_Dev exists
-- (gitignored; never shipped in the CurseForge zip). Not listed in the TOC.
local DEV_TOOLS = false
do
	if io and io.open then
		local paths = {
			"Interface/AddOns/AJH/AJH_Dev",
			"Interface\\AddOns\\AJH\\AJH_Dev",
			"../Interface/AddOns/AJH/AJH_Dev",
		}
		for i = 1, #paths do
			local ok, f = pcall(io.open, paths[i], "r")
			if ok and f then
				f:close()
				DEV_TOOLS = true
				break
			end
		end
	end
end

local C = {
	bg = { 0.06, 0.07, 0.08, 0.96 },
	header = { 0.09, 0.11, 0.10, 1 },
	border = { 0.45, 0.78, 0.52, 0.55 },
	muted = { 0.55, 0.60, 0.56, 1 },
	text = { 0.90, 0.93, 0.90, 1 },
	accent = { 0.53, 1.00, 0.53, 1 },
	barBg = { 0.12, 0.14, 0.13, 1 },
	barFill = { 0.35, 0.72, 0.42, 1 },
	divider = { 0.45, 0.78, 0.52, 0.22 },
	tabIdle = { 0.10, 0.12, 0.11, 1 },
	tabActive = { 0.14, 0.20, 0.15, 1 },
	rowHi = { 0.12, 0.18, 0.13, 0.9 },
}

-- RuneScape cumulative XP required to reach each level.
local xpForLevel = { [1] = 0 }
do
	local points = 0
	for level = 1, MAX_LEVEL - 1 do
		points = points + math.floor(level + 300 * (2 ^ (level / 7)))
		xpForLevel[level + 1] = math.floor(points / 4)
	end
end

local function ToNumberOr(value, fallback)
	local n = tonumber(value)
	if n then
		return n
	end
	return fallback
end

-- Layout quality for raise-only merges. Visibility (shown) is intentionally
-- excluded so hiding the bar cannot be blocked as a "demotion".
local function JumpXPBarLayoutScore(bar)
	if type(bar) ~= "table" then
		return -1
	end
	local score = 0
	if bar.userPlaced then
		score = score + 100
	end
	local widthPct = ToNumberOr(bar.widthPct, 100)
	if widthPct ~= 100 then
		score = score + 5
	end
	if type(bar.point) == "string" and bar.point ~= "BOTTOM" then
		score = score + 5
	end
	if ToNumberOr(bar.x, 0) ~= 0 or ToNumberOr(bar.y, 55) ~= 55 then
		score = score + 3
	end
	return score
end

local function JumpXPBarScore(bar)
	if type(bar) ~= "table" then
		return -1
	end
	local score = JumpXPBarLayoutScore(bar)
	if bar.shown then
		score = score + 10
	end
	return score
end

local function CopyJumpXPBarTable(src)
	if type(src) ~= "table" then
		return nil
	end
	return {
		point = src.point,
		x = src.x,
		y = src.y,
		widthPct = src.widthPct,
		shown = src.shown,
		userPlaced = src.userPlaced,
	}
end

local function PreferJumpXPBar(destBar, srcBar)
	if JumpXPBarLayoutScore(srcBar) > JumpXPBarLayoutScore(destBar) then
		return CopyJumpXPBarTable(srcBar)
	end
	-- Same layout quality: still prefer a copy that is shown / has shown flag
	-- only when dest has no bar at all.
	if type(destBar) ~= "table" and type(srcBar) == "table" then
		return CopyJumpXPBarTable(srcBar)
	end
	return nil
end

-- Progress lives ONLY in SavedVariables: AJHAccount (SpaceToAccept pattern).
-- Forever: one account SV in WTF/.../SavedVariables/AJH.lua. Do NOT declare
-- AJHFloor or per-character AJHDB in the TOC — multi/per-char SV has been
-- observed to leave ALL AJH globals nil for the whole session.
-- Never write progress into Interface/AddOns. Never ship HighWater files.
--
-- Forever sometimes leaves SV globals empty at ADDON_LOADED even when WTF
-- files are correct. Mitigations:
-- - Canonical progress in account SV (AJHAccount), shared by name+guid aliases.
-- - Always bind to the richest existing copy; never invent an empty row and
--   overwrite a richer name/guid alias.
-- - Raise-only watermarks: AJHFloor.__best and AJHAccount.__floor.
-- - Blank session must not clobber account/floor stores with zeros.
-- - Full identity bind waits until PLAYER_LOGIN (name+guid are ready).

local function MaxProgressInAccountSV()
	local maxJ = 0
	if type(AJHAccount) == "table" then
		for k, rec in pairs(AJHAccount) do
			if type(rec) == "table" then
				local j = ToNumberOr(rec.jumps, 0)
				if j > maxJ then
					maxJ = j
				end
			end
		end
	end
	if type(AJHFloor) == "table" then
		for _, rec in pairs(AJHFloor) do
			if type(rec) == "table" then
				local j = ToNumberOr(rec.jumps, 0)
				if j > maxJ then
					maxJ = j
				end
			end
		end
	end
	if type(AJHDB) == "table" then
		local j = ToNumberOr(AJHDB.jumps, 0)
		if j > maxJ then
			maxJ = j
		end
	end
	return maxJ
end

local lateLoadTicker = nil

local function PlayerKey()
	local guid = UnitGUID("player")
	if type(guid) == "string" and guid ~= "" then
		return guid
	end
	local name = UnitName("player")
	if type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

local function RaiseNumber(dest, key, srcValue)
	local incoming = ToNumberOr(srcValue, nil)
	if type(incoming) ~= "number" then
		return false
	end
	local current = ToNumberOr(dest[key], 0)
	if incoming > current then
		dest[key] = incoming
		return true
	end
	return false
end

RaiseMergeRecord = function(dest, src)
	if type(dest) ~= "table" or type(src) ~= "table" or dest == src then
		return false
	end
	local raised = false
	if RaiseNumber(dest, "jumps", src.jumps) then
		raised = true
	end
	if RaiseNumber(dest, "xp", src.xp) then
		raised = true
	end
	if type(src.achievements) == "table" then
		if type(dest.achievements) ~= "table" then
			dest.achievements = {}
		end
		for id, when in pairs(src.achievements) do
			if dest.achievements[id] == nil then
				dest.achievements[id] = when
				raised = true
			end
		end
	end
	if type(src.board) == "table" then
		if type(dest.board) ~= "table" then
			dest.board = {}
		end
		for key, entry in pairs(src.board) do
			if type(entry) == "table" then
				local existing = dest.board[key]
				if type(existing) ~= "table" then
					dest.board[key] = entry
					raised = true
				elseif ToNumberOr(entry.jumps, 0) > ToNumberOr(existing.jumps, 0) then
					dest.board[key] = entry
					raised = true
				end
			end
		end
	end
	if type(src.jumpXPBar) == "table" then
		local preferred = PreferJumpXPBar(dest.jumpXPBar, src.jumpXPBar)
		if preferred then
			dest.jumpXPBar = preferred
			if dest.jumpXPBar.shown then
				dest.showJumpXPBar = true
			end
			raised = true
		end
	end
	if type(src.jumpXPBarLayouts) == "table" then
		if type(dest.jumpXPBarLayouts) ~= "table" then
			dest.jumpXPBarLayouts = {}
		end
		for layoutName, layout in pairs(src.jumpXPBarLayouts) do
			if type(layout) == "table" then
				local preferred = PreferJumpXPBar(dest.jumpXPBarLayouts[layoutName], layout)
				if preferred or type(dest.jumpXPBarLayouts[layoutName]) ~= "table" then
					dest.jumpXPBarLayouts[layoutName] = preferred or CopyJumpXPBarTable(layout)
					raised = true
				end
			end
		end
	end
	if src.minimapPos ~= nil and dest.minimapPos == nil then
		dest.minimapPos = src.minimapPos
	end
	if src.showJumpXPBar and not dest.showJumpXPBar then
		dest.showJumpXPBar = true
		raised = true
	end
	return raised
end

-- Forever sometimes leaves AJHAccount/AJHFloor/AJHDB nil even when the WTF
-- SavedVariables file on disk is valid (diag: CLIENT_LOAD_FAIL). Re-read ONLY
-- the official SV files under WTF/ — never Interface/AddOns. Raise-merge only.
local lastHydrateNote = "not-run"

local debugLogLines = {}
local debugCopyFrame

local function DebugChat(msg)
	local line = tostring(msg)
	debugLogLines[#debugLogLines + 1] = line
	if #debugLogLines > 200 then
		table.remove(debugLogLines, 1)
	end
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00AJH-DEBUG:|r " .. line)
	end
end

local function GetDebugLogText()
	return table.concat(debugLogLines, "\n")
end

local function ShowDebugCopyFrame(text)
	if not debugCopyFrame then
		local f = CreateFrame("Frame", "AJHDebugCopyFrame", UIParent, BackdropTemplate and "BackdropTemplate" or nil)
		f:SetSize(520, 360)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		f:Hide()
		if type(tinsert) == "function" and UISpecialFrames then
			tinsert(UISpecialFrames, "AJHDebugCopyFrame")
		end
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true,
				tileSize = 32,
				edgeSize = 32,
				insets = { left = 8, right = 8, top = 8, bottom = 8 },
			})
			f:SetBackdropColor(0, 0, 0, 0.95)
		else
			local bg = f:CreateTexture(nil, "BACKGROUND")
			bg:SetAllPoints()
			bg:SetColorTexture(0, 0, 0, 0.92)
		end

		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOP", 0, -14)
		title:SetText("AJH Debug — Ctrl+A then Ctrl+C")

		local scroll = CreateFrame("ScrollFrame", "AJHDebugCopyScroll", f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -36)
		scroll:SetPoint("BOTTOMRIGHT", -36, 44)

		local edit = CreateFrame("EditBox", "AJHDebugCopyEdit", scroll)
		edit:SetMultiLine(true)
		edit:SetFontObject(GameFontHighlightSmall)
		edit:SetWidth(460)
		edit:SetAutoFocus(false)
		edit:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			f:Hide()
		end)
		scroll:SetScrollChild(edit)
		f.edit = edit

		local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		hint:SetPoint("BOTTOMLEFT", 16, 16)
		hint:SetText("Ctrl+A, Ctrl+C, paste here")

		local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		close:SetSize(80, 22)
		close:SetPoint("BOTTOMRIGHT", -16, 14)
		close:SetText("Close")
		close:SetScript("OnClick", function()
			f:Hide()
		end)

		debugCopyFrame = f
	end

	local f = debugCopyFrame
	f.edit:SetText(text or "")
	f:Show()
	f.edit:SetFocus()
	f.edit:HighlightText()
end

local function DebugDump(tag)
	-- Automatic login dumps only in local-dev. Manual `/ajh copy` always works.
	if not DEV_TOOLS and not (type(tag) == "string" and tag:find("manual", 1, true)) then
		return
	end
	local name = UnitName("player") or "?"
	local guid = UnitGUID("player") or "?"
	local key = PlayerKey() or "?"
	local function jOf(tbl)
		if type(tbl) ~= "table" then
			return "nil"
		end
		return tostring(ToNumberOr(tbl.jumps, 0))
	end
	-- Forever may inject SV into _G while the addon env still sees nil.
	local gAccount = rawget(_G, "AJHAccount")
	local gFloor = rawget(_G, "AJHFloor")
	local gDB = rawget(_G, "AJHDB")
	local acctMax = 0
	local srcAccount = (type(AJHAccount) == "table" and AJHAccount) or (type(gAccount) == "table" and gAccount)
	if type(srcAccount) == "table" then
		for _, rec in pairs(srcAccount) do
			if type(rec) == "table" then
				local j = ToNumberOr(rec.jumps, 0)
				if j > acctMax then
					acctMax = j
				end
			end
		end
	end
	local nameRow = "nil"
	if type(srcAccount) == "table" and type(srcAccount[name]) == "table" then
		nameRow = jOf(srcAccount[name])
	end
	local guidRow = "nil"
	if type(srcAccount) == "table" and type(srcAccount[guid]) == "table" then
		guidRow = jOf(srcAccount[guid])
	end
	local acctFloor = "nil"
	if type(srcAccount) == "table" then
		acctFloor = jOf(srcAccount.__floor)
	end
	local floorBest = "nil"
	local srcFloor = (type(AJHFloor) == "table" and AJHFloor) or (type(gFloor) == "table" and gFloor)
	if type(srcFloor) == "table" then
		floorBest = jOf(srcFloor.__best)
	end
	DebugChat("======== " .. tag .. " ========")
	DebugChat("1 player=" .. name .. " addon=" .. tostring(ADDON_NAME) .. " key=" .. tostring(key))
	DebugChat("2 env Account=" .. type(AJHAccount) .. " Floor=" .. type(AJHFloor) .. " DB=" .. type(AJHDB))
	DebugChat("3 _G Account=" .. type(gAccount) .. " Floor=" .. type(gFloor) .. " DB=" .. type(gDB))
	DebugChat("4 AJHDB.jumps=" .. jOf(AJHDB) .. " _G.AJHDB.jumps=" .. jOf(gDB))
	DebugChat("5 AccountMax=" .. tostring(acctMax) .. " nameRow=" .. nameRow .. " guidRow=" .. guidRow)
	DebugChat("6 __floor=" .. acctFloor .. " Floor.__best=" .. floorBest)
	DebugChat("7 hydrate=" .. tostring(lastHydrateNote))
	DebugChat("8 tocSV=AJHAccount+AJHFloor+perchar (locked)")
	local dbShape = "nil"
	if type(AJHDB) == "table" then
		if type(AJHDB.jumps) == "number" then
			dbShape = "char-row jumps=" .. tostring(AJHDB.jumps)
		elseif AJHDB.__floor then
			dbShape = "account-store"
		else
			local nested = false
			for _, v in pairs(AJHDB) do
				if type(v) == "table" and type(v.jumps) == "number" then
					nested = true
					break
				end
			end
			dbShape = nested and "account-store" or "table-other"
		end
	end
	DebugChat("9 AJHDB_shape=" .. dbShape .. " Account=" .. type(AJHAccount))
	DebugChat("10 store=" .. type(rawget(_G, "AJHStoreDB")) .. " sta=" .. type(rawget(_G, "SpaceToAcceptDB")))
	DebugChat("======== end ========")
end

-- If Forever put SV on _G but not in the addon env, pull them in.
local function SyncSavedVarsFromGlobal()
	if type(AJHAccount) ~= "table" and type(rawget(_G, "AJHAccount")) == "table" then
		AJHAccount = rawget(_G, "AJHAccount")
	end
	if type(AJHFloor) ~= "table" and type(rawget(_G, "AJHFloor")) == "table" then
		AJHFloor = rawget(_G, "AJHFloor")
	end
	local gDB = rawget(_G, "AJHDB")
	if type(AJHDB) ~= "table" and type(gDB) == "table" then
		AJHDB = gDB
	end
end

-- Forever may inject the account store as AJHDB (mis-named) or leave a legacy
-- AJHAccount table. Normalize so the rest of the addon always sees AJHAccount
-- as the account store; EnsureDB then rebinds AJHDB to the character row.
local function AbsorbAccountStoreFromAJHDB()
	if type(AJHDB) ~= "table" then
		return false
	end
	local key = PlayerKey()
	local name = UnitName("player")
	local hasNestedPlayer = false
	for k, v in pairs(AJHDB) do
		if k == "__floor" or (type(v) == "table" and type(v.jumps) == "number") then
			hasNestedPlayer = true
			break
		end
	end
	-- Character-row shape (legacy per-char SV): top-level jumps, no nested players.
	if type(AJHDB.jumps) == "number" and not AJHDB.__floor and not hasNestedPlayer then
		if type(AJHAccount) ~= "table" then
			AJHAccount = {}
		end
		if key then
			AJHAccount[key] = AJHDB
		end
		if type(name) == "string" and name ~= "" then
			AJHAccount[name] = AJHDB
		end
		return true
	end
	-- Account-store shape: nested player keys / __floor.
	if hasNestedPlayer or type(AJHDB.jumps) ~= "number" then
		local looksAccount = false
		for k, v in pairs(AJHDB) do
			if k == "__floor" or (type(v) == "table" and type(v.jumps) == "number") then
				looksAccount = true
				break
			end
		end
		if looksAccount then
			AJHAccount = AJHDB
			return true
		end
	end
	return false
end

local function TryHydrateSavedVariablesFromWTF()
	if not (io and io.open) then
		lastHydrateNote = "no-io-api"
		return false
	end
	local paths = {
		"WTF/Account/100206261#2/SavedVariables/AJH.lua",
		"WTF\\Account\\100206261#2\\SavedVariables\\AJH.lua",
		"WTF/Account/100206261#2/SavedVariables/AJH.lua.bak",
		"WTF\\Account\\100206261#2\\SavedVariables\\AJH.lua.bak",
		"D:/World of Warcraft/_classic_beta_/WTF/Account/100206261#2/SavedVariables/AJH.lua",
		"D:\\World of Warcraft\\_classic_beta_\\WTF\\Account\\100206261#2\\SavedVariables\\AJH.lua",
		"D:/World of Warcraft/_classic_beta_/WTF/Account/100206261#2/SavedVariables/AJH.lua.bak",
		"D:\\World of Warcraft\\_classic_beta_\\WTF\\Account\\100206261#2\\SavedVariables\\AJH.lua.bak",
		"WTF/Account/100206261#2/70/Resist-Rex/SavedVariables/AJH.lua",
		"D:/World of Warcraft/_classic_beta_/WTF/Account/100206261#2/70/Resist-Rex/SavedVariables/AJH.lua",
	}
	local function readBody(path)
		local ok, body = pcall(function()
			local f = io.open(path, "r")
			if not f then
				return nil
			end
			local data = f:read("*a")
			f:close()
			return data
		end)
		if ok and type(body) == "string" and body ~= "" then
			return body
		end
		return nil
	end
	local function parse(body)
		if type(body) ~= "string" then
			return nil, nil, nil
		end
		if body:match("AJHAccount%s*=%s*nil") and not body:match("AJHAccount%s*=%s*{")
			and not body:match("AJHFloor%s*=%s*{")
			and not body:match("AJHDB%s*=%s*{")
		then
			return nil, nil, nil
		end
		local loader = loadstring or load
		if not loader then
			return nil, nil, nil
		end
		local env = {}
		local fn
		if setfenv then
			fn = loader(body)
			if fn then
				setfenv(fn, env)
			end
		else
			fn = loader(body, "AJH_sv_hydrate", "t", env)
		end
		if not fn or not pcall(fn) then
			return nil, nil, nil
		end
		return env.AJHAccount, env.AJHFloor, env.AJHDB
	end
	local function mergeAccount(account)
		if type(account) ~= "table" then
			return false
		end
		local raised = false
		if type(AJHAccount) ~= "table" then
			AJHAccount = account
			return true
		end
		for key, rec in pairs(account) do
			if type(rec) == "table" then
				if type(AJHAccount[key]) ~= "table" then
					AJHAccount[key] = rec
					raised = true
				elseif RaiseMergeRecord(AJHAccount[key], rec) then
					raised = true
				end
			end
		end
		return raised
	end
	local function mergeFloor(floor)
		if type(floor) ~= "table" then
			return false
		end
		local raised = false
		if type(AJHFloor) ~= "table" then
			AJHFloor = floor
			return true
		end
		for key, rec in pairs(floor) do
			if type(rec) == "table" then
				if type(AJHFloor[key]) ~= "table" then
					AJHFloor[key] = rec
					raised = true
				elseif RaiseMergeRecord(AJHFloor[key], rec) then
					raised = true
				end
			end
		end
		return raised
	end
	local function mergeChar(db)
		if type(db) ~= "table" then
			return false
		end
		if ToNumberOr(db.jumps, 0) <= 0 and ToNumberOr(db.xp, 0) <= 0 then
			return false
		end
		if type(AJHDB) ~= "table" then
			AJHDB = {}
		end
		return RaiseMergeRecord(AJHDB, db)
	end

	local raised = false
	local opened = 0
	local bestDisk = 0
	for i = 1, #paths do
		local body = readBody(paths[i])
		if body then
			opened = opened + 1
			local account, floor, charDB = parse(body)
			local diskJ = 0
			if type(account) == "table" then
				for _, rec in pairs(account) do
					if type(rec) == "table" then
						local j = ToNumberOr(rec.jumps, 0)
						if j > diskJ then
							diskJ = j
						end
					end
				end
			end
			if type(charDB) == "table" then
				local j = ToNumberOr(charDB.jumps, 0)
				if j > diskJ then
					diskJ = j
				end
			end
			if diskJ > bestDisk then
				bestDisk = diskJ
			end
			if mergeAccount(account) then
				raised = true
			end
			if mergeFloor(floor) then
				raised = true
			end
			if mergeChar(charDB) then
				raised = true
			end
		end
	end
	lastHydrateNote = string.format("opened=%d bestDisk=%d raised=%s", opened, bestDisk, raised and "yes" or "no")
	return raised
end

local function FillDBDefaults(db)
	local jumps = ToNumberOr(db.jumps, nil)
	if type(jumps) ~= "number" then
		jumps = 0
	end
	db.jumps = jumps

	local xp = ToNumberOr(db.xp, nil)
	if type(xp) ~= "number" then
		xp = db.jumps * XP_PER_JUMP
	elseif db.jumps > 0 and xp == db.jumps * 10 then
		xp = db.jumps
	end
	db.xp = xp

	if type(db.board) ~= "table" then
		db.board = {}
	end
	db.minimapPos = ToNumberOr(db.minimapPos, 210)
	if type(db.minimapPos) ~= "number" then
		db.minimapPos = 210
	end
	if type(db.achievements) ~= "table" then
		db.achievements = {}
	end
	if type(db.jumpXPBar) ~= "table" then
		db.jumpXPBar = {}
	end
	local barDB = db.jumpXPBar

	if barDB.shown == nil and db.showJumpXPBar ~= nil then
		barDB.shown = not not db.showJumpXPBar
	end
	if barDB.shown == nil then
		barDB.shown = false
	else
		barDB.shown = not not barDB.shown
	end
	db.showJumpXPBar = barDB.shown

	local function adoptPos(src)
		if type(src) ~= "table" then
			return
		end
		if barDB.point == nil and type(src.point) == "string" then
			barDB.point = src.point
		end
		if barDB.x == nil then
			barDB.x = ToNumberOr(src.x, nil)
		end
		if barDB.y == nil then
			barDB.y = ToNumberOr(src.y, nil)
		end
		if barDB.widthPct == nil then
			barDB.widthPct = ToNumberOr(src.widthPct, nil)
		end
	end

	if type(db.jumpXPBarPos) == "table" then
		local legacy = db.jumpXPBarPos
		adoptPos(legacy)
		if barDB.widthPct == nil and type(legacy.fullWidth) == "number" and legacy.fullWidth > 0 and type(legacy.width) == "number" then
			barDB.widthPct = math.floor((legacy.width / legacy.fullWidth) * 100 + 0.5)
		end
		db.jumpXPBarPos = nil
	end
	if type(db.jumpXPBarLayouts) == "table" then
		local layouts = db.jumpXPBarLayouts
		adoptPos(layouts.__legacy)
		-- Prefer the highest-scoring saved Edit Mode layout over defaults / partial bars.
		local bestLayout, bestScore = nil, JumpXPBarLayoutScore(barDB)
		for _, data in pairs(layouts) do
			if type(data) == "table" and data.point then
				adoptPos(data)
				local score = JumpXPBarLayoutScore(data)
				if score > bestScore then
					bestLayout, bestScore = data, score
				end
			end
		end
		if bestLayout then
			barDB.point = bestLayout.point or barDB.point
			barDB.x = ToNumberOr(bestLayout.x, barDB.x)
			barDB.y = ToNumberOr(bestLayout.y, barDB.y)
			barDB.widthPct = ToNumberOr(bestLayout.widthPct, barDB.widthPct)
			if bestLayout.userPlaced then
				barDB.userPlaced = true
			end
			-- Do not copy shown from layouts here — visibility is independent.
		end
	else
		db.jumpXPBarLayouts = {}
	end

	if type(barDB.point) ~= "string" then
		barDB.point = "BOTTOM"
	end
	barDB.x = ToNumberOr(barDB.x, 0) or 0
	barDB.y = ToNumberOr(barDB.y, 55) or 55
	barDB.widthPct = ToNumberOr(barDB.widthPct, 100) or 100
	if barDB.widthPct < 50 then
		barDB.widthPct = 50
	elseif barDB.widthPct > 100 then
		barDB.widthPct = 100
	end
	db.showJumpXPBar = not not barDB.shown
end

local function RaiseFromOwnBoard(rec)
	if type(rec) ~= "table" or type(rec.board) ~= "table" then
		return false
	end
	local name = UnitName("player")
	if type(name) ~= "string" or name == "" then
		return false
	end
	local raised = false
	local prefix = name .. "-"
	for boardKey, entry in pairs(rec.board) do
		if type(entry) == "table" and type(boardKey) == "string" then
			if boardKey == name or boardKey:sub(1, #prefix) == prefix then
				if RaiseNumber(rec, "jumps", entry.jumps) then
					raised = true
				end
				-- Board only stores jumps; keep xp at least in sync with jumps.
				if RaiseNumber(rec, "xp", entry.jumps) then
					raised = true
				end
			end
		end
	end
	return raised
end

local function IsWatermarkRecord(record)
	-- Only dedicated watermark slots — never treat player AJHFloor/AJHAccount
	-- identity rows as watermarks (that blocked them from being canonical).
	if type(record) ~= "table" then
		return false
	end
	if type(AJHAccount) == "table" and record == AJHAccount.__floor then
		return true
	end
	if type(AJHFloor) == "table" and record == AJHFloor.__best then
		return true
	end
	return false
end

local function CollectFloorCandidates(name, guid, key)
	local out = {}
	local function consider(record)
		if type(record) == "table" then
			out[#out + 1] = record
		end
	end
	if type(AJHAccount) == "table" then
		consider(AJHAccount.__floor)
	end
	if type(AJHFloor) ~= "table" then
		return out
	end
	consider(AJHFloor.__best)
	consider(key and AJHFloor[key])
	consider(name and AJHFloor[name])
	consider(guid and AJHFloor[guid])
	for floorKey, floorRec in pairs(AJHFloor) do
		if floorKey ~= "__best" and type(floorRec) == "table" then
			if (guid and floorKey == guid)
				or (name and (floorKey == name or (type(floorKey) == "string" and floorKey:sub(1, #name + 1) == (name .. "-"))))
			then
				consider(floorRec)
			end
		end
	end
	return out
end

local function CommitFloor()
	local key = PlayerKey()
	if not key or type(AJHDB) ~= "table" or type(AJHAccount) ~= "table" then
		return
	end

	local liveJumps = ToNumberOr(AJHDB.jumps, 0)
	local liveXp = ToNumberOr(AJHDB.xp, 0)
	-- Never seed a zero watermark. A blank in-memory session must not
	-- overwrite richer account data on logout.
	if liveJumps <= 0 and liveXp <= 0 then
		return
	end

	local name = UnitName("player")
	local guid = UnitGUID("player")
	-- Heal live progress from every watermark before the client writes WTF.
	for _, src in ipairs(CollectFloorCandidates(name, guid, key)) do
		RaiseMergeRecord(AJHDB, src)
	end
	liveJumps = ToNumberOr(AJHDB.jumps, 0)
	liveXp = ToNumberOr(AJHDB.xp, 0)
	if liveJumps <= 0 then
		return
	end

	if type(AJHAccount.__floor) ~= "table" then
		AJHAccount.__floor = {}
	end
	RaiseNumber(AJHAccount.__floor, "jumps", liveJumps)
	RaiseNumber(AJHAccount.__floor, "xp", liveXp)
	if type(AJHDB.achievements) == "table" then
		if type(AJHAccount.__floor.achievements) ~= "table" then
			AJHAccount.__floor.achievements = {}
		end
		for id, when in pairs(AJHDB.achievements) do
			if AJHAccount.__floor.achievements[id] == nil then
				AJHAccount.__floor.achievements[id] = when
			end
		end
	end
	if type(AJHDB.jumpXPBar) == "table" then
		if type(AJHAccount.__floor.jumpXPBar) ~= "table"
			or JumpXPBarScore(AJHDB.jumpXPBar) > JumpXPBarScore(AJHAccount.__floor.jumpXPBar)
		then
			AJHAccount.__floor.jumpXPBar = CopyJumpXPBarTable(AJHDB.jumpXPBar)
		end
	end
end

-- Forever injects SavedVariables at VARIABLES_LOADED. Creating AJHDB={} before
-- that (e.g. via BuildJumpXPBar → EnsureDB at ADDON_LOADED) poisons the session
-- with an empty char DB while Account/Floor are still nil.
local variablesLoadedFired = false

local function EnsureDB()
	if not variablesLoadedFired then
		return
	end

	SyncSavedVarsFromGlobal()
	-- If Forever left SV globals empty, re-read the official WTF files first.
	if MaxProgressInAccountSV() <= 0 then
		TryHydrateSavedVariablesFromWTF()
		SyncSavedVarsFromGlobal()
	end

	-- Merge into existing SV tables only. Forever TOC declares AJHAccount only
	-- (SpaceToAccept pattern). AJHDB is a runtime alias to the player row —
	-- never a separate SavedVariable. AJHFloor is legacy/read-only if present.
	if type(AJHDB) ~= "table" then
		AJHDB = {}
	end

	local key = PlayerKey()
	if not key then
		-- Player identity not ready yet. Do not create account keys here —
		-- an empty bind on ADDON_LOADED can overwrite richer aliases on save.
		FillDBDefaults(AJHDB)
		return
	end

	local name = UnitName("player")
	local guid = UnitGUID("player")
	local accountPresent = type(AJHAccount) == "table"
	local floorPresent = type(AJHFloor) == "table"

	-- Gather every known copy. Forever sometimes loads one key and not the other,
	-- or leaves AJHDB empty while AJHAccount still has progress.
	local candidates = {}
	local function consider(record)
		if type(record) == "table" then
			candidates[#candidates + 1] = record
		end
	end
	if accountPresent then
		consider(AJHAccount[key])
		if type(name) == "string" and name ~= "" then
			consider(AJHAccount[name])
		end
		if type(guid) == "string" and guid ~= "" and guid ~= key then
			consider(AJHAccount[guid])
		end
		consider(AJHAccount.__floor)
	end
	if type(AJHDB) == "table" then
		consider(AJHDB)
	end
	if floorPresent then
		for _, floorRec in ipairs(CollectFloorCandidates(name, guid, key)) do
			consider(floorRec)
		end
	end

	-- Canonical record = richest player-owned candidate. Never promote a
	-- watermark table into the live player slot.
	local rec = nil
	local bestJumps = -1
	for i = 1, #candidates do
		local c = candidates[i]
		if not IsWatermarkRecord(c) then
			local j = ToNumberOr(c.jumps, 0)
			if j > bestJumps then
				rec = c
				bestJumps = j
			end
		end
	end
	if type(rec) ~= "table" then
		rec = {}
	end

	for i = 1, #candidates do
		local c = candidates[i]
		if c ~= rec then
			RaiseMergeRecord(rec, c)
		end
	end

	RaiseFromOwnBoard(rec)
	FillDBDefaults(rec)

	local jumps = ToNumberOr(rec.jumps, 0)
	local watermarkMax = 0
	for i = 1, #candidates do
		local c = candidates[i]
		if IsWatermarkRecord(c) then
			local wj = ToNumberOr(c.jumps, 0)
			if wj > watermarkMax then
				watermarkMax = wj
			end
		end
	end
	-- Never allow a live bind below a known watermark (partial merge / shared-table miss).
	if jumps < watermarkMax then
		for i = 1, #candidates do
			RaiseMergeRecord(rec, candidates[i])
		end
		jumps = ToNumberOr(rec.jumps, 0)
	end

	if jumps <= 0 then
		-- Blank session: keep a throwaway display table and do NOT create or
		-- clobber account SavedVariables. Writing zeros is what wipes players
		-- when Forever fails to load the real WTF data into memory.
		AJHDB = rec
		return
	end

	-- Demotion guard: if account already holds a richer row, raise into it and
	-- keep that table identity so logout cannot serialize a lower alias.
	if accountPresent then
		local existing = AJHAccount[key]
		if type(existing) == "table" and existing ~= rec then
			local existingJumps = ToNumberOr(existing.jumps, 0)
			if existingJumps > jumps then
				RaiseMergeRecord(existing, rec)
				rec = existing
				jumps = ToNumberOr(rec.jumps, 0)
			else
				RaiseMergeRecord(rec, existing)
			end
		end
	end

	if not accountPresent then
		AJHAccount = {}
	end

	-- Point every identity key at the SAME table so a later save cannot
	-- serialize an empty alias over the good one.
	AJHAccount[key] = rec
	if type(name) == "string" and name ~= "" then
		AJHAccount[name] = rec
	end
	if type(guid) == "string" and guid ~= "" then
		AJHAccount[guid] = rec
	end

	AJHDB = rec
	CommitFloor()
end

-- Forever often fails to inject AJHAccount/AJHDB on login even when WTF is
-- valid. Mirror progress into AJHStoreDB (companion addon) and, as a backup,
-- SpaceToAcceptDB.AJH — same SV pattern SpaceToAccept loads successfully.
-- Do NOT hardcode jump floors in shipping builds (that would gift/wipe everyone).
local function CopyAccountStore(src)
	if type(src) ~= "table" then
		return nil
	end
	local out = {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			local row = {}
			for rk, rv in pairs(v) do
				if type(rv) ~= "table" then
					row[rk] = rv
				elseif rk == "achievements" or rk == "board" or rk == "jumpXPBarLayouts" then
					local nested = {}
					for nk, nv in pairs(rv) do
						nested[nk] = nv
					end
					row[rk] = nested
				elseif rk == "jumpXPBar" then
					row[rk] = CopyJumpXPBarTable(rv)
				end
			end
			out[k] = row
		else
			out[k] = v
		end
	end
	return out
end

local function MaxJumpsInStore(store)
	local best = 0
	if type(store) ~= "table" then
		return best
	end
	for _, rec in pairs(store) do
		if type(rec) == "table" then
			local j = ToNumberOr(rec.jumps, 0)
			if j > best then
				best = j
			end
		end
	end
	return best
end

local function PersistProgressMirror()
	if type(AJHAccount) ~= "table" then
		return
	end
	if MaxProgressInAccountSV() <= 0 then
		return
	end
	local snapshot = CopyAccountStore(AJHAccount)
	if not snapshot then
		return
	end
	if type(AJHStoreDB) ~= "table" then
		AJHStoreDB = {}
	end
	-- Raise-only: never demote a richer mirror.
	if MaxJumpsInStore(snapshot) >= MaxJumpsInStore(AJHStoreDB.account) then
		AJHStoreDB.account = snapshot
		AJHStoreDB.jumps = MaxJumpsInStore(snapshot)
		AJHStoreDB.updated = time and time() or 0
	end
	if type(SpaceToAcceptDB) == "table" then
		local prev = SpaceToAcceptDB.AJH
		if type(prev) ~= "table" or MaxJumpsInStore(snapshot) >= MaxJumpsInStore(prev.account) then
			SpaceToAcceptDB.AJH = {
				account = snapshot,
				jumps = MaxJumpsInStore(snapshot),
			}
		end
	end
	if _G then
		rawset(_G, "AJHStoreDB", AJHStoreDB)
	end
end

local function RestoreProgressMirror()
	local candidates = {}
	if type(AJHStoreDB) == "table" and type(AJHStoreDB.account) == "table" then
		candidates[#candidates + 1] = { src = "AJHStoreDB", store = AJHStoreDB.account }
	end
	local sta = rawget(_G, "SpaceToAcceptDB")
	if type(sta) == "table" and type(sta.AJH) == "table" and type(sta.AJH.account) == "table" then
		candidates[#candidates + 1] = { src = "SpaceToAcceptDB", store = sta.AJH.account }
	end
	local best, bestSrc, bestJ = nil, nil, 0
	for i = 1, #candidates do
		local j = MaxJumpsInStore(candidates[i].store)
		if j > bestJ then
			bestJ = j
			best = candidates[i].store
			bestSrc = candidates[i].src
		end
	end
	if not best or bestJ <= 0 then
		return false
	end
	local accountJ = MaxProgressInAccountSV()
	if type(AJHAccount) == "table" and accountJ >= bestJ then
		return false
	end
	AJHAccount = CopyAccountStore(best) or best
	lastHydrateNote = "mirror-" .. tostring(bestSrc) .. "-" .. tostring(bestJ)
	return true
end

local function HealProgressOnLogin()
	local beforeJumps = 0
	local beforeXp = 0
	if type(AJHDB) == "table" then
		beforeJumps = ToNumberOr(AJHDB.jumps, 0)
		beforeXp = ToNumberOr(AJHDB.xp, 0)
	end
	SyncSavedVarsFromGlobal()
	AbsorbAccountStoreFromAJHDB()
	local mirrored = RestoreProgressMirror()
	if mirrored and DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cff88ff88AJH:|r Restored Jump Habit progress from companion store."
		)
	end
	EnsureDB()
	if MaxProgressInAccountSV() > 0 or (type(AJHDB) == "table" and ToNumberOr(AJHDB.jumps, 0) > 0) then
		PersistProgressMirror()
	end
	local afterJumps = ToNumberOr(AJHDB and AJHDB.jumps, 0)
	local afterXp = ToNumberOr(AJHDB and AJHDB.xp, 0)
	return afterJumps > beforeJumps or afterXp > beforeXp
end

-- StartLateLoadWatch is defined later (needs panel / diag locals).

-- ---------------------------------------------------------------------------
-- Diagnostics (pre-release). Read-only snapshots of SV globals before/after
-- EnsureDB so we can tell client load failure from addon bind poisoning.
-- /ajh diag  — dump latest snapshots + verdict
-- /ajh diag on|off — toggle automatic chat spam (default off)
-- ---------------------------------------------------------------------------
local DIAG_ENABLED = false -- /ajh diag on|off toggles automatic chat spam; /ajh diag always dumps
local diagLog = {}
local diagRawAtAddonLoaded = nil
local diagAfterBind = nil
local diagAtLogout = nil

local function DiagChat(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffAJH-DIAG:|r " .. msg)
	end
end

local function DiagJumpsOf(rec)
	if type(rec) ~= "table" then
		return nil
	end
	return ToNumberOr(rec.jumps, 0)
end

local function DiagScanAccount()
	local rows = {}
	local maxJ = 0
	if type(AJHAccount) ~= "table" then
		return rows, maxJ
	end
	for k, rec in pairs(AJHAccount) do
		if k ~= "__floor" and type(rec) == "table" then
			local j = ToNumberOr(rec.jumps, 0)
			rows[#rows + 1] = {
				key = tostring(k),
				jumps = j,
				xp = ToNumberOr(rec.xp, 0),
				sameAsDB = (rec == AJHDB),
			}
			if j > maxJ then
				maxJ = j
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.key < b.key
	end)
	return rows, maxJ
end

local function DiagSnapshot(label)
	local name = UnitName("player")
	local guid = UnitGUID("player")
	local key = PlayerKey()
	local rows, maxAccount = DiagScanAccount()
	local floorJ = 0
	if type(AJHFloor) == "table" then
		floorJ = math.max(
			ToNumberOr(AJHFloor.__best and AJHFloor.__best.jumps, 0),
			ToNumberOr(key and AJHFloor[key] and AJHFloor[key].jumps, 0),
			ToNumberOr(name and AJHFloor[name] and AJHFloor[name].jumps, 0),
			ToNumberOr(guid and AJHFloor[guid] and AJHFloor[guid].jumps, 0)
		)
	end
	local acctFloorJ = ToNumberOr(
		type(AJHAccount) == "table" and AJHAccount.__floor and AJHAccount.__floor.jumps,
		0
	)
	local snap = {
		label = label,
		t = GetTime and GetTime() or 0,
		accountType = type(AJHAccount),
		floorType = type(AJHFloor),
		dbType = type(AJHDB),
		key = key and tostring(key) or "nil",
		name = (type(name) == "string" and name ~= "" and name) or "nil",
		guid = (type(guid) == "string" and guid ~= "" and guid) or "nil",
		dbJumps = DiagJumpsOf(AJHDB),
		maxAccountJumps = maxAccount,
		accountFloorJumps = acctFloorJ,
		floorJumps = floorJ,
		rows = rows,
		dbIsAccountRef = false,
	}
	if type(AJHDB) == "table" and type(AJHAccount) == "table" then
		for _, row in ipairs(rows) do
			-- row.sameAsDB already computed
			if row.sameAsDB then
				snap.dbIsAccountRef = true
				break
			end
		end
		if AJHAccount.__floor == AJHDB then
			snap.dbIsAccountRef = true
		end
	end
	diagLog[#diagLog + 1] = snap
	if #diagLog > 20 then
		table.remove(diagLog, 1)
	end
	return snap
end

local function DiagPrintSnapshot(snap, verbose)
	if not snap then
		DiagChat("no snapshot")
		return
	end
	DiagChat(string.format(
		"[%s] account=%s floorSV=%s db=%s key=%s name=%s",
		snap.label,
		snap.accountType,
		snap.floorType,
		snap.dbType,
		snap.key,
		snap.name
	))
	DiagChat(string.format(
		"[%s] dbJumps=%s maxAccount=%s acctFloor=%s floorSV=%s dbAlias=%s",
		snap.label,
		tostring(snap.dbJumps),
		tostring(snap.maxAccountJumps),
		tostring(snap.accountFloorJumps),
		tostring(snap.floorJumps),
		snap.dbIsAccountRef and "yes" or "no"
	))
	if verbose and snap.rows then
		for _, row in ipairs(snap.rows) do
			DiagChat(string.format(
				"  account[%s] jumps=%s xp=%s sameAsDB=%s",
				row.key,
				tostring(row.jumps),
				tostring(row.xp),
				row.sameAsDB and "yes" or "no"
			))
		end
	end
end


local function DiagVerdict()
	local raw = diagRawAtAddonLoaded
	local bound = diagAfterBind
	if not raw then
		return "INCOMPLETE", "No ADDON_LOADED/raw snapshot yet. /reload and watch chat."
	end

	local rawMax = math.max(
		raw.maxAccountJumps or 0,
		raw.floorJumps or 0,
		raw.accountFloorJumps or 0,
		raw.dbJumps or 0
	)
	local boundDb = bound and (bound.dbJumps or 0) or -1

	-- Client handed us nothing useful from WTF.
	if rawMax <= 0 then
		if bound and boundDb > 0 then
			return "CLIENT_LOAD_FAIL",
				"SV globals were empty/zero at ADDON_LOADED; jumps appeared later. Forever likely failed to populate WTF into Lua at load (or file was already wiped)."
		end
		return "CLIENT_LOAD_FAIL_OR_WIPED_FILE",
			"SV globals were empty/zero at ADDON_LOADED and still blank after bind. Either Forever failed to load WTF, or the file on disk was already wiped before this session."
	end

	-- Client loaded real progress.
	if rawMax > 0 then
		if bound and boundDb == 0 then
			return "ADDON_BIND_BUG",
				"WTF data WAS present at ADDON_LOADED (max jumps "
					.. tostring(rawMax)
					.. ") but after EnsureDB dbJumps=0. Addon bind poisoned progress."
		end
		if bound and boundDb > 0 and boundDb < rawMax then
			return "ADDON_REGRESSION",
				"Loaded max "
					.. tostring(rawMax)
					.. " from SV but ended at "
					.. tostring(boundDb)
					.. " after EnsureDB (possible bad merge)."
		end
		if bound and boundDb >= rawMax then
			return "OK_CLIENT_LOADED",
				"SV had progress at ADDON_LOADED (max "
					.. tostring(rawMax)
					.. ") and EnsureDB kept/raised it to "
					.. tostring(boundDb)
					.. ". Client load looks fine this session."
		end
		return "OK_CLIENT_LOADED",
			"SV had progress at ADDON_LOADED (max " .. tostring(rawMax) .. "). Bind snapshot missing; check login diag lines."
	end

	return "UNKNOWN", "Could not classify. Paste /ajh diag output."
end

local function DiagReport(tag)
	if not DIAG_ENABLED and tag ~= "manual" then
		return
	end
	local code, detail = DiagVerdict()
	DiagChat("--- " .. (tag or "report") .. " ---")
	DiagChat("VERDICT: " .. code)
	DiagChat(detail)
end

local function ClearAccountProgress()
	EnsureDB()
	AJHDB.jumps = 0
	AJHDB.xp = 0
	if type(AJHAccount) == "table" and type(AJHAccount.__floor) == "table" then
		AJHAccount.__floor.jumps = 0
		AJHAccount.__floor.xp = 0
	end
	if type(AJHFloor) == "table" then
		local key = PlayerKey()
		local name = UnitName("player")
		local guid = UnitGUID("player")
		local function zeroFloor(slot)
			if type(slot) == "string" and type(AJHFloor[slot]) == "table" then
				AJHFloor[slot].jumps = 0
				AJHFloor[slot].xp = 0
			end
		end
		zeroFloor(key)
		zeroFloor(name)
		zeroFloor(guid)
		if type(AJHFloor.__best) == "table" then
			AJHFloor.__best.jumps = 0
			AJHFloor.__best.xp = 0
		end
	end
end

local function GetLevel(xp)
	local level = 1
	while level < MAX_LEVEL and xp >= xpForLevel[level + 1] do
		level = level + 1
	end
	return level
end

-- Forever/Midnight treats auras as secret. Reading them from a tainted
-- JumpOrAscendStart hook throws. Cache on UNIT_AURA instead; jumps only
-- read this flag. Aura APIs are always pcalled so a secret/taint miss
-- fails closed (1x XP) instead of erroring.
local campBenefitActive = false
local campBenefitSpellID

local function AuraNameMatchesCampBenefit(name)
	if type(name) ~= "string" then
		return false
	end
	return strlower(name):find("camp benefit", 1, true) ~= nil
end

local function RememberCampBenefitSpellID(spellID)
	if type(spellID) == "number" and spellID > 0 then
		campBenefitSpellID = spellID
	end
end

local function TryFindCampBenefitByName()
	if not (AuraUtil and AuraUtil.FindAuraByName) then
		return nil
	end
	local name, _, _, _, _, _, _, _, _, spellID = AuraUtil.FindAuraByName("Camp Benefit", "player", "HELPFUL")
	return name, spellID
end

local function TryGetPlayerAuraBySpellID(spellID)
	if not spellID or not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then
		return nil
	end
	return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

local function TryGetAuraDataByIndex(index)
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
		return nil
	end
	return C_UnitAuras.GetAuraDataByIndex("player", index, "HELPFUL")
end

local function TryUnitBuffName(index)
	if not UnitBuff then
		return nil
	end
	return UnitBuff("player", index)
end

local function ScanCampBenefit()
	-- Prefer name lookup; it is the least secret-hostile path.
	local nameOk, name, spellID = pcall(TryFindCampBenefitByName)
	if not nameOk then
		-- Name lookup tainted/secret. Do not iterate auras; try a known
		-- spell ID if we have one, otherwise leave the multiplier off.
		local idOk, data = pcall(TryGetPlayerAuraBySpellID, campBenefitSpellID)
		return idOk and data ~= nil
	end
	if AuraNameMatchesCampBenefit(name) then
		RememberCampBenefitSpellID(spellID)
		return true
	end

	-- Exact name missed. Scan for substring variants, aborting on taint.
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, data = pcall(TryGetAuraDataByIndex, i)
			if not ok then
				return false
			end
			if not data then
				break
			end
			if AuraNameMatchesCampBenefit(data.name) then
				RememberCampBenefitSpellID(data.spellId)
				return true
			end
		end
		return false
	end

	for i = 1, 40 do
		local ok, buffName = pcall(TryUnitBuffName, i)
		if not ok then
			return false
		end
		if not buffName then
			break
		end
		if AuraNameMatchesCampBenefit(buffName) then
			return true
		end
	end

	return false
end

local function RefreshCampBenefit()
	local found = ScanCampBenefit()
	local changed = found ~= campBenefitActive
	campBenefitActive = found
	return changed
end

local function HasCampBenefit()
	return campBenefitActive
end

local function GetJumpXPGain()
	if campBenefitActive then
		return XP_PER_JUMP * CAMP_XP_MULTIPLIER
	end
	return XP_PER_JUMP
end

local function FormatNumber(n)
	local formatted = tostring(math.floor(n + 0.5))
	while true do
		local k
		formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return formatted
end

local function Solid(frame, r, g, b, a)
	frame:SetColorTexture(r, g, b, a)
end

local function PlayerIdentity()
	local name, realm = UnitFullName("player")
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	end
	local key = string.format("%s-%s", name, realm)
	return key, name
end

-- Location feats (English client zone / subzone / minimap names).
-- Each entry: id, display name, match strings, optional mapIDs, optional instanceType.
local CITY_LOCATIONS = {
	{ id = "orgrimmar", name = "Orgrimmar", match = { "orgrimmar" } },
	{ id = "thunder_bluff", name = "Thunder Bluff", match = { "thunder bluff" } },
	{ id = "undercity", name = "Undercity", match = { "undercity" }, mapIDs = { 90 } },
	{ id = "stormwind", name = "Stormwind City", match = { "stormwind city", "stormwind" } },
	{ id = "ironforge", name = "Ironforge", match = { "ironforge" } },
	{ id = "darnassus", name = "Darnassus", match = { "darnassus" } },
}

local TOWN_LOCATIONS = {
	{ id = "brill", name = "Brill", match = { "brill" } },
	{ id = "goldshire", name = "Goldshire", match = { "goldshire" } },
	{ id = "razor_hill", name = "Razor Hill", match = { "razor hill" } },
	{ id = "bloodhoof", name = "Bloodhoof Village", match = { "bloodhoof village" } },
	{ id = "dolanaar", name = "Dolanaar", match = { "dolanaar" } },
	{ id = "kharanos", name = "Kharanos", match = { "kharanos" } },
	{ id = "senjin", name = "Sen'jin Village", match = { "sen'jin village" } },
	{ id = "crossroads", name = "The Crossroads", match = { "the crossroads", "crossroads" } },
	{ id = "tarren_mill", name = "Tarren Mill", match = { "tarren mill" } },
	{ id = "southshore", name = "Southshore", match = { "southshore" } },
	{ id = "booty_bay", name = "Booty Bay", match = { "booty bay" } },
	{ id = "gadgetzan", name = "Gadgetzan", match = { "gadgetzan" } },
	{ id = "everlook", name = "Everlook", match = { "everlook" } },
	{ id = "ratchet", name = "Ratchet", match = { "ratchet" } },
	{ id = "sentinel_hill", name = "Sentinel Hill", match = { "sentinel hill" } },
	{ id = "lakeshire", name = "Lakeshire", match = { "lakeshire" } },
	{ id = "darkshire", name = "Darkshire", match = { "darkshire" } },
	{ id = "menethil", name = "Menethil Harbor", match = { "menethil harbor" } },
	{ id = "theramore", name = "Theramore Isle", match = { "theramore isle", "theramore" } },
	{ id = "astranaar", name = "Astranaar", match = { "astranaar" } },
	{ id = "auberdine", name = "Auberdine", match = { "auberdine" } },
	{ id = "freewind", name = "Freewind Post", match = { "freewind post" } },
	{ id = "camp_taurajo", name = "Camp Taurajo", match = { "camp taurajo" } },
	{ id = "hammerfall", name = "Hammerfall", match = { "hammerfall" } },
	{ id = "revantusk", name = "Revantusk Village", match = { "revantusk village" } },
	{ id = "light_hope", name = "Light's Hope Chapel", match = { "light's hope chapel" } },
	{ id = "cenarion_hold", name = "Cenarion Hold", match = { "cenarion hold" } },
	{ id = "feathermoon", name = "Feathermoon Stronghold", match = { "feathermoon stronghold" } },
	{ id = "nijels_point", name = "Nijel's Point", match = { "nijel's point" } },
	{ id = "stonetalon_peak", name = "Stonetalon Peak", match = { "stonetalon peak" } },
	{ id = "sun_rock", name = "Sun Rock Retreat", match = { "sun rock retreat" } },
	{ id = "splintertree", name = "Splintertree Post", match = { "splintertree post" } },
	{ id = "zorgtars", name = "Zoram'gar Outpost", match = { "zoram'gar outpost" } },
	{ id = "thelsamar", name = "Thelsamar", match = { "thelsamar" } },
	{ id = "refuge_pointe", name = "Refuge Pointe", match = { "refuge pointe" } },
	{ id = "chillwind", name = "Chillwind Camp", match = { "chillwind camp" } },
	{ id = "aerie_peak", name = "Aerie Peak", match = { "aerie peak" } },
}

local DUNGEON_LOCATIONS = {
	-- Classic
	{ id = "rfc", name = "Ragefire Chasm", match = { "ragefire chasm" } },
	{ id = "wc", name = "Wailing Caverns", match = { "wailing caverns" } },
	{ id = "deadmines", name = "The Deadmines", match = { "the deadmines", "deadmines" } },
	{ id = "sfk", name = "Shadowfang Keep", match = { "shadowfang keep" } },
	{ id = "stockade", name = "The Stockade", match = { "the stockade", "stormwind stockade" } },
	{ id = "bfd", name = "Blackfathom Deeps", match = { "blackfathom deeps" } },
	{ id = "gnomeregan", name = "Gnomeregan", match = { "gnomeregan" } },
	{ id = "rfk", name = "Razorfen Kraul", match = { "razorfen kraul" } },
	{ id = "sm_gy", name = "Scarlet Monastery Graveyard", match = { "scarlet monastery graveyard" } },
	{ id = "sm_lib", name = "Scarlet Monastery Library", match = { "scarlet monastery library" } },
	{ id = "sm_arm", name = "Scarlet Monastery Armory", match = { "scarlet monastery armory" } },
	{ id = "sm_cath", name = "Scarlet Monastery Cathedral", match = { "scarlet monastery cathedral" } },
	{ id = "sm", name = "Scarlet Monastery", match = { "scarlet monastery" } },
	{ id = "rfd", name = "Razorfen Downs", match = { "razorfen downs" } },
	{ id = "uldaman", name = "Uldaman", match = { "uldaman" } },
	{ id = "zf", name = "Zul'Farrak", match = { "zul'farrak" } },
	{ id = "maraudon", name = "Maraudon", match = { "maraudon" } },
	{ id = "st", name = "The Temple of Atal'Hakkar", match = { "the temple of atal'hakkar", "sunken temple" } },
	{ id = "brd", name = "Blackrock Depths", match = { "blackrock depths" } },
	{ id = "lbrs", name = "Lower Blackrock Spire", match = { "lower blackrock spire", "blackrock spire" } },
	{ id = "ubrs", name = "Upper Blackrock Spire", match = { "upper blackrock spire" } },
	{ id = "dire_maul", name = "Dire Maul", match = { "dire maul" } },
	{ id = "stratholme", name = "Stratholme", match = { "stratholme" } },
	{ id = "scholomance", name = "Scholomance", match = { "scholomance" } },
}

local RAID_LOCATIONS = {
	{ id = "mc", name = "Molten Core", match = { "molten core" } },
	{ id = "onyxia", name = "Onyxia's Lair", match = { "onyxia's lair" } },
	{ id = "bwl", name = "Blackwing Lair", match = { "blackwing lair" } },
	{ id = "zg", name = "Zul'Gurub", match = { "zul'gurub" } },
	{ id = "aq20", name = "Ruins of Ahn'Qiraj", match = { "ruins of ahn'qiraj" } },
	{ id = "aq40", name = "Temple of Ahn'Qiraj", match = { "temple of ahn'qiraj", "ahn'qiraj" } },
	{ id = "naxx", name = "Naxxramas", match = { "naxxramas" } },
}

local function NormName(s)
	return strlower(strtrim(s or ""))
end

local function GetJumpContext()
	local zone = GetRealZoneText() or GetZoneText() or ""
	local sub = GetSubZoneText() or ""
	local mini = GetMinimapZoneText() or ""
	local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local _, instanceType = IsInInstance()
	instanceType = instanceType or "none"

	local spots = {
		NormName(zone),
		NormName(sub),
		NormName(mini),
	}

	local function inPlace(...)
		for i = 1, select("#", ...) do
			local want = NormName(select(i, ...))
			for _, spot in ipairs(spots) do
				if spot ~= "" and spot == want then
					return true
				end
			end
		end
		return false
	end

	local function matchesLocation(loc)
		if loc.mapIDs and mapID then
			for _, id in ipairs(loc.mapIDs) do
				if mapID == id then
					return true
				end
			end
		end
		for _, name in ipairs(loc.match) do
			if inPlace(name) then
				return true
			end
		end
		return false
	end

	return {
		zone = zone,
		sub = sub,
		mini = mini,
		mapID = mapID,
		instanceType = instanceType,
		inPlace = inPlace,
		matchesLocation = matchesLocation,
	}
end

local function MakeLocationFeat(loc, category, requireInstanceType)
	return {
		id = loc.id,
		category = category,
		name = loc.name,
		desc = "Jump once in " .. loc.name .. ".",
		test = function(ctx)
			if requireInstanceType and ctx.instanceType ~= requireInstanceType then
				return false
			end
			return ctx.matchesLocation(loc)
		end,
	}
end

local ACHIEVEMENTS = {}
for _, loc in ipairs(CITY_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = MakeLocationFeat(loc, "city")
end
for _, loc in ipairs(TOWN_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = MakeLocationFeat(loc, "town")
end
for _, loc in ipairs(DUNGEON_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = MakeLocationFeat(loc, "dungeon", "party")
end
for _, loc in ipairs(RAID_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = MakeLocationFeat(loc, "raid", "raid")
end

local FEAT_CATEGORIES = {
	{ id = "city", name = "City Jumper", desc = "Capital cities." },
	{ id = "town", name = "Town Jumper", desc = "Towns, villages, and outposts." },
	{ id = "dungeon", name = "Dungeon Jumper", desc = "Every dungeon." },
	{ id = "raid", name = "Raid Jumper", desc = "Every raid." },
}

local function GetFeatsInCategory(categoryId)
	local list = {}
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ach.category == categoryId then
			list[#list + 1] = ach
		end
	end
	return list
end

local function CountCategoryProgress(categoryId)
	local total, earned = 0, 0
	EnsureDB()
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ach.category == categoryId then
			total = total + 1
			if AJHDB.achievements[ach.id] then
				earned = earned + 1
			end
		end
	end
	return earned, total
end

local PRIDE_LINES = {
	"Archindula is proud of you.",
	"Archindula nodded. Once.",
	"Archindula filed this under 'acceptable hopping'.",
	"Archindula saw that. He's impressed.",
	"Archindula approves of this vertical lifestyle.",
	"Archindula whispered: 'more jumps, please.'",
	"Archindula has updated your hopping permit.",
	"Archindula clapped. Quietly. Internally.",
	"Archindula rates this jump: solid 7/10.",
	"Archindula says gravity owed you that one.",
	"Archindula almost smiled. Almost.",
	"Archindula logged it in the Book of Bounces.",
	"Archindula declares: 'legs were used correctly.'",
	"Archindula would high-five you, but he's busy.",
	"Archindula recommends stretching. Then more jumps.",
	"Archindula told the guild. They're jealous.",
}


-- Forward declarations (assigned later)
local panel
local activeTab = "habit"
local BroadcastScore
local UpdateAchievements
local UpdateLeaderboard
local UpdateJumpXPBar

local toastFrame
local toastQueue = {}
local toastBusy = false

local function PlayAchievementSound()
	-- Same fanfare as character level-up.
	local played = pcall(function()
		if SOUNDKIT and SOUNDKIT.LEVELUP then
			PlaySound(SOUNDKIT.LEVELUP, "Master")
		elseif SOUNDKIT and SOUNDKIT.LEVEL_UP then
			PlaySound(SOUNDKIT.LEVEL_UP, "Master")
		else
			PlaySound(888, "Master")
		end
	end)
	if not played then
		pcall(PlaySoundFile, "Sound\\Interface\\LevelUp.ogg", "Master")
	end
end

local function EnsureToastFrame()
	if toastFrame then
		return toastFrame
	end

	local f = CreateFrame("Frame", "AJHLevelUpToast", UIParent)
	f:SetSize(560, 200)
	f:SetPoint("TOP", 0, -60)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetFrameLevel(200)
	f:Hide()
	f:SetAlpha(0)

	local function GoldLine(anchor, y)
		local line = f:CreateTexture(nil, "ARTWORK")
		line:SetTexture("Interface\\LevelUp\\LevelUpTex")
		line:SetTexCoord(0.00195313, 0.81835938, 0.01953125, 0.03320313)
		line:SetSize(480, 8)
		line:SetPoint(anchor, 0, y)
		return line
	end

	local topLine = GoldLine("TOP", -58)
	GoldLine("BOTTOM", 58)

	local banner = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	banner:SetPoint("BOTTOM", topLine, "TOP", 0, 8)
	banner:SetTextScale(1.15)
	f.banner = banner

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
	title:SetPoint("CENTER", 0, 0)
	if QuestFont_Super_Huge then
		title:SetFontObject(QuestFont_Super_Huge)
	end
	title:SetTextScale(1.25)
	f.title = title

	local pride = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	pride:SetPoint("TOP", f, "BOTTOM", 0, 50)
	pride:SetWidth(480)
	pride:SetWordWrap(true)
	pride:SetTextScale(1.15)
	f.pride = pride
	f.detail = pride

	toastFrame = f
	return f
end

local function ShowNextToast()
	if toastBusy then
		return
	end
	local toast = tremove(toastQueue, 1)
	if not toast then
		return
	end

	toastBusy = true
	local f = EnsureToastFrame()
	f.banner:SetText(toast.banner or "FEAT UNLOCKED")
	f.title:SetText(toast.name or "")
	f.pride:SetText(PRIDE_LINES[math.random(1, #PRIDE_LINES)])

	PlayAchievementSound()

	f:Show()
	f:SetAlpha(0)
	f:SetScale(0.85)

	local elapsed = 0
	local fadeIn = 0.45
	local holdUntil = 7.0
	local fadeOut = 1.5
	local total = holdUntil + fadeOut

	f:SetScript("OnUpdate", function(self, dt)
		elapsed = elapsed + dt
		if elapsed < fadeIn then
			local t = elapsed / fadeIn
			self:SetAlpha(t)
			self:SetScale(0.88 + 0.12 * t)
		elseif elapsed < holdUntil then
			self:SetAlpha(1)
			self:SetScale(1)
		elseif elapsed < total then
			local t = (elapsed - holdUntil) / fadeOut
			self:SetAlpha(1 - t)
		else
			self:SetScript("OnUpdate", nil)
			self:Hide()
			toastBusy = false
			ShowNextToast()
		end
	end)
end

local function QueueToast(toast)
	tinsert(toastQueue, toast)
	ShowNextToast()
end

local function QueueAchievementToast(ach)
	QueueToast({
		banner = "FEAT UNLOCKED",
		name = ach.name,
		desc = ach.desc,
	})
end

local function AnnounceLevelUp(newLevel)
	DEFAULT_CHAT_FRAME:AddMessage(string.format(
		"|cff88ff88AJH:|r Congratulations! Your Jump Habit is now level %d.",
		newLevel
	))

	local detail
	if newLevel == MAX_LEVEL then
		detail = "You've reached the legendary level 99!"
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r You've reached the legendary level 99!")
	else
		detail = PRIDE_LINES[math.random(1, #PRIDE_LINES)]
	end

	QueueToast({
		banner = "YOUR JUMP HABIT",
		name = string.format("IS NOW LEVEL %d!", newLevel),
		desc = detail,
	})
end

local function GetAchievementMask()
	EnsureDB()
	local mask = 0
	for i, ach in ipairs(ACHIEVEMENTS) do
		if AJHDB.achievements[ach.id] then
			mask = mask + (2 ^ (i - 1))
		end
	end
	return mask
end

local function CountAchievementsFromMask(mask)
	mask = tonumber(mask) or 0
	local n = 0
	for i = 1, #ACHIEVEMENTS do
		local bitv = 2 ^ (i - 1)
		if math.floor(mask / bitv) % 2 == 1 then
			n = n + 1
		end
	end
	return n
end

local function CountOwnAchievements()
	EnsureDB()
	local n = 0
	for _, ach in ipairs(ACHIEVEMENTS) do
		if AJHDB.achievements[ach.id] then
			n = n + 1
		end
	end
	return n
end

local function UnlockAchievement(ach)
	EnsureDB()
	if AJHDB.achievements[ach.id] then
		return false
	end

	AJHDB.achievements[ach.id] = time()
	CommitFloor()
	DEFAULT_CHAT_FRAME:AddMessage(string.format(
		"|cff88ff88AJH:|r Feat unlocked: |cffffffff%s|r - %s",
		ach.name,
		ach.desc
	))

	QueueAchievementToast(ach)

	if IsInGuild() then
		SendChatMessage(
			string.format("Jump Habit Feat: %s - %s", ach.name, ach.desc),
			"GUILD"
		)
	end

	BroadcastScore()
	return true
end

local function CheckAchievementsOnJump()
	local ctx = GetJumpContext()
	local earned = false
	for _, ach in ipairs(ACHIEVEMENTS) do
		if not AJHDB.achievements[ach.id] and ach.test(ctx) then
			if UnlockAchievement(ach) then
				earned = true
			end
		end
	end
	return earned
end

local function ResetAchievements()
	EnsureDB()
	AJHDB.achievements = {}
	BroadcastScore()
	DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Feats reset for testing.")
	if panel and panel:IsShown() then
		if activeTab == "achieves" then
			UpdateAchievements()
		elseif activeTab == "guild" then
			UpdateLeaderboard()
		end
	end
end

local ui = {
	tabs = {},
	pages = {},
	levelRows = {},
	boardRows = {},
	achRows = {},
	featCatRows = {},
	featView = "categories", -- "categories" or a FEAT_CATEGORIES id
}
local lastGuildReply = 0
local jumpXPBar
local JUMP_XP_BAR_HEIGHT = 14

local function IsEditModeActive()
	if LibEditMode and LibEditMode.IsInEditMode then
		return LibEditMode:IsInEditMode()
	end
	return EditModeManagerFrame and EditModeManagerFrame:IsShown()
end

local function TrySetAtlas(texture, atlas)
	if not texture or not atlas then
		return false
	end
	if C_Texture and C_Texture.GetAtlasInfo then
		local info = C_Texture.GetAtlasInfo(atlas)
		if not info then
			return false
		end
	end
	return pcall(texture.SetAtlas, texture, atlas, true)
end

local function MatchDefaultStatusBarWidth()
	-- Use on-screen span (GetRight-GetLeft) so we match the visible XP / status
	-- bar even when GetWidth() is stale, scaled, or a half-size fallback.
	-- Do NOT fall back to MainMenuBar / UIParent — those are much wider than the
	-- XP bar, so a saved 50% looked like ~100% after /reload.
	local function Span(frame)
		if not frame then
			return nil
		end
		local left, right = frame:GetLeft(), frame:GetRight()
		if left and right then
			local span = right - left
			if span > 100 then
				return span
			end
		end
		if frame.GetWidth then
			local w = frame:GetWidth()
			if w and w > 100 then
				return w
			end
		end
		return nil
	end

	local candidates = {
		MainStatusTrackingBarContainer,
		StatusTrackingBarManager and StatusTrackingBarManager.MainStatusTrackingBarContainer,
		StatusTrackingBarManager and StatusTrackingBarManager.SecondaryStatusTrackingBarContainer,
	}

	local best
	for _, frame in ipairs(candidates) do
		local w = Span(frame)
		if w and (not best or w > best) then
			best = w
		end
	end

	if StatusTrackingBarManager and StatusTrackingBarManager.GetChildren then
		local children = { StatusTrackingBarManager:GetChildren() }
		for _, child in ipairs(children) do
			local w = Span(child)
			if w and (not best or w > best) then
				best = w
			end
		end
	end

	if best then
		return best
	end
	return 804
end

local function DefaultJumpXPBarOffsetY()
	local container = MainStatusTrackingBarContainer
	if not container and StatusTrackingBarManager then
		container = StatusTrackingBarManager.MainStatusTrackingBarContainer
	end
	if container and container.GetTop then
		local top = container:GetTop()
		if top then
			return top + 2
		end
	end
	if MainMenuBar and MainMenuBar.GetTop then
		local top = MainMenuBar:GetTop()
		if top then
			return top + 2
		end
	end
	return 55
end

local JUMP_XP_BAR_DEFAULT = {
	point = "BOTTOM",
	x = 0,
	y = 55,
	widthPct = 100,
}

-- Live Edit Mode draft (nil outside a dirty edit session).
local jumpXPBarDraft
local jumpXPBarBaseline
local jumpXPBarEditDirty = false

local function CopyJumpXPBarState(src)
	return {
		shown = not not (src and src.shown),
		point = (src and src.point) or JUMP_XP_BAR_DEFAULT.point,
		x = ToNumberOr(src and src.x, JUMP_XP_BAR_DEFAULT.x) or JUMP_XP_BAR_DEFAULT.x,
		y = ToNumberOr(src and src.y, JUMP_XP_BAR_DEFAULT.y) or JUMP_XP_BAR_DEFAULT.y,
		widthPct = ToNumberOr(src and src.widthPct, JUMP_XP_BAR_DEFAULT.widthPct) or JUMP_XP_BAR_DEFAULT.widthPct,
		userPlaced = not not (src and src.userPlaced),
	}
end

local function GetJumpXPBarSaved()
	EnsureDB()
	local barDB = AJHDB.jumpXPBar
	barDB.point = type(barDB.point) == "string" and barDB.point or JUMP_XP_BAR_DEFAULT.point
	barDB.x = ToNumberOr(barDB.x, JUMP_XP_BAR_DEFAULT.x) or JUMP_XP_BAR_DEFAULT.x
	barDB.y = ToNumberOr(barDB.y, JUMP_XP_BAR_DEFAULT.y) or JUMP_XP_BAR_DEFAULT.y
	barDB.widthPct = ToNumberOr(barDB.widthPct, 100) or 100
	if barDB.widthPct < 50 then
		barDB.widthPct = 50
	elseif barDB.widthPct > 100 then
		barDB.widthPct = 100
	end
	barDB.shown = not not barDB.shown
	AJHDB.showJumpXPBar = barDB.shown
	return barDB
end

local function GetJumpXPBarState()
	if jumpXPBarDraft then
		return jumpXPBarDraft
	end
	return GetJumpXPBarSaved()
end

local function ApplyJumpXPBarLayout(holder, state)
	if not holder then
		return
	end
	state = state or GetJumpXPBarState()
	local full = MatchDefaultStatusBarWidth()
	local widthPct = ToNumberOr(state.widthPct, 100) or 100
	if widthPct < 50 then
		widthPct = 50
	elseif widthPct > 100 then
		widthPct = 100
	end
	local width = full * (widthPct / 100)
	local point = (type(state.point) == "string" and state.point) or "BOTTOM"
	local x = ToNumberOr(state.x, 0) or 0
	local y = ToNumberOr(state.y, 55) or 55
	holder:SetSize(width, JUMP_XP_BAR_HEIGHT)
	holder:ClearAllPoints()
	holder:SetPoint(point, UIParent, point, x, y)
	if holder.LayoutChrome then
		holder:LayoutChrome()
	end
end

local function RestoreJumpXPBarFromSaved()
	if not jumpXPBar then
		return
	end
	JUMP_XP_BAR_DEFAULT.y = DefaultJumpXPBarOffsetY()
	ApplyJumpXPBarLayout(jumpXPBar, GetJumpXPBarSaved())
	UpdateJumpXPBar()
end

local function CommitJumpXPBarState(state, opts)
	EnsureDB()
	state = state or GetJumpXPBarState()
	opts = opts or {}
	local barDB = AJHDB.jumpXPBar

	-- Visibility always updates (hide button must work).
	if state.shown ~= nil then
		barDB.shown = not not state.shown
		AJHDB.showJumpXPBar = barDB.shown
	end

	if opts.visibilityOnly then
		return
	end

	local proposed = {
		shown = barDB.shown,
		point = state.point or barDB.point or "BOTTOM",
		x = tonumber(state.x)
			or ToNumberOr(barDB.x, 0)
			or 0,
		y = tonumber(state.y)
			or ToNumberOr(barDB.y, 55)
			or 55,
		widthPct = tonumber(state.widthPct)
			or ToNumberOr(barDB.widthPct, 100)
			or 100,
		userPlaced = not not (state.userPlaced or barDB.userPlaced),
	}
	if proposed.widthPct < 50 then
		proposed.widthPct = 50
	elseif proposed.widthPct > 100 then
		proposed.widthPct = 100
	end

	-- Raise-only for position/size. Defaults cannot replace a customized bar.
	if JumpXPBarLayoutScore(proposed) < JumpXPBarLayoutScore(barDB) then
		return
	end
	-- Ignore non-userPlaced writes that look like Edit Mode defaults when we
	-- already have any customized layout saved.
	if not proposed.userPlaced and JumpXPBarLayoutScore(barDB) > 0 then
		return
	end

	barDB.point = proposed.point
	barDB.x = proposed.x
	barDB.y = proposed.y
	barDB.widthPct = proposed.widthPct
	if proposed.userPlaced then
		barDB.userPlaced = true
	end

	if type(AJHDB.jumpXPBarLayouts) ~= "table" then
		AJHDB.jumpXPBarLayouts = {}
	end
	-- Only snapshot into Edit Mode layouts when the player actually placed it.
	if barDB.userPlaced then
		local layoutName = "Modern"
		if LibEditMode and LibEditMode.GetActiveLayoutName then
			layoutName = LibEditMode:GetActiveLayoutName() or layoutName
		end
		local layoutCopy = CopyJumpXPBarState(barDB)
		local existingLayout = AJHDB.jumpXPBarLayouts[layoutName]
		if JumpXPBarLayoutScore(layoutCopy) >= JumpXPBarLayoutScore(existingLayout) then
			AJHDB.jumpXPBarLayouts[layoutName] = layoutCopy
		end
	end

	if ToNumberOr(AJHDB.jumps, 0) > 0 then
		CommitFloor()
	end
end

local function PersistJumpXPBarDraft()
	if jumpXPBarDraft and jumpXPBarEditDirty then
		CommitJumpXPBarState(jumpXPBarDraft)
	end
end

local function MarkJumpXPBarEditDirty()
	if not IsEditModeActive() then
		return
	end
	jumpXPBarEditDirty = true
	PersistJumpXPBarDraft()
	if EditModeManagerFrame and EditModeManagerFrame.SetHasActiveChanges then
		pcall(EditModeManagerFrame.SetHasActiveChanges, EditModeManagerFrame, true)
	end
end

local function BeginJumpXPBarEditSession()
	EnsureDB()
	local saved = GetJumpXPBarSaved()
	jumpXPBarBaseline = CopyJumpXPBarState(saved)
	jumpXPBarDraft = CopyJumpXPBarState(saved)
	jumpXPBarEditDirty = false
end

local function CommitJumpXPBarEditSession()
	if not jumpXPBarDraft then
		return
	end
	if jumpXPBarEditDirty then
		jumpXPBarDraft.shown = true
		jumpXPBarDraft.userPlaced = true
		CommitJumpXPBarState(jumpXPBarDraft)
	end
	jumpXPBarBaseline = CopyJumpXPBarState(jumpXPBarDraft)
	jumpXPBarDraft = CopyJumpXPBarState(jumpXPBarDraft)
	jumpXPBarEditDirty = false
	UpdateJumpXPBar()
end

local function RevertJumpXPBarEditSession()
	if not jumpXPBarBaseline then
		jumpXPBarDraft = nil
		jumpXPBarEditDirty = false
		return
	end
	jumpXPBarDraft = CopyJumpXPBarState(jumpXPBarBaseline)
	jumpXPBarEditDirty = false
	if jumpXPBar then
		ApplyJumpXPBarLayout(jumpXPBar, jumpXPBarDraft)
	end
	UpdateJumpXPBar()
end

local function EndJumpXPBarEditSession()
	if jumpXPBarDraft and jumpXPBarEditDirty then
		jumpXPBarDraft.shown = true
		jumpXPBarDraft.userPlaced = true
		CommitJumpXPBarState(jumpXPBarDraft)
	end
	jumpXPBarDraft = nil
	jumpXPBarBaseline = nil
	jumpXPBarEditDirty = false
	UpdateJumpXPBar()
end

local function UpdateJumpXPBarToggleLabel()
	if not ui.jumpXPBarToggle then
		return
	end
	local state = GetJumpXPBarSaved()
	if state.shown then
		ui.jumpXPBarToggle:SetText("Hide XP Bar")
	else
		ui.jumpXPBarToggle:SetText("Show XP Bar")
	end
end

UpdateJumpXPBar = function()
	EnsureDB()
	UpdateJumpXPBarToggleLabel()
	if not jumpXPBar then
		return
	end

	local state = GetJumpXPBarState()
	local editing = IsEditModeActive()
	if not state.shown and not editing then
		jumpXPBar:Hide()
		return
	end

	if not jumpXPBar.isMoving then
		ApplyJumpXPBarLayout(jumpXPBar, state)
	end

	local xp = AJHDB.xp
	local jumps = AJHDB.jumps
	local level = GetLevel(xp)
	local intoLevel, needed, remaining, pct

	if level >= MAX_LEVEL then
		intoLevel = xp - xpForLevel[MAX_LEVEL]
		needed = 1
		remaining = 0
		pct = 100
		jumpXPBar.bar:SetMinMaxValues(0, 1)
		jumpXPBar.bar:SetValue(1)
		jumpXPBar.text:SetText(string.format("Level %d  MAX", level))
	else
		intoLevel = xp - xpForLevel[level]
		needed = xpForLevel[level + 1] - xpForLevel[level]
		remaining = needed - intoLevel
		pct = needed > 0 and math.floor((intoLevel / needed) * 100 + 0.5) or 0
		jumpXPBar.bar:SetMinMaxValues(0, needed)
		jumpXPBar.bar:SetValue(intoLevel)
		jumpXPBar.text:SetText(string.format("Level %d  %d%%", level, pct))
	end

	jumpXPBar.tipLevel = level
	jumpXPBar.tipInto = intoLevel
	jumpXPBar.tipNeeded = needed
	jumpXPBar.tipRemaining = remaining
	jumpXPBar.tipJumps = jumps
	jumpXPBar.tipMax = level >= MAX_LEVEL

	if editing and not state.shown then
		jumpXPBar:SetAlpha(0.65)
	else
		jumpXPBar:SetAlpha(1)
	end
	jumpXPBar:Show()
end

local function SetJumpXPBarShown(shown)
	EnsureDB()
	local state = GetJumpXPBarState()
	state.shown = not not shown
	-- Visibility only — never touch position/size (and never block hide).
	CommitJumpXPBarState(state, { visibilityOnly = true })
	if jumpXPBarDraft then
		jumpXPBarDraft.shown = state.shown
	end
	UpdateJumpXPBar()
end

local function SetupJumpXPBarEditMode(holder)
	if holder.editModeReady or not LibEditMode then
		return
	end
	holder.editModeReady = true
	holder.editModeName = "Jump Habit XP Bar"

	JUMP_XP_BAR_DEFAULT.y = DefaultJumpXPBarOffsetY()

	LibEditMode:AddFrame(holder, function(frame, _layoutName, point, x, y)
		-- Ignore spurious callbacks outside Edit Mode (would lock in defaults).
		if not IsEditModeActive() then
			ApplyJumpXPBarLayout(frame, GetJumpXPBarSaved())
			return
		end
		local state = GetJumpXPBarState()
		state.point, state.x, state.y = point, x, y
		state.shown = true
		state.userPlaced = true
		if jumpXPBarDraft then
			MarkJumpXPBarEditDirty()
		else
			CommitJumpXPBarState(state)
		end
		frame:ClearAllPoints()
		frame:SetPoint(point, UIParent, point, x, y)
	end, JUMP_XP_BAR_DEFAULT, "Jump Habit XP Bar")

	LibEditMode:AddFrameSettings(holder, {
		{
			kind = LibEditMode.SettingType.Slider,
			name = "Width",
			desc = "Width relative to the default experience / status bar (50%-100%).",
			default = 100,
			minValue = 50,
			maxValue = 100,
			valueStep = 1,
			formatter = function(value)
				return string.format("%d%%", value)
			end,
			get = function()
				return GetJumpXPBarState().widthPct
			end,
			set = function(_layoutName, value, _fromReset)
				if not IsEditModeActive() and not _fromReset then
					return
				end
				-- Ignore Reset-to-default while we already have a custom layout.
				if _fromReset and GetJumpXPBarSaved().userPlaced then
					return
				end
				local state = GetJumpXPBarState()
				state.widthPct = value
				state.shown = true
				state.userPlaced = true
				if jumpXPBarDraft then
					MarkJumpXPBarEditDirty()
				else
					CommitJumpXPBarState(state)
				end
				if jumpXPBar then
					ApplyJumpXPBarLayout(jumpXPBar, state)
				end
			end,
		},
	})

	LibEditMode:RegisterCallback("enter", function()
		EnsureDB()
		BeginJumpXPBarEditSession()
		UpdateJumpXPBar()
	end)

	LibEditMode:RegisterCallback("exit", function()
		EndJumpXPBarEditSession()
	end)

	-- Edit Mode layout info arrives after ADDON_LOADED; re-apply saved bar then.
	LibEditMode:RegisterCallback("layout", function()
		RestoreJumpXPBarFromSaved()
	end)

	-- Blizzard Save / Revert All Changes (retry until EditModeManagerFrame exists).
	local function HookEditModeSaveRevert()
		if holder._ajhSaveHooked then
			return true
		end
		if not EditModeManagerFrame then
			return false
		end
		holder._ajhSaveHooked = true
		if EditModeManagerFrame.SaveLayouts then
			hooksecurefunc(EditModeManagerFrame, "SaveLayouts", function()
				CommitJumpXPBarEditSession()
			end)
		end
		if EditModeManagerFrame.RevertAllChanges then
			hooksecurefunc(EditModeManagerFrame, "RevertAllChanges", function()
				RevertJumpXPBarEditSession()
			end)
		end
		EventRegistry:RegisterCallback("EditMode.SavedLayouts", function()
			CommitJumpXPBarEditSession()
		end)
		return true
	end
	if not HookEditModeSaveRevert() then
		local waiter = CreateFrame("Frame")
		waiter:RegisterEvent("PLAYER_LOGIN")
		waiter:RegisterEvent("ADDON_LOADED")
		waiter:SetScript("OnEvent", function(self)
			if HookEditModeSaveRevert() then
				self:UnregisterAllEvents()
				self:SetScript("OnEvent", nil)
			end
		end)
	end

	RestoreJumpXPBarFromSaved()
end

local function BuildJumpXPBar()
	if jumpXPBar then
		return jumpXPBar
	end

	EnsureDB()

	-- Status-tracking XP chrome (HUD atlases) with classic UI-XP-Bar fallback.
	local holder = CreateFrame("Frame", "AJHJumpXPBar", UIParent)
	holder:SetFrameStrata("MEDIUM")
	holder:SetFrameLevel(50)
	holder:EnableMouse(true)
	holder:Hide()

	local barBg = holder:CreateTexture(nil, "BACKGROUND", nil, -1)
	barBg:SetPoint("TOPLEFT", 1, -1)
	barBg:SetPoint("BOTTOMRIGHT", -1, 1)
	local usedHudBg = TrySetAtlas(barBg, "UI-HUD-ExperienceBar-Background")
	if not usedHudBg then
		barBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
		barBg:SetVertexColor(0.0, 0.0, 0.0, 0.55)
	end

	local bar = CreateFrame("StatusBar", nil, holder)
	bar:SetPoint("TOPLEFT", 3, -3)
	bar:SetPoint("BOTTOMRIGHT", -3, 3)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	local fillOk = false
	local statusTex = bar:CreateTexture(nil, "ARTWORK")
	bar:SetStatusBarTexture(statusTex)
	if TrySetAtlas(statusTex, "UI-HUD-ExperienceBar-Fill-Honor") then
		fillOk = true
		bar:SetStatusBarColor(1, 1, 1)
	elseif TrySetAtlas(statusTex, "UI-HUD-ExperienceBar-Fill") then
		fillOk = true
		statusTex:SetVertexColor(1.0, 0.55, 0.05)
		bar:SetStatusBarColor(1, 1, 1)
	end
	if not fillOk then
		bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
		local tex = bar:GetStatusBarTexture()
		if tex then
			tex:SetHorizTile(false)
		end
		bar:SetStatusBarColor(1.0, 0.50, 0.0)
	end

	local hudFrame = holder:CreateTexture(nil, "OVERLAY", nil, 7)
	hudFrame:SetAllPoints()
	local usedHudFrame = TrySetAtlas(hudFrame, "UI-HUD-ExperienceBar-Frame")
	if usedHudFrame then
		holder.useClassicChrome = false
	else
		hudFrame:Hide()
		holder.useClassicChrome = true

		local borderLeft = holder:CreateTexture(nil, "OVERLAY", nil, 7)
		borderLeft:SetTexture("Interface\\MainMenuBar\\UI-XP-Bar")
		borderLeft:SetSize(14, 14)
		borderLeft:SetPoint("LEFT", holder, "LEFT", -3, 0)
		borderLeft:SetTexCoord(0.015625, 0.234375, 0.015625, 0.234375)

		local borderRight = holder:CreateTexture(nil, "OVERLAY", nil, 7)
		borderRight:SetTexture("Interface\\MainMenuBar\\UI-XP-Bar")
		borderRight:SetSize(14, 14)
		borderRight:SetPoint("RIGHT", holder, "RIGHT", 3, 0)
		borderRight:SetTexCoord(0.765625, 0.984375, 0.015625, 0.234375)

		local borderMid = holder:CreateTexture(nil, "OVERLAY", nil, 6)
		borderMid:SetTexture("Interface\\MainMenuBar\\UI-XP-Bar")
		borderMid:SetPoint("LEFT", borderLeft, "RIGHT", -4, 0)
		borderMid:SetPoint("RIGHT", borderRight, "LEFT", 4, 0)
		borderMid:SetHeight(14)
		borderMid:SetTexCoord(0.234375, 0.765625, 0.015625, 0.234375)

		holder.divs = {}
		for i = 1, 19 do
			local div = holder:CreateTexture(nil, "OVERLAY", nil, 5)
			div:SetTexture("Interface\\MainMenuBar\\UI-XP-Bar")
			div:SetSize(9, 9)
			div:SetTexCoord(0.015625, 0.15625, 0.015625, 0.171875)
			holder.divs[i] = div
		end
	end

	function holder:LayoutChrome()
		if not self.divs then
			return
		end
		local width = self:GetWidth()
		if not width or width <= 0 then
			return
		end
		local divWidth = width / 20
		local xpos = divWidth - 4.5
		for i = 1, 19 do
			local div = self.divs[i]
			div:ClearAllPoints()
			div:SetPoint("LEFT", self, "LEFT", math.floor(xpos), 1)
			xpos = xpos + divWidth
		end
	end

	local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	if TextStatusBarText then
		text:SetFontObject(TextStatusBarText)
	end
	text:SetPoint("CENTER", holder, "CENTER", 0, 0)

	holder:SetScript("OnEnter", function(self)
		if IsEditModeActive() then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Jump Habit Experience", 1.0, 0.82, 0.0)
		if self.tipMax then
			GameTooltip:AddLine(string.format("Level %d (max)", self.tipLevel or MAX_LEVEL), 1, 1, 1)
			GameTooltip:AddLine(
				string.format("XP past max: %s", FormatNumber(self.tipInto or 0)),
				0.9, 0.9, 0.9
			)
		else
			GameTooltip:AddLine(string.format("Level %d", self.tipLevel or 1), 1, 1, 1)
			GameTooltip:AddLine(
				string.format(
					"%s / %s XP this level",
					FormatNumber(self.tipInto or 0),
					FormatNumber(self.tipNeeded or 0)
				),
				0.9, 0.9, 0.9
			)
			GameTooltip:AddLine(
				string.format("%s XP remaining", FormatNumber(self.tipRemaining or 0)),
				0.9, 0.9, 0.9
			)
		end
		GameTooltip:AddLine(
			string.format("Total jumps: %s", FormatNumber(self.tipJumps or 0)),
			0.7, 0.7, 0.7
		)
		GameTooltip:AddLine("Edit Mode: move, width, and reset", 0.55, 0.55, 0.55)
		GameTooltip:Show()
	end)
	holder:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	holder:SetScript("OnSizeChanged", function(self)
		if self.LayoutChrome then
			self:LayoutChrome()
		end
	end)

	holder.bar = bar
	holder.text = text
	jumpXPBar = holder

	ApplyJumpXPBarLayout(holder)
	SetupJumpXPBarEditMode(holder)
	UpdateJumpXPBar()
	return holder
end

local function StoreScore(key, name, jumps, achMask, xp)
	EnsureDB()
	if type(AJHDB) ~= "table" then
		return
	end
	if type(AJHDB.board) ~= "table" then
		AJHDB.board = {}
	end
	local jumpsN = tonumber(jumps) or 0
	local xpN = tonumber(xp)
	if not xpN or xpN < 0 then
		-- Legacy peers only sent jumps; approximate XP from jumps.
		xpN = jumpsN
	end
	local prev = AJHDB.board[key]
	-- Raise-only so a stale broadcast cannot demote a richer row.
	if type(prev) == "table" then
		if ToNumberOr(prev.jumps, 0) > jumpsN then
			jumpsN = ToNumberOr(prev.jumps, 0)
		end
		if ToNumberOr(prev.xp, 0) > xpN then
			xpN = ToNumberOr(prev.xp, 0)
		end
	end
	AJHDB.board[key] = {
		name = name or (type(prev) == "table" and prev.name) or key,
		jumps = jumpsN,
		xp = xpN,
		achMask = tonumber(achMask) or (type(prev) == "table" and prev.achMask) or 0,
		updated = time(),
	}
end

local function SendGuildAddonMessage(message)
	if not IsInGuild() then
		return false, "not-in-guild"
	end
	local ok, result = pcall(function()
		if C_ChatInfo and C_ChatInfo.SendAddonMessage then
			return C_ChatInfo.SendAddonMessage(ADDON_PREFIX, message, "GUILD")
		end
		if SendAddonMessage then
			return SendAddonMessage(ADDON_PREFIX, message, "GUILD")
		end
		return "no-api"
	end)
	if not ok then
		return false, result
	end
	-- Modern clients return an enum; 0 / Success / nil usually means ok.
	if result == false or result == "no-api" then
		return false, result
	end
	if type(result) == "number" and result ~= 0 then
		-- Non-zero enums are often failure codes (varies by client).
		-- Still try whispers below; report the code for /ajh guild.
		return false, result
	end
	return true, result
end

local function SendWhisperAddonMessage(message, target)
	if type(target) ~= "string" or target == "" then
		return false
	end
	local ok, result = pcall(function()
		if C_ChatInfo and C_ChatInfo.SendAddonMessage then
			return C_ChatInfo.SendAddonMessage(ADDON_PREFIX, message, "WHISPER", target)
		end
		if SendAddonMessage then
			return SendAddonMessage(ADDON_PREFIX, message, "WHISPER", target)
		end
		return false
	end)
	return ok and result ~= false, result
end

local lastGuildSyncNote = "not-run"
local lastGuildRecvNote = "none"
local lastGuildSendNote = "none"

local function IterOnlineGuildNames()
	local names = {}
	if not IsInGuild() then
		return names
	end
	if GuildRoster then
		pcall(GuildRoster)
	end
	local total = GetNumGuildMembers and GetNumGuildMembers() or 0
	local myName = UnitName("player")
	for i = 1, total do
		local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		if online and type(name) == "string" and name ~= "" then
			local short = Ambiguate(name, "short")
			if short ~= myName then
				names[#names + 1] = Ambiguate(name, "none") or name
			end
		end
	end
	return names
end

local function BroadcastScorePayload(message)
	local guildOk, guildResult = SendGuildAddonMessage(message)
	local whispered = 0
	local whisperFail = 0
	for _, target in ipairs(IterOnlineGuildNames()) do
		local wOk = SendWhisperAddonMessage(message, target)
		if wOk then
			whispered = whispered + 1
		else
			whisperFail = whisperFail + 1
		end
	end
	lastGuildSendNote = string.format(
		"guildOk=%s result=%s whispered=%d fail=%d",
		tostring(guildOk),
		tostring(guildResult),
		whispered,
		whisperFail
	)
	return guildOk or whispered > 0
end

local function IsAjhAddonChannel(channel)
	if channel == nil or channel == "GUILD" or channel == "OFFICER" or channel == "WHISPER" then
		return true
	end
	if type(channel) == "number" then
		return true
	end
	if type(channel) == "string" then
		local upper = strupper(channel)
		if upper == "GUILD" or upper == "OFFICER" or upper == "WHISPER"
			or upper == "PARTY" or upper == "RAID" or upper == "INSTANCE_CHAT"
		then
			return true
		end
		if upper == "SAY" or upper == "YELL" then
			return false
		end
		return upper:find("GUILD", 1, true) ~= nil
			or upper:find("WHISPER", 1, true) ~= nil
			or upper:find("PARTY", 1, true) ~= nil
			or upper:find("RAID", 1, true) ~= nil
	end
	return false
end

BroadcastScore = function()
	if not IsInGuild() then
		lastGuildSyncNote = "skip-not-in-guild"
		return
	end
	EnsureDB()
	if type(AJHDB) ~= "table" then
		lastGuildSyncNote = "skip-no-db"
		return
	end
	local key, name = PlayerIdentity()
	if not key then
		lastGuildSyncNote = "skip-no-identity"
		return
	end
	local mask = GetAchievementMask()
	local jumps = ToNumberOr(AJHDB.jumps, 0)
	local xp = ToNumberOr(AJHDB.xp, 0)
	StoreScore(key, name, jumps, mask, xp)
	-- One legacy + one extended on GUILD; whispers only send legacy once (throttle).
	SendGuildAddonMessage(string.format("S:%d:%d", jumps, mask))
	SendGuildAddonMessage(string.format("X:%d:%d:%d", jumps, mask, xp))
	local whispered = 0
	local whisperFail = 0
	local legacy = string.format("S:%d:%d", jumps, mask)
	for _, target in ipairs(IterOnlineGuildNames()) do
		if SendWhisperAddonMessage(legacy, target) then
			whispered = whispered + 1
		else
			whisperFail = whisperFail + 1
		end
		-- Extended XP for peers on this build.
		SendWhisperAddonMessage(string.format("X:%d:%d:%d", jumps, mask, xp), target)
	end
	-- Also party/raid if grouped with them.
	if IsInGroup and IsInGroup() then
		pcall(function()
			local chatType = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
			if C_ChatInfo and C_ChatInfo.SendAddonMessage then
				C_ChatInfo.SendAddonMessage(ADDON_PREFIX, legacy, chatType)
				C_ChatInfo.SendAddonMessage(ADDON_PREFIX, string.format("X:%d:%d:%d", jumps, mask, xp), chatType)
			end
		end)
	end
	lastGuildSendNote = string.format("whispered=%d fail=%d onlinePeers=%d", whispered, whisperFail, #IterOnlineGuildNames())
	lastGuildSyncNote = "broadcast " .. lastGuildSendNote
end

local function RequestGuildScores()
	if not IsInGuild() then
		lastGuildSyncNote = "request-not-in-guild"
		return
	end
	BroadcastScore()
	SendGuildAddonMessage("R")
	local asked = 0
	for _, target in ipairs(IterOnlineGuildNames()) do
		if SendWhisperAddonMessage("R", target) then
			asked = asked + 1
		end
	end
	lastGuildSyncNote = string.format("request whisperedR=%d %s", asked, lastGuildSendNote)
end

local function CreateStatRow(parent, anchor, y)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", anchor, "TOPLEFT", 16, y)

	local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	value:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -16, y)

	return label, value
end

local function CreateScrollArea(parent)
	local wrap = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
	wrap:SetPoint("TOPLEFT", 4, -4)
	wrap:SetPoint("BOTTOMRIGHT", -4, 4)

	local scroll = CreateFrame("ScrollFrame", nil, wrap, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)

	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)

	return wrap, scroll, child
end

local function PlayUISound(kit, fallback)
	if SOUNDKIT and SOUNDKIT[kit] then
		PlaySound(SOUNDKIT[kit], "SFX")
	else
		PlaySound(fallback, "SFX")
	end
end

local function ScrollLevelsToCurrent(level)
	local scroll = ui.levelScroll
	local child = ui.levelChild
	if not scroll or not child or not level then
		return
	end
	-- Row tops sit at 20 + (level-1)*ROW_HEIGHT inside the scroll child.
	local rowTop = 20 + (level - 1) * ROW_HEIGHT
	local rowCenter = rowTop + (ROW_HEIGHT / 2)
	local viewH = scroll:GetHeight() or 0
	local childH = child:GetHeight() or 0
	if viewH <= 0 then
		return
	end
	local maxScroll = math.max(0, childH - viewH)
	local target = rowCenter - (viewH / 2)
	if target < 0 then
		target = 0
	elseif target > maxScroll then
		target = maxScroll
	end
	scroll:SetVerticalScroll(target)
end

local function SetTab(id, silent)
	local changed = activeTab ~= id
	activeTab = id
	for tabId, page in pairs(ui.pages) do
		page:SetShown(tabId == id)
	end
	if panel and ui.tabIndex and ui.tabIndex[id] then
		PanelTemplates_SetTab(panel, ui.tabIndex[id])
	end
	if id == "guild" then
		RequestGuildScores()
	end
	if panel then
		panel:Update()
	end
	if id == "levels" then
		EnsureDB()
		local level = GetLevel(AJHDB.xp)
		-- Defer until the scroll frame has a real height after Show().
		C_Timer.After(0, function()
			ScrollLevelsToCurrent(level)
		end)
	end
	if not silent and changed then
		PlayUISound("IG_CHARACTER_INFO_TAB", 841)
	end
end

local function BuildLevelRows(parent)
		local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	header:SetPoint("TOPLEFT", 8, -4)
	header:SetText("LEVEL")

	local headerXp = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headerXp:SetPoint("TOPRIGHT", -8, -4)
	headerXp:SetText("XP REQUIRED")

	for level = 1, MAX_LEVEL do
		local row = CreateFrame("Frame", nil, parent)
		row:SetPoint("TOPLEFT", 0, -20 - (level - 1) * ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", 0, -20 - (level - 1) * ROW_HEIGHT)
		row:SetHeight(ROW_HEIGHT)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:Hide()

		row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.level:SetPoint("LEFT", 8, 0)
		row.level:SetText(tostring(level))

		row.xp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.xp:SetPoint("RIGHT", -8, 0)
		row.xp:SetText(FormatNumber(xpForLevel[level]))

		row.diff = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.diff:SetPoint("CENTER", 20, 0)
		if level == 1 then
			row.diff:SetText("")
		else
			row.diff:SetText("+" .. FormatNumber(xpForLevel[level] - xpForLevel[level - 1]))
		end

		ui.levelRows[level] = row
	end

	parent:SetSize(300, 24 + MAX_LEVEL * ROW_HEIGHT)
end

local function UpdateLevelRows(currentLevel)
	for level, row in pairs(ui.levelRows) do
		if level == currentLevel then
			row.bg:SetColorTexture(1, 0.82, 0, 0.18)
			row.bg:Show()
			row.level:SetTextColor(1, 0.82, 0, 1)
			row.xp:SetTextColor(1, 0.82, 0, 1)
		else
			row.bg:Hide()
			row.level:SetTextColor(1, 1, 1, 1)
			row.xp:SetTextColor(1, 1, 1, 1)
		end
	end
end

local function EnsureBoardRow(parent, index)
	local row = ui.boardRows[index]
	if row then
		return row
	end

	row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT)

	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.rank:SetPoint("LEFT", 8, 0)
	row.rank:SetWidth(28)
	row.rank:SetJustifyH("LEFT")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", 40, 0)
	row.name:SetPoint("RIGHT", -160, 0)
	row.name:SetJustifyH("LEFT")

	row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.level:SetPoint("RIGHT", -112, 0)
	row.level:SetWidth(36)
	row.level:SetJustifyH("RIGHT")

	row.jumps = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.jumps:SetPoint("RIGHT", -52, 0)
	row.jumps:SetWidth(56)
	row.jumps:SetJustifyH("RIGHT")

	row.achs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.achs:SetPoint("RIGHT", -8, 0)
	row.achs:SetWidth(40)
	row.achs:SetJustifyH("RIGHT")

	ui.boardRows[index] = row
	return row
end

UpdateLeaderboard = function()
	EnsureDB()
	if type(AJHDB) ~= "table" then
		return
	end
	local key, name = PlayerIdentity()
	StoreScore(key, name, AJHDB.jumps, GetAchievementMask(), AJHDB.xp)

	local entries = {}
	for entryKey, data in pairs(AJHDB.board) do
		if type(data) == "table" and type(data.jumps) == "number" then
			local achCount = CountAchievementsFromMask(data.achMask)
			if entryKey == key then
				achCount = CountOwnAchievements()
			end
			local entryXp = ToNumberOr(data.xp, data.jumps)
			tinsert(entries, {
				key = entryKey,
				name = data.name or entryKey,
				jumps = data.jumps,
				level = GetLevel(entryXp),
				achs = achCount,
			})
		end
	end

	table.sort(entries, function(a, b)
		if a.jumps == b.jumps then
			if a.achs == b.achs then
				return a.name < b.name
			end
			return a.achs > b.achs
		end
		return a.jumps > b.jumps
	end)

	if ui.guildEmpty then
		if not IsInGuild() then
			ui.guildEmpty:SetText("Join a guild to share a Jump Habit leaderboard.")
			ui.guildEmpty:Show()
		elseif #entries <= 1 then
			ui.guildEmpty:SetText("Waiting for guildmates with AJH… Open this tab while they are online.")
			if #entries == 0 then
				ui.guildEmpty:Show()
			else
				-- Still show your row; keep the hint visible above is awkward.
				-- Hide empty state when at least you are listed.
				ui.guildEmpty:Hide()
			end
		else
			ui.guildEmpty:Hide()
		end
	end

	local child = ui.boardChild
	if not child then
		return
	end

	for i, entry in ipairs(entries) do
		local row = EnsureBoardRow(child, i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -20 - (i - 1) * ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", 0, -20 - (i - 1) * ROW_HEIGHT)
		row:Show()

		row.rank:SetText(tostring(i))
		row.name:SetText(entry.name)
		row.level:SetText(tostring(entry.level))
		row.jumps:SetText(FormatNumber(entry.jumps))
		row.achs:SetText(string.format("%d/%d", entry.achs, #ACHIEVEMENTS))

		local mine = entry.key == key
		if mine then
			row.rank:SetTextColor(1, 0.82, 0, 1)
			row.name:SetTextColor(1, 0.82, 0, 1)
			row.level:SetTextColor(1, 0.82, 0, 1)
			row.jumps:SetTextColor(1, 0.82, 0, 1)
			row.achs:SetTextColor(1, 0.82, 0, 1)
		else
			row.rank:SetTextColor(1, 1, 1, 1)
			row.name:SetTextColor(1, 1, 1, 1)
			row.level:SetTextColor(1, 1, 1, 1)
			row.jumps:SetTextColor(1, 1, 1, 1)
			row.achs:SetTextColor(1, 1, 1, 1)
		end
	end

	for i = #entries + 1, #ui.boardRows do
		ui.boardRows[i]:Hide()
	end

	child:SetSize(300, 24 + math.max(#entries, 1) * ROW_HEIGHT)
end

local ACH_ROW_HEIGHT = 48
local FEAT_CAT_ROW_HEIGHT = 52

local function HideFeatRows(rows)
	for _, row in pairs(rows) do
		row:Hide()
	end
end

local function StyleFeatItemRow(row, ach, done)
	row.title:SetText(ach.name)
	row.desc:SetText(ach.desc)
	if done then
		row.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
		row.bg:SetColorTexture(1, 0.82, 0, 0.12)
		row.bg:Show()
		row.title:SetTextColor(1, 0.82, 0, 1)
		row.desc:SetTextColor(1, 1, 1, 1)
	else
		row.icon:SetTexture("Interface\\GossipFrame\\IncompleteQuestIcon")
		row.bg:Hide()
		row.title:SetTextColor(1, 1, 1, 1)
		row.desc:SetTextColor(0.7, 0.7, 0.7, 1)
	end
end

local function EnsureFeatItemRow(i)
	local child = ui.achChild
	local row = ui.achRows[i]
	if row then
		return row
	end
	row = CreateFrame("Frame", nil, child)
	row:SetHeight(ACH_ROW_HEIGHT)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", 10, 0)

	row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.title:SetPoint("TOPLEFT", 40, -8)
	row.title:SetPoint("TOPRIGHT", -10, -8)
	row.title:SetJustifyH("LEFT")

	row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.desc:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
	row.desc:SetPoint("RIGHT", -10, 0)
	row.desc:SetJustifyH("LEFT")

	ui.achRows[i] = row
	return row
end

local function EnsureFeatCategoryRow(i)
	local child = ui.achChild
	local row = ui.featCatRows[i]
	if row then
		return row
	end
	row = CreateFrame("Button", nil, child)
	row:SetHeight(FEAT_CAT_ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp")

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, 0.04)

	row.hl = row:CreateTexture(nil, "HIGHLIGHT")
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(1, 1, 1, 0.08)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(22, 22)
	row.icon:SetPoint("LEFT", 10, 0)
	row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

	row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.title:SetPoint("TOPLEFT", 42, -10)
	row.title:SetPoint("TOPRIGHT", -56, -10)
	row.title:SetJustifyH("LEFT")

	row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.desc:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
	row.desc:SetPoint("RIGHT", -56, 0)
	row.desc:SetJustifyH("LEFT")
	row.desc:SetTextColor(0.7, 0.7, 0.7, 1)

	row.progress = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.progress:SetPoint("RIGHT", -12, 0)
	row.progress:SetJustifyH("RIGHT")

	row:SetScript("OnClick", function(self)
		if not self.categoryId then
			return
		end
		ui.featView = self.categoryId
		PlayUISound("IG_CHARACTER_INFO_TAB", 841)
		UpdateAchievements()
	end)

	ui.featCatRows[i] = row
	return row
end

UpdateAchievements = function()
	EnsureDB()
	local child = ui.achChild
	if not child then
		return
	end

	local totalEarned = 0
	for _, ach in ipairs(ACHIEVEMENTS) do
		if AJHDB.achievements[ach.id] then
			totalEarned = totalEarned + 1
		end
	end

	local view = ui.featView or "categories"
	local inCategory = view ~= "categories"

	if ui.featBack then
		ui.featBack:SetShown(inCategory)
	end
	if ui.achSummary then
		ui.achSummary:ClearAllPoints()
		if inCategory and ui.featBack then
			ui.achSummary:SetPoint("LEFT", ui.featBack, "RIGHT", 8, 0)
		else
			ui.achSummary:SetPoint("TOPLEFT", 12, -16)
		end
	end

	if inCategory then
		HideFeatRows(ui.featCatRows)

		local catName = view
		for _, cat in ipairs(FEAT_CATEGORIES) do
			if cat.id == view then
				catName = cat.name
				break
			end
		end

		local feats = GetFeatsInCategory(view)
		local earned, total = CountCategoryProgress(view)

		for i, ach in ipairs(feats) do
			local row = EnsureFeatItemRow(i)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -(i - 1) * ACH_ROW_HEIGHT)
			row:SetPoint("TOPRIGHT", 0, -(i - 1) * ACH_ROW_HEIGHT)
			row:Show()
			StyleFeatItemRow(row, ach, AJHDB.achievements[ach.id] ~= nil)
		end
		for i = #feats + 1, #ui.achRows do
			ui.achRows[i]:Hide()
		end

		child:SetSize(300, math.max(#feats, 1) * ACH_ROW_HEIGHT)
		if ui.achSummary then
			ui.achSummary:SetText(string.format("%s  —  %d / %d", catName, earned, total))
		end
	else
		HideFeatRows(ui.achRows)

		for i, cat in ipairs(FEAT_CATEGORIES) do
			local row = EnsureFeatCategoryRow(i)
			local earned, total = CountCategoryProgress(cat.id)
			row.categoryId = cat.id
			row.title:SetText(cat.name)
			row.desc:SetText(cat.desc)
			row.progress:SetText(string.format("%d / %d", earned, total))
			if earned >= total and total > 0 then
				row.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
				row.progress:SetTextColor(1, 0.82, 0, 1)
				row.title:SetTextColor(1, 0.82, 0, 1)
				row.bg:SetColorTexture(1, 0.82, 0, 0.10)
			elseif earned > 0 then
				row.icon:SetTexture("Interface\\GossipFrame\\IncompleteQuestIcon")
				row.progress:SetTextColor(1, 1, 1, 1)
				row.title:SetTextColor(1, 1, 1, 1)
				row.bg:SetColorTexture(1, 1, 1, 0.04)
			else
				row.icon:SetTexture("Interface\\GossipFrame\\IncompleteQuestIcon")
				row.progress:SetTextColor(0.7, 0.7, 0.7, 1)
				row.title:SetTextColor(1, 1, 1, 1)
				row.bg:SetColorTexture(1, 1, 1, 0.04)
			end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -(i - 1) * FEAT_CAT_ROW_HEIGHT)
			row:SetPoint("TOPRIGHT", 0, -(i - 1) * FEAT_CAT_ROW_HEIGHT)
			row:Show()
		end
		for i = #FEAT_CATEGORIES + 1, #ui.featCatRows do
			ui.featCatRows[i]:Hide()
		end

		child:SetSize(300, #FEAT_CATEGORIES * FEAT_CAT_ROW_HEIGHT)
		if ui.achSummary then
			ui.achSummary:SetText(string.format("%d / %d feats", totalEarned, #ACHIEVEMENTS))
		end
	end
end

local function BuildPanel()
	if panel then
		return panel
	end

	panel = CreateFrame("Frame", "AJHFrame", UIParent, "ButtonFrameTemplate")
	panel:SetSize(384, 424)
	panel:SetPoint("CENTER")
	panel:SetFrameStrata("MEDIUM")
	panel:SetToplevel(true)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	panel:Hide()

	tinsert(UISpecialFrames, "AJHFrame")

	if ButtonFrameTemplate_HideButtonBar then
		ButtonFrameTemplate_HideButtonBar(panel)
	end
	if panel.SetTitle then
		panel:SetTitle("Archindula's Jump Habit")
	elseif panel.TitleContainer and panel.TitleContainer.TitleText then
		panel.TitleContainer.TitleText:SetText("Archindula's Jump Habit")
	elseif panel.TitleText then
		panel.TitleText:SetText("Archindula's Jump Habit")
	end
	if panel.SetPortraitToTexture then
		panel:SetPortraitToTexture(FROG_ICON)
	elseif panel.SetPortraitToAsset then
		panel:SetPortraitToAsset(FROG_ICON)
	else
		local portrait = panel.PortraitContainer and panel.PortraitContainer.portrait or panel.portrait
		if portrait then
			portrait:SetTexture(FROG_ICON)
		end
	end
	if panel.TitleContainer then
		panel.TitleContainer:EnableMouse(true)
		panel.TitleContainer:RegisterForDrag("LeftButton")
		panel.TitleContainer:SetScript("OnDragStart", function()
			panel:StartMoving()
		end)
		panel.TitleContainer:SetScript("OnDragStop", function()
			panel:StopMovingOrSizing()
		end)
	end

	local content = CreateFrame("Frame", nil, panel)
	if panel.Inset then
		panel.Inset:ClearAllPoints()
		-- Equal left/right so the InsetFrame edge sliver shows on both sides.
		panel.Inset:SetPoint("TOPLEFT", 8, -62)
		panel.Inset:SetPoint("BOTTOMRIGHT", -12, 28)
		content:SetParent(panel.Inset)
		content:SetAllPoints()
	else
		content:SetPoint("TOPLEFT", 12, -70)
		content:SetPoint("BOTTOMRIGHT", -12, 28)
	end

	local tabDefs = {
		{ id = "habit", label = "Habit" },
		{ id = "levels", label = "Levels" },
		{ id = "achieves", label = "Feats" },
		{ id = "guild", label = "Guild" },
	}
	ui.tabIndex = {}
	ui.tabButtons = {}
	for i, def in ipairs(tabDefs) do
		local tab = CreateFrame("Button", "AJHFrameTab" .. i, panel, "PanelTabButtonTemplate")
		tab:SetID(i)
		tab:SetText(def.label)
		tab.tabId = def.id
		if i == 1 then
			tab:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 11, 2)
		else
			tab:SetPoint("LEFT", ui.tabButtons[i - 1], "RIGHT", 3, 0)
		end
		tab:SetScript("OnClick", function(self)
			SetTab(self.tabId)
		end)
		if PanelTemplates_TabResize then
			PanelTemplates_TabResize(tab, 0)
		end
		ui.tabButtons[i] = tab
		ui.tabs[def.id] = tab
		ui.tabIndex[def.id] = i
	end
	PanelTemplates_SetNumTabs(panel, #tabDefs)
	PanelTemplates_SetTab(panel, 1)

	-- Habit page
	local habit = CreateFrame("Frame", nil, content)
	habit:SetAllPoints()
	ui.pages.habit = habit

	local levelLabel = habit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	levelLabel:SetPoint("TOP", 0, -8)
	levelLabel:SetText("LEVEL")
	levelLabel:SetTextColor(1, 0.82, 0)

	ui.level = habit:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	ui.level:SetPoint("TOP", levelLabel, "BOTTOM", 0, -2)
	-- Large gold level number.
	local levelFont = (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
	ui.level:SetFont(levelFont, 42, "OUTLINE")
	ui.level:SetTextColor(1, 0.82, 0)
	if ui.level.SetShadowOffset then
		ui.level:SetShadowOffset(2, -2)
		ui.level:SetShadowColor(0, 0, 0, 0.85)
	end

	-- Habit XP bar: flat yellow fill flush to the frame (no texture padding gaps).
	local BAR_PAD = 22
	local barWrap = CreateFrame("Frame", nil, habit)
	barWrap:ClearAllPoints()
	barWrap:SetPoint("TOP", ui.level, "BOTTOM", 0, -14)
	barWrap:SetPoint("LEFT", habit, "LEFT", BAR_PAD, 0)
	barWrap:SetPoint("RIGHT", habit, "RIGHT", -BAR_PAD, 0)
	barWrap:SetHeight(22)
	ui.barWrap = barWrap

	-- Border first so the StatusBar can fill its interior tightly.
	local border = CreateFrame("Frame", nil, barWrap, BackdropTemplateMixin and "BackdropTemplate" or nil)
	border:SetPoint("TOPLEFT", 0, 0)
	border:SetPoint("BOTTOMRIGHT", 0, 0)
	border:SetFrameLevel(barWrap:GetFrameLevel() + 3)
	if border.SetBackdrop then
		border:SetBackdrop({
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		border:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
	end

	ui.bar = CreateFrame("StatusBar", nil, barWrap)
	-- Inset matches the tooltip border's visual inner edge so no black gap shows.
	ui.bar:SetPoint("TOPLEFT", barWrap, "TOPLEFT", 3, -3)
	ui.bar:SetPoint("BOTTOMRIGHT", barWrap, "BOTTOMRIGHT", -3, 3)
	ui.bar:SetMinMaxValues(0, 1)
	ui.bar:SetValue(0)
	ui.bar:SetFrameLevel(barWrap:GetFrameLevel() + 1)
	-- Solid fill — UI-StatusBar has transparent margins that left black lines.
	ui.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	ui.bar:SetStatusBarColor(1.0, 0.82, 0.0, 1)
	local fillTex = ui.bar:GetStatusBarTexture()
	if fillTex then
		fillTex:SetHorizTile(false)
		fillTex:SetVertTile(false)
	end

	local track = ui.bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(0.08, 0.07, 0.04, 1)

	-- Leading-edge silver glow (same idea as profession bars' hot tip).
	ui.barSpark = ui.bar:CreateTexture(nil, "OVERLAY", nil, 2)
	ui.barSpark:SetTexture("Interface\\Buttons\\WHITE8X8")
	ui.barSpark:SetWidth(48)
	ui.barSpark:SetPoint("TOP", 0, 0)
	ui.barSpark:SetPoint("BOTTOM", 0, 0)
	if ui.barSpark.SetGradient and CreateColor then
		-- Soft yellow into cool silver at the tip.
		ui.barSpark:SetGradient(
			"HORIZONTAL",
			CreateColor(1.0, 0.82, 0.0, 0),
			CreateColor(0.92, 0.94, 1.0, 0.95)
		)
	else
		ui.barSpark:SetColorTexture(0.9, 0.92, 1.0, 0.85)
	end
	ui.barSpark:Hide()

	local function UpdateHabitBarSilverTip()
		local spark = ui.barSpark
		local bar = ui.bar
		if not spark or not bar then
			return
		end
		local minV, maxV = bar:GetMinMaxValues()
		local value = bar:GetValue()
		local width = bar:GetWidth()
		if not width or width <= 0 or not maxV or maxV <= minV then
			spark:Hide()
			return
		end
		local pct = (value - minV) / (maxV - minV)
		if pct <= 0.02 or pct >= 0.995 then
			spark:Hide()
			return
		end
		local fillW = width * pct
		local tipW = math.min(56, math.max(28, fillW * 0.38))
		spark:SetWidth(tipW)
		spark:ClearAllPoints()
		spark:SetPoint("TOPRIGHT", bar, "TOPLEFT", fillW, 0)
		spark:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", fillW, 0)
		spark:Show()
	end

	ui.bar:SetScript("OnValueChanged", function()
		UpdateHabitBarSilverTip()
	end)
	ui.bar:SetScript("OnSizeChanged", function()
		UpdateHabitBarSilverTip()
	end)
	ui.UpdateHabitBarFill = UpdateHabitBarSilverTip

	ui.barText = ui.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.barText:SetPoint("CENTER", ui.bar, "CENTER", 0, 0)
	ui.barText:SetTextColor(1, 1, 1)
	do
		local fontPath, fontSize = ui.barText:GetFont()
		if fontPath then
			ui.barText:SetFont(fontPath, fontSize or 12, "OUTLINE")
		end
	end
	if ui.barText.SetShadowOffset then
		ui.barText:SetShadowOffset(0, 0)
		ui.barText:SetShadowColor(0, 0, 0, 0)
	end

	ui.xpDetail = habit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.xpDetail:SetPoint("TOP", barWrap, "BOTTOM", 0, -10)
	ui.xpDetail:SetTextColor(1, 0.82, 0)

	local statsLine = habit:CreateTexture(nil, "ARTWORK")
	statsLine:SetHeight(1)
	statsLine:SetColorTexture(0.55, 0.45, 0.15, 0.55)
	statsLine:SetPoint("LEFT", habit, "LEFT", 16, 0)
	statsLine:SetPoint("RIGHT", habit, "RIGHT", -16, 0)
	statsLine:SetPoint("TOP", ui.xpDetail, "BOTTOM", 0, -12)

	local function HabitStatRow(anchor, yOff)
		local label = habit:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
		local value = habit:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		value:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, yOff)
		return label, value
	end

	ui.jumpLabel, ui.jumpValue = HabitStatRow(statsLine, -14)
	ui.jumpLabel:SetText("Total jumps")

	ui.xpLabel, ui.xpValue = HabitStatRow(ui.jumpLabel, -10)
	ui.xpLabel:SetText("Experience")
	-- Keep value aligned to the full-width line, not the shorter label.
	ui.xpValue:ClearAllPoints()
	ui.xpValue:SetPoint("TOPRIGHT", ui.jumpValue, "BOTTOMRIGHT", 0, -10)

	ui.nextLabel, ui.nextValue = HabitStatRow(ui.xpLabel, -10)
	ui.nextLabel:SetText("XP to next level")
	ui.nextValue:ClearAllPoints()
	ui.nextValue:SetPoint("TOPRIGHT", ui.xpValue, "BOTTOMRIGHT", 0, -10)

	ui.rateLabel, ui.rateValue = HabitStatRow(ui.nextLabel, -10)
	ui.rateLabel:SetText("XP per jump")
	ui.rateValue:ClearAllPoints()
	ui.rateValue:SetPoint("TOPRIGHT", ui.nextValue, "BOTTOMRIGHT", 0, -10)
	ui.rateValue:SetText(tostring(XP_PER_JUMP))

	local function MakeAnnounceButton(parent, label)
		local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		btn:SetHeight(22)
		btn:SetText(label)
		return btn
	end

	local function AnnounceStatus(channel)
		EnsureDB()
		local level = GetLevel(AJHDB.xp)
		local jumps = AJHDB.jumps
		SendChatMessage(
			string.format(
				"Jump Habit: Level %d - %s jump%s",
				level,
				FormatNumber(jumps),
				jumps == 1 and "" or "s"
			),
			channel
		)
	end

	-- One tidy row of three equal buttons.
	local BTN_PAD = 12
	local BTN_GAP = 6
	local btnRow = CreateFrame("Frame", nil, habit)
	btnRow:SetPoint("BOTTOMLEFT", BTN_PAD, 10)
	btnRow:SetPoint("BOTTOMRIGHT", -BTN_PAD, 10)
	btnRow:SetHeight(22)

	ui.jumpXPBarToggle = MakeAnnounceButton(btnRow, "Show XP Bar")
	local announceSay = MakeAnnounceButton(btnRow, "Announce /say")
	local announceGuild = MakeAnnounceButton(btnRow, "Announce /g")

	local function LayoutHabitButtons()
		local width = btnRow:GetWidth()
		if not width or width <= 0 then
			return
		end
		local btnW = (width - BTN_GAP * 2) / 3
		ui.jumpXPBarToggle:ClearAllPoints()
		ui.jumpXPBarToggle:SetSize(btnW, 22)
		ui.jumpXPBarToggle:SetPoint("LEFT", btnRow, "LEFT", 0, 0)

		announceSay:ClearAllPoints()
		announceSay:SetSize(btnW, 22)
		announceSay:SetPoint("LEFT", ui.jumpXPBarToggle, "RIGHT", BTN_GAP, 0)

		announceGuild:ClearAllPoints()
		announceGuild:SetSize(btnW, 22)
		announceGuild:SetPoint("LEFT", announceSay, "RIGHT", BTN_GAP, 0)
	end

	btnRow:SetScript("OnSizeChanged", LayoutHabitButtons)
	LayoutHabitButtons()

	ui.jumpXPBarToggle:SetScript("OnClick", function()
		EnsureDB()
		local shown = GetJumpXPBarSaved().shown
		SetJumpXPBarShown(not shown)
	end)
	announceSay:SetScript("OnClick", function()
		AnnounceStatus("SAY")
	end)
	announceGuild:SetScript("OnClick", function()
		if not IsInGuild() then
			DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r You are not in a guild.")
			return
		end
		AnnounceStatus("GUILD")
	end)
	UpdateJumpXPBarToggleLabel()

	-- Levels page
	local levels = CreateFrame("Frame", nil, content)
	levels:SetAllPoints()
	levels:Hide()
	ui.pages.levels = levels
	local _, levelScroll, levelChild = CreateScrollArea(levels)
	ui.levelScroll = levelScroll
	ui.levelChild = levelChild
	BuildLevelRows(levelChild)

	-- Achievements page
	local achieves = CreateFrame("Frame", nil, content)
	achieves:SetAllPoints()
	achieves:Hide()
	ui.pages.achieves = achieves

	ui.featBack = CreateFrame("Button", nil, achieves, "UIPanelButtonTemplate")
	ui.featBack:SetSize(56, 20)
	ui.featBack:SetPoint("TOPLEFT", 8, -12)
	ui.featBack:SetText("< Back")
	ui.featBack:Hide()
	ui.featBack:SetScript("OnClick", function()
		ui.featView = "categories"
		PlayUISound("IG_CHARACTER_INFO_TAB", 841)
		UpdateAchievements()
	end)

	ui.achSummary = achieves:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.achSummary:SetPoint("TOPLEFT", 12, -16)

	local achWrap, _, achChild = CreateScrollArea(achieves)
	achWrap:SetPoint("TOPLEFT", 4, -40)
	-- Leave room for the reset button only when local DEV_TOOLS is on.
	achWrap:SetPoint("BOTTOMRIGHT", -4, DEV_TOOLS and 32 or 4)
	ui.achChild = achChild

	if DEV_TOOLS then
		local resetAch = CreateFrame("Button", nil, achieves, "UIPanelButtonTemplate")
		resetAch:SetPoint("BOTTOMLEFT", 12, 6)
		resetAch:SetPoint("BOTTOMRIGHT", -12, 6)
		resetAch:SetHeight(22)
		resetAch:SetText("Reset feats (testing)")
		resetAch:SetScript("OnClick", function()
			ResetAchievements()
		end)
	end

	-- Guild page
	local guild = CreateFrame("Frame", nil, content)
	guild:SetAllPoints()
	guild:Hide()
	ui.pages.guild = guild

	local boardWrap, _, boardChild = CreateScrollArea(guild)
	ui.boardChild = boardChild

	local boardHeaderRank = boardChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	boardHeaderRank:SetPoint("TOPLEFT", 8, -4)
	boardHeaderRank:SetText("#")

	local boardHeaderName = boardChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	boardHeaderName:SetPoint("TOPLEFT", 40, -4)
	boardHeaderName:SetText("NAME")

	local boardHeaderLevel = boardChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	boardHeaderLevel:SetPoint("TOPRIGHT", -112, -4)
	boardHeaderLevel:SetText("LVL")

	local boardHeaderJumps = boardChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	boardHeaderJumps:SetPoint("TOPRIGHT", -52, -4)
	boardHeaderJumps:SetText("JUMPS")

	local boardHeaderAchs = boardChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	boardHeaderAchs:SetPoint("TOPRIGHT", -8, -4)
	boardHeaderAchs:SetText("FEATS")

	ui.guildEmpty = guild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ui.guildEmpty:SetPoint("CENTER", boardWrap, "CENTER", -8, 0)
	ui.guildEmpty:SetWidth(280)
	ui.guildEmpty:SetJustifyH("CENTER")

	local refresh = CreateFrame("Button", nil, guild, "UIPanelButtonTemplate")
	refresh:SetPoint("BOTTOMLEFT", 12, 6)
	refresh:SetPoint("BOTTOMRIGHT", -12, 6)
	refresh:SetHeight(22)
	refresh:SetText("Refresh guild scores")
	refresh:SetScript("OnClick", function()
		RequestGuildScores()
		UpdateLeaderboard()
	end)

	boardWrap:SetPoint("TOPLEFT", 4, -4)
	boardWrap:SetPoint("BOTTOMRIGHT", -4, 32)

	panel:SetScript("OnShow", function()
		PlayUISound("IG_CHARACTER_INFO_OPEN", 839)
		panel:Update()
	end)
	panel:SetScript("OnHide", function()
		PlayUISound("IG_CHARACTER_INFO_CLOSE", 840)
	end)

	function panel:Update()
		EnsureDB()
		local xp = AJHDB.xp
		local jumps = AJHDB.jumps
		local level = GetLevel(xp)

		ui.level:SetText(tostring(level))
		ui.jumpValue:SetText(FormatNumber(jumps))
		UpdateLevelRows(level)

		local xpGain = GetJumpXPGain()
		if HasCampBenefit() then
			ui.rateValue:SetText(string.format("%d (Camp x%d)", xpGain, CAMP_XP_MULTIPLIER))
			ui.rateValue:SetTextColor(0.1, 1, 0.1, 1)
		else
			ui.rateValue:SetText(tostring(xpGain))
			ui.rateValue:SetTextColor(1, 1, 1, 1)
		end

		if level >= MAX_LEVEL then
			ui.bar:SetMinMaxValues(0, 1)
			ui.bar:SetValue(1)
			ui.barText:SetText("Jump Habit MAX")
			ui.xpDetail:SetText("RuneScape curve - level 99")
			ui.xpValue:SetText(FormatNumber(xp - xpForLevel[MAX_LEVEL]))
			ui.nextLabel:SetText("XP to next level")
			ui.nextValue:SetText("-")
		else
			-- Within-level XP resets to 0 at each level-up.
			local intoLevel = xp - xpForLevel[level]
			local needed = xpForLevel[level + 1] - xpForLevel[level]
			local remaining = needed - intoLevel
			local pct = needed > 0 and (intoLevel / needed) or 0

			ui.bar:SetMinMaxValues(0, needed)
			ui.bar:SetValue(intoLevel)
			-- Same label style as profession skill bars: Name current/max
			ui.barText:SetText(string.format(
				"Jump Habit %s/%s",
				FormatNumber(intoLevel),
				FormatNumber(needed)
			))
			ui.xpDetail:SetText(string.format(
				"%d%%  -  %s until level %d",
				math.min(99, math.floor(pct * 100)),
				FormatNumber(remaining),
				level + 1
			))
			ui.xpValue:SetText(FormatNumber(intoLevel))
			ui.nextLabel:SetText("XP to next level")
			ui.nextValue:SetText(FormatNumber(remaining))
		end

		if activeTab == "guild" then
			UpdateLeaderboard()
		elseif activeTab == "achieves" then
			UpdateAchievements()
		end

		UpdateJumpXPBar()
	end

	SetTab("habit", true)
	return panel
end

local function TogglePanel()
	local f = BuildPanel()
	if f:IsShown() then
		f:Hide()
	else
		f:Show()
		f:Update()
	end
end

-- Slash / binding entry point (Bindings.xml auto-loads; must not be in TOC).
function AJH_TogglePanel()
	TogglePanel()
end

local minimapButton
local minimapDragging = false

local function UpdateMinimapButtonPosition()
	if not minimapButton then
		return
	end
	-- Do NOT call EnsureDB here — position reads AJHDB if present; UI build
	-- waits until VARIABLES_LOADED so we never invent an empty DB early.
	local angle = math.rad((type(AJHDB) == "table" and AJHDB.minimapPos) or 210)
	local radius = (Minimap:GetWidth() / 2) + 5
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
	if minimapButton then
		return minimapButton
	end

	local btn = CreateFrame("Button", "AJHMinimapButton", Minimap)
	btn:SetSize(36, 36)
	btn:SetFrameStrata("MEDIUM")
	btn:SetFrameLevel(8)
	btn:RegisterForClicks("LeftButtonUp")
	btn:RegisterForDrag("LeftButton")
	btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	-- Scaled-up MiniMap-TrackingBorder layout.
	local icon = btn:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(24, 24)
	icon:SetPoint("CENTER")
	icon:SetTexture(FROG_ICON)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local overlay = btn:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(62, 62)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	btn:SetScript("OnEnter", function(self)
		EnsureDB()
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Archindula's Jump Habit", C.accent[1], C.accent[2], C.accent[3])
		GameTooltip:AddLine(
			string.format("Level %d  -  %s jumps", GetLevel(AJHDB.xp), FormatNumber(AJHDB.jumps)),
			1, 1, 1
		)
		GameTooltip:AddLine("Click to open", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("Drag to move", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	btn:SetScript("OnClick", function()
		if minimapDragging then
			return
		end
		TogglePanel()
	end)

	btn:SetScript("OnDragStart", function(self)
		minimapDragging = true
		GameTooltip:Hide()
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale
			EnsureDB()
			AJHDB.minimapPos = math.deg(math.atan2(cy - my, cx - mx))
			UpdateMinimapButtonPosition()
		end)
	end)

	btn:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		C_Timer.After(0, function()
			minimapDragging = false
		end)
	end)

	minimapButton = btn
	UpdateMinimapButtonPosition()
	return btn
end

local JUMP_COOLDOWN = 0.8
local lastJumpTime = 0

local function StartLateLoadWatch()
	if lateLoadTicker then
		return
	end
	local tries = 0
	lateLoadTicker = C_Timer.NewTicker(0.5, function(self)
		tries = tries + 1
		local before = type(AJHDB) == "table" and ToNumberOr(AJHDB.jumps, 0) or 0
		local rawMax = MaxProgressInAccountSV()
		if rawMax > before then
			EnsureDB()
			if panel and panel:IsShown() then
				panel:Update()
			else
				UpdateJumpXPBar()
			end
			if DIAG_ENABLED then
				DiagChat(string.format(
					"late-load hydrate before=%d rawMax=%d after=%d",
					before,
					rawMax,
					ToNumberOr(AJHDB and AJHDB.jumps, 0)
				))
			end
		end
		if tries >= 20 then
			self:Cancel()
			lateLoadTicker = nil
		end
	end)
end

local function OnJump()
	local now = GetTime()
	if now - lastJumpTime < JUMP_COOLDOWN then
		return
	end
	lastJumpTime = now

	EnsureDB()
	local oldLevel = GetLevel(AJHDB.xp)
	AJHDB.jumps = AJHDB.jumps + 1
	AJHDB.xp = AJHDB.xp + GetJumpXPGain()
	CommitFloor()
	PersistProgressMirror()
	local newLevel = GetLevel(AJHDB.xp)
	if newLevel > oldLevel then
		AnnounceLevelUp(newLevel)
		BroadcastScore()
	elseif AJHDB.jumps % 25 == 0 then
		BroadcastScore()
	end
	if CheckAchievementsOnJump() and panel and panel:IsShown() and activeTab == "achieves" then
		UpdateAchievements()
	end
	if panel and panel:IsShown() then
		panel:Update()
	else
		UpdateJumpXPBar()
	end
end

local uiBuilt = false
local jumpHookInstalled = false

-- Build UI / jump hook only AFTER VARIABLES_LOADED (or on PLAYER_LOGIN if
-- VARIABLES_LOADED was missed). BuildJumpXPBar → EnsureDB must not run at
-- ADDON_LOADED or it invents AJHDB={} before Forever injects SavedVariables.
local function EnsureUIBuilt()
	if uiBuilt then
		return
	end
	uiBuilt = true
	BuildPanel()
	BuildJumpXPBar()
	BuildMinimapButton()
	if not jumpHookInstalled then
		jumpHookInstalled = true
		hooksecurefunc("JumpOrAscendStart", OnJump)
	end
	RefreshCampBenefit()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("VARIABLES_LOADED")
loader:RegisterUnitEvent("UNIT_AURA", "player")
loader:RegisterEvent("CHAT_MSG_ADDON")
loader:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name ~= ADDON_NAME then
			return
		end
		-- Snapshot ONLY — no EnsureDB, no UI build. Forever has not injected
		-- account SavedVariables yet; BuildJumpXPBar→EnsureDB would invent
		-- AJHDB={} and poison the session (diag: DB=table jumps=0).
		diagRawAtAddonLoaded = DiagSnapshot("ADDON_LOADED/raw")
		SyncSavedVarsFromGlobal()
		DebugDump("ADDON_LOADED (raw client SV, before bind)")
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
		elseif RegisterAddonMessagePrefix then
			RegisterAddonMessagePrefix(ADDON_PREFIX)
		end
	elseif event == "VARIABLES_LOADED" then
		-- Forever injects account SavedVariables HERE (not at ADDON_LOADED).
		-- Character AJHDB may already exist; Account/Floor appear now.
		variablesLoadedFired = true
		SyncSavedVarsFromGlobal()
		DebugDump("VARIABLES_LOADED (before bind)")
		local healed = HealProgressOnLogin()
		DebugDump("VARIABLES_LOADED (after bind)")
		EnsureUIBuilt()
		if healed and DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff88ff88AJH:|r Recovered your Jump Habit progress (%s jumps).",
				FormatNumber(AJHDB.jumps)
			))
		end
		if panel then
			panel:Update()
		end
		UpdateJumpXPBar()
	elseif event == "PLAYER_LOGIN" then
		-- Safety: allow EnsureDB if VARIABLES_LOADED never fired on this client.
		variablesLoadedFired = true
		SyncSavedVarsFromGlobal()
		-- Bind again in case anything arrived between VARIABLES_LOADED and login.
		local healed = HealProgressOnLogin()
		diagAfterBind = DiagSnapshot("PLAYER_LOGIN/afterEnsureDB")
		DebugDump("PLAYER_LOGIN (after bind/hydrate)")
		EnsureUIBuilt()
		-- Quiet late catch if Forever injects SV after login (no chat spam).
		C_Timer.After(2, function()
			SyncSavedVarsFromGlobal()
			AbsorbAccountStoreFromAJHDB()
			RestoreProgressMirror()
			if MaxProgressInAccountSV() > ToNumberOr(AJHDB and AJHDB.jumps, 0) then
				EnsureDB()
				PersistProgressMirror()
				if panel then
					panel:Update()
				end
			end
		end)
		StartLateLoadWatch()
		if healed then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff88ff88AJH:|r Recovered your Jump Habit progress (%s jumps).",
				FormatNumber(AJHDB.jumps)
			))
		else
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff88ff88AJH:|r Loaded %s jumps (%s XP).",
				FormatNumber(AJHDB.jumps),
				FormatNumber(AJHDB.xp)
			))
		end
		RefreshCampBenefit()
		if panel then
			panel:Update()
		end
		RestoreJumpXPBarFromSaved()
		C_Timer.After(0.5, RestoreJumpXPBarFromSaved)
	elseif event == "PLAYER_LOGOUT" then
		diagAtLogout = DiagSnapshot("PLAYER_LOGOUT/beforeEnsureDB")
		if DIAG_ENABLED then
			DiagPrintSnapshot(diagAtLogout, true)
		end
		-- Forever ignores TOC renames for SAVE: it keeps writing AJHAccount
		-- (and AJHFloor when present). Never rename/nil those on logout when
		-- we have real progress. Empty account tables must not be serialized.
		local hasProgress = MaxProgressInAccountSV() > 0
			or (type(AJHDB) == "table" and ToNumberOr(AJHDB.jumps, 0) > 0)
		if type(AJHAccount) == "table" and hasProgress then
			EnsureDB()
			if type(AJHDB) == "table" and ToNumberOr(AJHDB.jumps, 0) > 0 then
				CommitFloor()
			end
			-- Ensure AJHFloor exists so Forever's dual-var save stays valid.
			if type(AJHFloor) ~= "table" then
				AJHFloor = {}
			end
			if type(AJHAccount.__floor) == "table" then
				AJHFloor.__best = AJHAccount.__floor
				local key = PlayerKey()
				local name = UnitName("player")
				if key then
					AJHFloor[key] = AJHAccount.__floor
				end
				if type(name) == "string" and name ~= "" then
					AJHFloor[name] = AJHAccount.__floor
				end
			end
			PersistProgressMirror()
		elseif type(AJHAccount) == "table" and not hasProgress then
			-- Blank in-memory account: drop it so Forever is less likely to
			-- overwrite a richer WTF file with zeros.
			AJHAccount = nil
			AJHFloor = nil
			if _G then
				rawset(_G, "AJHAccount", nil)
				rawset(_G, "AJHFloor", nil)
			end
		elseif DEFAULT_CHAT_FRAME and DEV_TOOLS then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cffff6666AJH:|r Account SV missing this session — skipping logout write to protect WTF."
			)
		end
		if DIAG_ENABLED then
			local after = DiagSnapshot("PLAYER_LOGOUT/afterEnsureDB")
			DiagPrintSnapshot(after, false)
			DiagReport("logout")
		end
	elseif event == "UNIT_AURA" then
		if RefreshCampBenefit() and panel and panel:IsShown() then
			panel:Update()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		EnsureDB()
		HealProgressOnLogin()
		RefreshCampBenefit()
		C_Timer.After(0, function()
			if RefreshCampBenefit() and panel and panel:IsShown() then
				panel:Update()
			end
			-- Status bars are laid out by now; re-apply saved Jump XP bar layout.
			RestoreJumpXPBarFromSaved()
		end)
		C_Timer.After(1, RestoreJumpXPBarFromSaved)
		C_Timer.After(3, BroadcastScore)
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...
		if prefix ~= ADDON_PREFIX then
			return
		end
		if not IsAjhAddonChannel(channel) then
			lastGuildRecvNote = string.format("drop-chan prefix=%s chan=%s sender=%s", tostring(prefix), tostring(channel), tostring(sender))
			return
		end
		if type(message) ~= "string" or message == "" then
			return
		end
		-- Trim accidental whitespace / nulls from some clients.
		message = message:match("^([^%z]+)") or message
		message = strtrim(message)
		lastGuildRecvNote = string.format("recv chan=%s sender=%s msg=%s", tostring(channel), tostring(sender), message)
		if message == "R" then
			if GetTime() - lastGuildReply > 2 then
				lastGuildReply = GetTime()
				BroadcastScore()
			end
		else
			-- X:jumps:achMask:xp (new) or S:jumps:achMask / S:jumps (legacy)
			local jumps, achMask, xp = message:match("^X:(%d+):(%d+):(%d+)$")
			if not jumps then
				jumps, achMask = message:match("^S:(%d+):(%d+)$")
				xp = nil
			end
			if not jumps then
				jumps = message:match("^S:(%d+)$")
				achMask = 0
				xp = nil
			end
			if not jumps then
				jumps, achMask, xp = message:match("^S:(%d+):(%d+):(%d+)$")
			end
			jumps = tonumber(jumps)
			achMask = tonumber(achMask) or 0
			xp = tonumber(xp)
			-- Allow 0 jumps; only reject missing parse / sender.
			if jumps == nil or not sender then
				return
			end
			local short = Ambiguate(sender, "short")
			local myKey, myName = PlayerIdentity()
			local boardKey = Ambiguate(sender, "none") or sender
			if myName and short == myName then
				boardKey = myKey or boardKey
			elseif myKey and boardKey == myKey then
				boardKey = myKey
			end
			StoreScore(boardKey, short, jumps, achMask, xp)
			if DEFAULT_CHAT_FRAME and (DEV_TOOLS or (panel and panel:IsShown() and activeTab == "guild")) then
				-- One-line confirm when guild tab is open so we can see arrivals.
				if DEV_TOOLS then
					DEFAULT_CHAT_FRAME:AddMessage(string.format(
						"|cff88ff88AJH:|r Guild score from %s: %d jumps (chan=%s)",
						tostring(short),
						jumps,
						tostring(channel)
					))
				end
			end
			if panel and panel:IsShown() and activeTab == "guild" then
				UpdateLeaderboard()
			end
		end
	end
end)
SLASH_AJH1 = "/ajh"
SLASH_AJH2 = "/jumphabit"
SlashCmdList.AJH = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "guild" or msg == "sync" then
		EnsureDB()
		if GuildRoster then
			pcall(GuildRoster)
		end
		RequestGuildScores()
		UpdateLeaderboard()
		local boardCount = 0
		if type(AJHDB) == "table" and type(AJHDB.board) == "table" then
			for _ in pairs(AJHDB.board) do
				boardCount = boardCount + 1
			end
		end
		local online = IterOnlineGuildNames()
		local prefixOk = "?"
		if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
			prefixOk = tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(ADDON_PREFIX))
		end
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH guild:|r")
		DEFAULT_CHAT_FRAME:AddMessage("  inGuild=" .. tostring(IsInGuild()) .. " prefixReg=" .. prefixOk)
		DEFAULT_CHAT_FRAME:AddMessage("  onlinePeers=" .. tostring(#online) .. " boardRows=" .. tostring(boardCount))
		DEFAULT_CHAT_FRAME:AddMessage("  lastSend=" .. tostring(lastGuildSendNote))
		DEFAULT_CHAT_FRAME:AddMessage("  lastSync=" .. tostring(lastGuildSyncNote))
		DEFAULT_CHAT_FRAME:AddMessage("  lastRecv=" .. tostring(lastGuildRecvNote))
		if #online > 0 then
			DEFAULT_CHAT_FRAME:AddMessage("  peers: " .. table.concat(online, ", "))
		else
			DEFAULT_CHAT_FRAME:AddMessage("  peers: (none online in roster — wait a second and /ajh guild again)")
		end
		return
	end
	if msg == "debug" or msg == "copy" then
		SyncSavedVarsFromGlobal()
		TryHydrateSavedVariablesFromWTF()
		DebugDump("manual /ajh " .. msg)
		ShowDebugCopyFrame(GetDebugLogText())
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Debug window opened — Ctrl+A, Ctrl+C to copy.")
		return
	end
	if msg == "diag" or msg == "diag on" or msg == "diag off" or msg:match("^diag%s") then
		local arg = msg:match("^diag%s*(.*)$") or ""
		arg = strtrim(arg)
		if arg == "on" then
			DIAG_ENABLED = true
			DiagChat("auto diag ON")
			return
		elseif arg == "off" then
			DIAG_ENABLED = false
			DiagChat("auto diag OFF")
			return
		end
		-- Manual dump: snapshot now + verdict from login raw/bind.
		DiagPrintSnapshot(DiagSnapshot("manual/now"), true)
		if diagRawAtAddonLoaded then
			DiagPrintSnapshot(diagRawAtAddonLoaded, true)
		end
		if diagAfterBind then
			DiagPrintSnapshot(diagAfterBind, true)
		end
		DiagReport("manual")
		return
	end
	EnsureDB()
	if msg == "clear" or msg == "reset" then
		ClearAccountProgress()
		local key = PlayerIdentity()
		if key and AJHDB.board then
			AJHDB.board[key] = nil
		end
		BroadcastScore()
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Jump count and XP reset.")
		if panel and panel:IsShown() then
			panel:Update()
		else
			UpdateJumpXPBar()
		end
	elseif msg == "where" then
		local ctx = GetJumpContext()
		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"|cff88ff88AJH:|r Zone: %s  |  Sub: %s  |  Mini: %s  |  Map: %s  |  Instance: %s",
			ctx.zone ~= "" and ctx.zone or "?",
			ctx.sub ~= "" and ctx.sub or "?",
			ctx.mini ~= "" and ctx.mini or "?",
			tostring(ctx.mapID or "?"),
			ctx.instanceType
		))
	else
		TogglePanel()
	end
end
