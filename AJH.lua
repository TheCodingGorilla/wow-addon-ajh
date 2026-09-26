local ADDON_NAME, ns = ...
-- TOC loads AJH.lua before LibEditMode embed; resolve lazily after the lib fills ns.
function ns.GetLibEditMode()
	local lem = ns and ns.LibEditMode
	if lem and lem.AddFrame then
		return lem
	end
	return nil
end

-- Keybind display names. Bindings.xml is auto-loaded by filename ? do NOT
-- list it in the TOC (that parses it as UI XML ? "Unrecognized XML: Binding").
BINDING_HEADER_AJH = "Archindula's Jump Habit"
BINDING_NAME_AJH_TOGGLE = "Toggle Archindula's Jump Habit"

local MAX_LEVEL = 99
local XP_PER_JUMP = 1
local CAMP_XP_MULTIPLIER = 2
local ADDON_PREFIX = "AJH"
local ROW_HEIGHT = 22
local FROG_ICON = "Interface\\Icons\\Spell_Shaman_Hex"
-- Retail achievements vibe: classic yellow achievement badge for the Feats tab portrait.
local FEATS_ICON = "Interface\\Icons\\Achievement_General"

-- Session jump counter (declared early so feat tests can close over it).
local sessionJumps = 0
local lastAcceptedJumpTime = 0
local sessionStartTime = 0

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

function ns.ToNumberOr(value, fallback)
	local n = tonumber(value)
	if n then
		return n
	end
	return fallback
end

-- Layout quality for raise-only merges. Visibility (shown) is intentionally
-- excluded so hiding the bar cannot be blocked as a "demotion".
function ns.JumpXPBarLayoutScore(bar)
	if type(bar) ~= "table" then
		return -1
	end
	local score = 0
	if bar.userPlaced then
		score = score + 100
	end
	local widthPct = ns.ToNumberOr(bar.widthPct, 100)
	if widthPct ~= 100 then
		score = score + 5
	end
	if type(bar.point) == "string" and bar.point ~= "BOTTOM" then
		score = score + 5
	end
	if ns.ToNumberOr(bar.x, 0) ~= 0 or ns.ToNumberOr(bar.y, 55) ~= 55 then
		score = score + 3
	end
	return score
end

function ns.JumpXPBarScore(bar)
	if type(bar) ~= "table" then
		return -1
	end
	local score = ns.JumpXPBarLayoutScore(bar)
	if bar.shown then
		score = score + 10
	end
	return score
end

function ns.CopyJumpXPBarTable(src)
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

function ns.PreferJumpXPBar(destBar, srcBar)
	if ns.JumpXPBarLayoutScore(srcBar) > ns.JumpXPBarLayoutScore(destBar) then
		return ns.CopyJumpXPBarTable(srcBar)
	end
	-- Same layout quality: still prefer a copy that is shown / has shown flag
	-- only when dest has no bar at all.
	if type(destBar) ~= "table" and type(srcBar) == "table" then
		return ns.CopyJumpXPBarTable(srcBar)
	end
	return nil
end

-- Progress lives in account SavedVariable AJHSaved (see TOC).
-- Mutate the loaded table. Client saves on logout /reload.
-- Never invent AJHSaved = {} when the client failed to load it ? that empties the WTF file.
function ns.PlayerKey()
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

function ns.RaiseNumber(dest, key, srcValue)
	local incoming = ns.ToNumberOr(srcValue, nil)
	if type(incoming) ~= "number" then
		return false
	end
	local current = ns.ToNumberOr(dest[key], 0)
	if incoming > current then
		dest[key] = incoming
		return true
	end
	return false
end

function ns.RaiseMergeRecord(dest, src)
	if type(dest) ~= "table" or type(src) ~= "table" or dest == src then
		return false
	end
	local raised = false
	if ns.RaiseNumber(dest, "jumps", src.jumps) then
		raised = true
	end
	if ns.RaiseNumber(dest, "xp", src.xp) then
		raised = true
	end
	if ns.RaiseNumber(dest, "playTime", src.playTime) then
		raised = true
	end
	if ns.RaiseNumber(dest, "jumpActivityTime", src.jumpActivityTime) then
		raised = true
	end
	if ns.RaiseNumber(dest, "sessionJumpHigh", src.sessionJumpHigh) then
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
				elseif ns.ToNumberOr(entry.jumps, 0) > ns.ToNumberOr(existing.jumps, 0) then
					dest.board[key] = entry
					raised = true
				end
			end
		end
	end
	if type(src.jumpXPBar) == "table" then
		local preferred = ns.PreferJumpXPBar(dest.jumpXPBar, src.jumpXPBar)
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
				local preferred = ns.PreferJumpXPBar(dest.jumpXPBarLayouts[layoutName], layout)
				if preferred or type(dest.jumpXPBarLayouts[layoutName]) ~= "table" then
					dest.jumpXPBarLayouts[layoutName] = preferred or ns.CopyJumpXPBarTable(layout)
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

local debugLogLines = {}
local debugCopyFrame

function ns.DebugChat(msg)
	local line = tostring(msg)
	debugLogLines[#debugLogLines + 1] = line
	if #debugLogLines > 200 then
		table.remove(debugLogLines, 1)
	end
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00AJH-DEBUG:|r " .. line)
	end
end

function ns.GetDebugLogText()
	return table.concat(debugLogLines, "\n")
end

function ns.ShowDebugCopyFrame(text)
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
		title:SetText("AJH Debug ? Ctrl+A then Ctrl+C")

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

function ns.DebugDump(tag)
	-- Automatic login dumps only in local-dev. Manual `/ajh copy` always works.
	if not DEV_TOOLS and not (type(tag) == "string" and tag:find("manual", 1, true)) then
		return
	end
	local name = UnitName("player") or "?"
	local jumps = "nil"
	local xp = "nil"
	if type(AJHSaved) == "table" then
		jumps = tostring(ns.ToNumberOr(ns.DB().jumps, 0))
		xp = tostring(ns.ToNumberOr(ns.DB().xp, 0))
	end
	ns.DebugChat("======== " .. tag .. " ========")
	ns.DebugChat("1 player=" .. name .. " addon=" .. tostring(ADDON_NAME))
	ns.DebugChat("2 type(AJHSaved)=" .. type(AJHSaved) .. " jumps=" .. jumps .. " xp=" .. xp)
	ns.DebugChat("======== end ========")
end

function ns.FillDBDefaults(db)
	local jumps = ns.ToNumberOr(db.jumps, nil)
	if type(jumps) ~= "number" then
		jumps = 0
	end
	db.jumps = jumps

	local xp = ns.ToNumberOr(db.xp, nil)
	if type(xp) ~= "number" then
		xp = db.jumps * XP_PER_JUMP
	elseif db.jumps > 0 and xp == db.jumps * 10 then
		xp = db.jumps
	end
	db.xp = xp

	if type(db.board) ~= "table" then
		db.board = {}
	end
	db.minimapPos = ns.ToNumberOr(db.minimapPos, 210)
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
			barDB.x = ns.ToNumberOr(src.x, nil)
		end
		if barDB.y == nil then
			barDB.y = ns.ToNumberOr(src.y, nil)
		end
		if barDB.widthPct == nil then
			barDB.widthPct = ns.ToNumberOr(src.widthPct, nil)
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
		local bestLayout, bestScore = nil, ns.JumpXPBarLayoutScore(barDB)
		for _, data in pairs(layouts) do
			if type(data) == "table" and data.point then
				adoptPos(data)
				local score = ns.JumpXPBarLayoutScore(data)
				if score > bestScore then
					bestLayout, bestScore = data, score
				end
			end
		end
		if bestLayout then
			barDB.point = bestLayout.point or barDB.point
			barDB.x = ns.ToNumberOr(bestLayout.x, barDB.x)
			barDB.y = ns.ToNumberOr(bestLayout.y, barDB.y)
			barDB.widthPct = ns.ToNumberOr(bestLayout.widthPct, barDB.widthPct)
			if bestLayout.userPlaced then
				barDB.userPlaced = true
			end
			-- Do not copy shown from layouts here ? visibility is independent.
		end
	else
		db.jumpXPBarLayouts = {}
	end

	if type(barDB.point) ~= "string" then
		barDB.point = "BOTTOM"
	end
	barDB.x = ns.ToNumberOr(barDB.x, 0) or 0
	barDB.y = ns.ToNumberOr(barDB.y, 55) or 55
	barDB.widthPct = ns.ToNumberOr(barDB.widthPct, 100) or 100
	if barDB.widthPct < 50 then
		barDB.widthPct = 50
	elseif barDB.widthPct > 100 then
		barDB.widthPct = 100
	end
	db.showJumpXPBar = not not barDB.shown

	if db.soundsEnabled == nil then
		db.soundsEnabled = true
	else
		db.soundsEnabled = not not db.soundsEnabled
	end
	db.soundVolume = ns.ToNumberOr(db.soundVolume, 100) or 100
	if db.soundVolume < 0 then
		db.soundVolume = 0
	elseif db.soundVolume > 100 then
		db.soundVolume = 100
	end
	if db.autoAnnounce == nil then
		db.autoAnnounce = false
	else
		db.autoAnnounce = not not db.autoAnnounce
	end
	db.sessionJumpHigh = math.max(0, math.floor(ns.ToNumberOr(db.sessionJumpHigh, 0) or 0))
	db.playTime = math.max(0, ns.ToNumberOr(db.playTime, 0) or 0)
	db.jumpActivityTime = math.max(0, ns.ToNumberOr(db.jumpActivityTime, 0) or 0)
	if type(db.jumpDayKeys) ~= "table" then
		db.jumpDayKeys = {}
	end
	db.announceCount = math.max(0, math.floor(ns.ToNumberOr(db.announceCount, 0) or 0))
end

function ns.RaiseFromOwnBoard(rec)
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
				if ns.RaiseNumber(rec, "jumps", entry.jumps) then
					raised = true
				end
				-- Board only stores jumps; keep xp at least in sync with jumps.
				if ns.RaiseNumber(rec, "xp", entry.jumps) then
					raised = true
				end
			end
		end
	end
	return raised
end

-- Forever sometimes leaves AJHSaved nil after /reload or a full restart even
-- when the WTF file is fine. Creating AJHSaved = {} would then be saved over
-- the good file. Use an ephemeral session table until/unless AJHSaved appears.
local svReady = false
local sessionDB = nil
local liveDB = nil
local warnedMissingSV = false

function ns.AdoptSavedIfPresent()
	if type(AJHSaved) ~= "table" then
		return false
	end
	if sessionDB and sessionDB ~= AJHSaved then
		ns.RaiseMergeRecord(AJHSaved, sessionDB)
		sessionDB = nil
	end
	ns.FillDBDefaults(AJHSaved)
	liveDB = AJHSaved
	return true
end

function ns.EnsureDB()
	if ns.AdoptSavedIfPresent() then
		return AJHSaved
	end
	if not svReady then
		liveDB = nil
		return nil
	end
	if not sessionDB then
		sessionDB = {}
		ns.FillDBDefaults(sessionDB)
		if not warnedMissingSV and DEFAULT_CHAT_FRAME then
			warnedMissingSV = true
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cffff6666AJH:|r Forever failed to load saved progress. This session is temporary and will |cffffcc00not|r overwrite your WTF file. Try another /reload or a full restart later."
			)
		end
	end
	liveDB = sessionDB
	return sessionDB
end

-- Gameplay reads/writes go through ns.DB() so ephemeral sessions work without
-- assigning the empty table to the AJHSaved global (which would wipe WTF).
function ns.DB()
	if type(liveDB) == "table" then
		return liveDB
	end
	return ns.EnsureDB()
end

function ns.TryLateSavedAdopt()
	if not ns.AdoptSavedIfPresent() then
		return
	end
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"|cff88ff88AJH:|r Saved progress loaded late ? %s jumps (%s XP).",
			tostring(AJHSaved.jumps or 0),
			tostring(AJHSaved.xp or 0)
		))
	end
	if panel then
		panel:Update()
	end
	if ns.RestoreJumpXPBarFromSaved then
		ns.RestoreJumpXPBarFromSaved()
	end
end

-- Diagnostics stubs.
local DIAG_ENABLED = false
local diagRawAtAddonLoaded = nil
local diagAfterBind = nil
local diagAtLogout = nil

function ns.DiagChat(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffAJH-DIAG:|r " .. msg)
	end
end

function ns.DiagSnapshot(label)
	return {
		label = label,
		t = GetTime and GetTime() or 0,
		dbType = type(AJHSaved),
		dbJumps = type(AJHSaved) == "table" and ns.ToNumberOr(ns.DB().jumps, 0) or nil,
	}
end

function ns.DiagPrintSnapshot(snap, verbose)
	if not snap then
		ns.DiagChat("no snapshot")
		return
	end
	ns.DiagChat(string.format("[%s] db=%s jumps=%s", snap.label, snap.dbType, tostring(snap.dbJumps)))
end

function ns.DiagReport(tag)
	if not DIAG_ENABLED and tag ~= "manual" then
		return
	end
	ns.DiagChat("--- " .. (tag or "report") .. " ---")
	ns.DiagChat("Simple persistence: AJHSaved only (type=" .. type(AJHSaved) .. ")")
	if type(AJHSaved) == "table" then
		ns.DiagChat("jumps=" .. tostring(ns.ToNumberOr(ns.DB().jumps, 0)) .. " xp=" .. tostring(ns.ToNumberOr(ns.DB().xp, 0)))
	end
end

function ns.ClearAccountProgress()
	local db = ns.EnsureDB()
	if not db then
		return
	end
	db.jumps = 0
	db.xp = 0
end

function ns.GetLevel(xp)
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

function ns.AuraNameMatchesCampBenefit(name)
	if type(name) ~= "string" then
		return false
	end
	return strlower(name):find("camp benefit", 1, true) ~= nil
end

function ns.RememberCampBenefitSpellID(spellID)
	if type(spellID) == "number" and spellID > 0 then
		campBenefitSpellID = spellID
	end
end

function ns.TryFindCampBenefitByName()
	if not (AuraUtil and AuraUtil.FindAuraByName) then
		return nil
	end
	local name, _, _, _, _, _, _, _, _, spellID = AuraUtil.FindAuraByName("Camp Benefit", "player", "HELPFUL")
	return name, spellID
end

function ns.TryGetPlayerAuraBySpellID(spellID)
	if not spellID or not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then
		return nil
	end
	return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

function ns.TryGetAuraDataByIndex(index)
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
		return nil
	end
	return C_UnitAuras.GetAuraDataByIndex("player", index, "HELPFUL")
end

function ns.TryUnitBuffName(index)
	if not UnitBuff then
		return nil
	end
	return UnitBuff("player", index)
end

function ns.ScanCampBenefit()
	-- Prefer name lookup; it is the least secret-hostile path.
	local nameOk, name, spellID = pcall(ns.TryFindCampBenefitByName)
	if not nameOk then
		-- Name lookup tainted/secret. Do not iterate auras; try a known
		-- spell ID if we have one, otherwise leave the multiplier off.
		local idOk, data = pcall(ns.TryGetPlayerAuraBySpellID, campBenefitSpellID)
		return idOk and data ~= nil
	end
	if ns.AuraNameMatchesCampBenefit(name) then
		ns.RememberCampBenefitSpellID(spellID)
		return true
	end

	-- Exact name missed. Scan for substring variants, aborting on taint.
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, data = pcall(ns.TryGetAuraDataByIndex, i)
			if not ok then
				return false
			end
			if not data then
				break
			end
			if ns.AuraNameMatchesCampBenefit(data.name) then
				ns.RememberCampBenefitSpellID(data.spellId)
				return true
			end
		end
		return false
	end

	for i = 1, 40 do
		local ok, buffName = pcall(ns.TryUnitBuffName, i)
		if not ok then
			return false
		end
		if not buffName then
			break
		end
		if ns.AuraNameMatchesCampBenefit(buffName) then
			return true
		end
	end

	return false
end

function ns.RefreshCampBenefit()
	local found = ns.ScanCampBenefit()
	local changed = found ~= campBenefitActive
	campBenefitActive = found
	return changed
end

function ns.HasCampBenefit()
	return campBenefitActive
end

function ns.GetJumpXPGain()
	if campBenefitActive then
		return XP_PER_JUMP * CAMP_XP_MULTIPLIER
	end
	return XP_PER_JUMP
end

function ns.FormatNumber(n)
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

function ns.Solid(frame, r, g, b, a)
	frame:SetColorTexture(r, g, b, a)
end

function ns.PlayerIdentity()
	local name, realm = UnitFullName("player")
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	end
	local key = string.format("%s-%s", name, realm)
	return key, name
end

-- Location feats (English client zone / subzone / minimap names).
-- faction: "Alliance" | "Horde" | "Neutral" ? Neutral stays in Town for everyone;
-- opposite-faction city/town feats resolve into the Hostile category at runtime.
local CITY_LOCATIONS = {
	{ id = "orgrimmar", name = "Orgrimmar", faction = "Horde", match = { "orgrimmar" } },
	{ id = "thunder_bluff", name = "Thunder Bluff", faction = "Horde", match = { "thunder bluff" } },
	{ id = "undercity", name = "Undercity", faction = "Horde", match = { "undercity" }, mapIDs = { 90 } },
	{ id = "stormwind", name = "Stormwind City", faction = "Alliance", match = { "stormwind city", "stormwind" } },
	{ id = "ironforge", name = "Ironforge", faction = "Alliance", match = { "ironforge" } },
	{ id = "darnassus", name = "Darnassus", faction = "Alliance", match = { "darnassus" } },
}

local TOWN_LOCATIONS = {
	-- Horde
	{ id = "brill", name = "Brill", faction = "Horde", match = { "brill" } },
	{ id = "sepulcher", name = "The Sepulcher", faction = "Horde", match = { "the sepulcher", "sepulcher" } },
	{ id = "razor_hill", name = "Razor Hill", faction = "Horde", match = { "razor hill" } },
	{ id = "senjin", name = "Sen'jin Village", faction = "Horde", match = { "sen'jin village" } },
	{ id = "bloodhoof", name = "Bloodhoof Village", faction = "Horde", match = { "bloodhoof village" } },
	{ id = "crossroads", name = "The Crossroads", faction = "Horde", match = { "the crossroads", "crossroads" } },
	{ id = "camp_taurajo", name = "Camp Taurajo", faction = "Horde", match = { "camp taurajo" } },
	{ id = "freewind", name = "Freewind Post", faction = "Horde", match = { "freewind post" } },
	{ id = "sun_rock", name = "Sun Rock Retreat", faction = "Horde", match = { "sun rock retreat" } },
	{ id = "splintertree", name = "Splintertree Post", faction = "Horde", match = { "splintertree post" } },
	{ id = "zorgtars", name = "Zoram'gar Outpost", faction = "Horde", match = { "zoram'gar outpost" } },
	{ id = "tarren_mill", name = "Tarren Mill", faction = "Horde", match = { "tarren mill" } },
	{ id = "hammerfall", name = "Hammerfall", faction = "Horde", match = { "hammerfall" } },
	{ id = "revantusk", name = "Revantusk Village", faction = "Horde", match = { "revantusk village" } },
	{ id = "shadowprey", name = "Shadowprey Village", faction = "Horde", match = { "shadowprey village" } },
	{ id = "camp_mojache", name = "Camp Mojache", faction = "Horde", match = { "camp mojache" } },
	{ id = "brackenwall", name = "Brackenwall Village", faction = "Horde", match = { "brackenwall village" } },
	{ id = "gromgol", name = "Grom'gol Base Camp", faction = "Horde", match = { "grom'gol base camp", "grom'gol" } },
	{ id = "stonard", name = "Stonard", faction = "Horde", match = { "stonard" } },
	{ id = "kargath", name = "Kargath", faction = "Horde", match = { "kargath" } },
	{ id = "valormok", name = "Valormok", faction = "Horde", match = { "valormok" } },
	{ id = "bloodvenom", name = "Bloodvenom Post", faction = "Horde", match = { "bloodvenom post" } },
	-- Alliance
	{ id = "goldshire", name = "Goldshire", faction = "Alliance", match = { "goldshire" } },
	{ id = "kharanos", name = "Kharanos", faction = "Alliance", match = { "kharanos" } },
	{ id = "dolanaar", name = "Dolanaar", faction = "Alliance", match = { "dolanaar" } },
	{ id = "sentinel_hill", name = "Sentinel Hill", faction = "Alliance", match = { "sentinel hill" } },
	{ id = "lakeshire", name = "Lakeshire", faction = "Alliance", match = { "lakeshire" } },
	{ id = "darkshire", name = "Darkshire", faction = "Alliance", match = { "darkshire" } },
	{ id = "menethil", name = "Menethil Harbor", faction = "Alliance", match = { "menethil harbor" } },
	{ id = "thelsamar", name = "Thelsamar", faction = "Alliance", match = { "thelsamar" } },
	{ id = "refuge_pointe", name = "Refuge Pointe", faction = "Alliance", match = { "refuge pointe" } },
	{ id = "southshore", name = "Southshore", faction = "Alliance", match = { "southshore" } },
	{ id = "aerie_peak", name = "Aerie Peak", faction = "Alliance", match = { "aerie peak" } },
	{ id = "chillwind", name = "Chillwind Camp", faction = "Alliance", match = { "chillwind camp" } },
	{ id = "astranaar", name = "Astranaar", faction = "Alliance", match = { "astranaar" } },
	{ id = "auberdine", name = "Auberdine", faction = "Alliance", match = { "auberdine" } },
	{ id = "stonetalon_peak", name = "Stonetalon Peak", faction = "Alliance", match = { "stonetalon peak" } },
	{ id = "nijels_point", name = "Nijel's Point", faction = "Alliance", match = { "nijel's point" } },
	{ id = "feathermoon", name = "Feathermoon Stronghold", faction = "Alliance", match = { "feathermoon stronghold" } },
	{ id = "thalanaar", name = "Thalanaar", faction = "Alliance", match = { "thalanaar" } },
	{ id = "theramore", name = "Theramore Isle", faction = "Alliance", match = { "theramore isle", "theramore" } },
	{ id = "nethergarde", name = "Nethergarde Keep", faction = "Alliance", match = { "nethergarde keep" } },
	{ id = "morgans_vigil", name = "Morgan's Vigil", faction = "Alliance", match = { "morgan's vigil" } },
	{ id = "talrendis", name = "Talrendis Point", faction = "Alliance", match = { "talrendis point" } },
	{ id = "talonbranch", name = "Talonbranch Glade", faction = "Alliance", match = { "talonbranch glade" } },
	-- Neutral / shared hubs
	{ id = "booty_bay", name = "Booty Bay", faction = "Neutral", match = { "booty bay" } },
	{ id = "gadgetzan", name = "Gadgetzan", faction = "Neutral", match = { "gadgetzan" } },
	{ id = "everlook", name = "Everlook", faction = "Neutral", match = { "everlook" } },
	{ id = "ratchet", name = "Ratchet", faction = "Neutral", match = { "ratchet" } },
	{ id = "light_hope", name = "Light's Hope Chapel", faction = "Neutral", match = { "light's hope chapel" } },
	{ id = "cenarion_hold", name = "Cenarion Hold", faction = "Neutral", match = { "cenarion hold" } },
	{ id = "thorium_point", name = "Thorium Point", faction = "Neutral", match = { "thorium point" } },
	{ id = "marshals", name = "Marshal's Refuge", faction = "Neutral", match = { "marshal's refuge" } },
	{ id = "flame_crest", name = "Flame Crest", faction = "Neutral", match = { "flame crest" } },
}

local DUNGEON_LOCATIONS = {
	-- Classic Era complete set
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

function ns.NormName(s)
	return strlower(strtrim(s or ""))
end

function ns.FrameIsShown(frame)
	return frame and frame.IsShown and frame:IsShown()
end

function ns.TodayKey(offsetDays)
	offsetDays = offsetDays or 0
	local t = time() - (offsetDays * 86400)
	return date("%Y-%m-%d", t)
end

function ns.NoteJumpDay()
	local db = ns.EnsureDB()
	if not db then
		return 0
	end
	local key = ns.TodayKey(0)
	db.jumpDayKeys[key] = true
	local streak = 0
	for i = 0, 60 do
		if db.jumpDayKeys[ns.TodayKey(i)] then
			streak = streak + 1
		else
			break
		end
	end
	return streak
end

function ns.CountJumpDays()
	local db = ns.DB()
	if not db or type(db.jumpDayKeys) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(db.jumpDayKeys) do
		n = n + 1
	end
	return n
end

function ns.GetJumpContext(extra)
	extra = extra or {}
	local zone = GetRealZoneText() or GetZoneText() or ""
	local sub = GetSubZoneText() or ""
	local mini = GetMinimapZoneText() or ""
	local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local _, instanceType = IsInInstance()
	instanceType = instanceType or "none"

	local spots = {
		ns.NormName(zone),
		ns.NormName(sub),
		ns.NormName(mini),
	}

	local function inPlace(...)
		for i = 1, select("#", ...) do
			local want = ns.NormName(select(i, ...))
			for _, spot in ipairs(spots) do
				if spot ~= "" and spot == want then
					return true
				end
			end
		end
		return false
	end

	local function spotContains(...)
		for i = 1, select("#", ...) do
			local needle = ns.NormName(select(i, ...))
			if needle ~= "" then
				for _, spot in ipairs(spots) do
					if spot ~= "" and spot:find(needle, 1, true) then
						return true
					end
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

	local hour = 12
	if GetGameTime then
		local h = GetGameTime()
		if type(h) == "number" then
			hour = h
		end
	end

	local pvpType = nil
	if GetZonePVPInfo then
		pvpType = GetZonePVPInfo()
	end

	local indoors = false
	if IsIndoors then
		local ok, v = pcall(IsIndoors)
		indoors = ok and v and true or false
	end

	return {
		zone = zone,
		sub = sub,
		mini = mini,
		mapID = mapID,
		instanceType = instanceType,
		inPlace = inPlace,
		spotContains = spotContains,
		matchesLocation = matchesLocation,
		fromJump = not not extra.fromJump,
		idleGap = tonumber(extra.idleGap) or 0,
		dayStreak = tonumber(extra.dayStreak) or 0,
		combat = UnitAffectingCombat and UnitAffectingCombat("player") or false,
		mounted = IsMounted and IsMounted() or false,
		swimming = (IsSwimming and IsSwimming()) or (IsSubmerged and IsSubmerged()) or false,
		dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") or false,
		ghost = UnitIsGhost and UnitIsGhost("player") or false,
		taxi = UnitOnTaxi and UnitOnTaxi("player") or false,
		grouped = IsInGroup and IsInGroup() or false,
		raid = IsInRaid and IsInRaid() or false,
		camp = ns.HasCampBenefit and ns.HasCampBenefit() or false,
		hour = hour,
		night = hour >= 21 or hour < 5,
		pvpType = pvpType,
		contested = pvpType == "contested",
		indoors = indoors,
		atAuction = ns.FrameIsShown(AuctionFrame) or ns.FrameIsShown(AuctionHouseFrame),
		atMail = ns.FrameIsShown(MailFrame),
		atTrainer = ns.FrameIsShown(ClassTrainerFrame) or ns.FrameIsShown(TrainerFrame),
		onTransport = spotContains(
			"deck",
			"the thundercaller",
			"the purple princess",
			"the maiden's fancy",
			"the bravery",
			"the lady mehley",
			"the moonspray",
			"zee looting boat",
			"the maiden's virtue",
			"zeppelin"
		) or inPlace("the thundercaller", "the purple princess", "the maiden's fancy"),
		gmIsland = inPlace("gm island", "designer island") or spotContains("gm island"),
	}
end

function ns.MakeLocationFeat(loc, baseCategory, requireInstanceType)
	return {
		id = loc.id,
		baseCategory = baseCategory,
		faction = loc.faction,
		isLocation = true,
		requiresJump = true,
		name = loc.name,
		desc = "Jump once in " .. loc.name .. ".",
		test = function(ctx)
			-- Location feats must only unlock on an accepted jump, never on login/zone enter.
			if not ctx or not ctx.fromJump then
				return false
			end
			if requireInstanceType and ctx.instanceType ~= requireInstanceType then
				return false
			end
			return ctx.matchesLocation(loc)
		end,
	}
end

function ns.MakeFeat(id, baseCategory, name, desc, test, opts)
	opts = opts or {}
	return {
		id = id,
		baseCategory = baseCategory,
		name = name,
		desc = desc,
		test = test,
		requiresJump = not not opts.requiresJump,
	}
end

local ACHIEVEMENTS = {}

function ns.AllLocationFeatsEarned(baseCategory)
	local db = ns.DB()
	if not db or type(db.achievements) ~= "table" then
		return false
	end
	local any = false
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ach.isLocation and ns.ResolveFeatCategory(ach) == baseCategory then
			any = true
			if not db.achievements[ach.id] then
				return false
			end
		end
	end
	return any
end

for _, loc in ipairs(CITY_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = ns.MakeLocationFeat(loc, "city")
end
for _, loc in ipairs(TOWN_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = ns.MakeLocationFeat(loc, "town")
end
for _, loc in ipairs(DUNGEON_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = ns.MakeLocationFeat(loc, "dungeon", "party")
end
for _, loc in ipairs(RAID_LOCATIONS) do
	ACHIEVEMENTS[#ACHIEVEMENTS + 1] = ns.MakeLocationFeat(loc, "raid", "raid")
end

-- Non-location feats (habit / style / travel / social / collection / oddities).
do
	local function add(id, cat, name, desc, test, opts)
		ACHIEVEMENTS[#ACHIEVEMENTS + 1] = ns.MakeFeat(id, cat, name, desc, test, opts)
	end
	local JUMP = { requiresJump = true }

	-- Milestone / habit
	add("jumps_100", "milestone", "Century Hopper", "Reach 100 lifetime jumps.", function()
		return ns.DB().jumps >= 100
	end)
	add("jumps_1000", "milestone", "Thousand Hops", "Reach 1,000 lifetime jumps.", function()
		return ns.DB().jumps >= 1000
	end)
	add("jumps_10000", "milestone", "Leg Day Legend", "Reach 10,000 lifetime jumps.", function()
		return ns.DB().jumps >= 10000
	end)
	add("level_10", "milestone", "Getting Air", "Reach Jump Habit level 10.", function()
		return ns.GetLevel(ns.DB().xp) >= 10
	end)
	add("level_40", "milestone", "Serious Bounce", "Reach Jump Habit level 40.", function()
		return ns.GetLevel(ns.DB().xp) >= 40
	end)
	add("level_70", "milestone", "Vertical Authority", "Reach Jump Habit level 70.", function()
		return ns.GetLevel(ns.DB().xp) >= 70
	end)
	add("level_99", "milestone", "Habit Maxed", "Reach Jump Habit level 99.", function()
		return ns.GetLevel(ns.DB().xp) >= 99
	end)
	add("streak_3", "milestone", "Three-Day Tick", "Jump on 3 consecutive calendar days.", function(ctx)
		return (ctx.dayStreak or 0) >= 3
	end, JUMP)
	add("streak_7", "milestone", "Weekly Legs", "Jump on 7 consecutive calendar days.", function(ctx)
		return (ctx.dayStreak or 0) >= 7
	end, JUMP)
	add("streak_30", "milestone", "Monthly Devotion", "Jump on 30 consecutive calendar days.", function(ctx)
		return (ctx.dayStreak or 0) >= 30
	end, JUMP)
	add("session_50", "milestone", "Warm-Up Crush", "Make 50 jumps in a single session.", function()
		return sessionJumps >= 50
	end)
	add("session_200", "milestone", "Session Savage", "Make 200 jumps in a single session.", function()
		return sessionJumps >= 200
	end)

	-- Style / situation (must be an accepted jump in that situation)
	add("camp_jump", "style", "Camp Cadet", "Jump while Camp Benefit is active.", function(ctx)
		return ctx.camp
	end, JUMP)
	add("combat_jump", "style", "Fight Hop", "Jump while in combat.", function(ctx)
		return ctx.combat
	end, JUMP)
	add("mounted_jump", "style", "Saddle Skip", "Jump while mounted.", function(ctx)
		return ctx.mounted
	end, JUMP)
	add("swim_jump", "style", "Splash Hop", "Jump while swimming.", function(ctx)
		return ctx.swimming
	end, JUMP)
	add("indoor_jump", "style", "Ceiling Tester", "Jump while indoors.", function(ctx)
		return ctx.indoors
	end, JUMP)
	add("night_jump", "style", "Midnight Bounce", "Jump between 21:00 and 05:00.", function(ctx)
		return ctx.night
	end, JUMP)

	-- Travel / risk
	add("taxi_jump", "travel", "Bird Brain", "Jump while on a flight path.", function(ctx)
		return ctx.taxi
	end, JUMP)
	add("transport_jump", "travel", "Deck Cadet", "Jump on a boat or zeppelin deck.", function(ctx)
		return ctx.onTransport
	end, JUMP)
	add("contested_jump", "travel", "Orange Zone", "Jump in a contested PvP zone.", function(ctx)
		return ctx.contested
	end, JUMP)
	add("ghost_jump", "travel", "Spectral Skip", "Jump while dead or as a ghost.", function(ctx)
		return ctx.dead or ctx.ghost
	end, JUMP)

	-- Social
	add("party_jump", "social", "Group Bounce", "Jump while in a party.", function(ctx)
		return ctx.grouped and not ctx.raid
	end, JUMP)
	add("raid_jump", "social", "Raid Hop", "Jump while in a raid group.", function(ctx)
		return ctx.raid
	end, JUMP)
	add("announce_5", "social", "Guild Flex", "Announce your Jump Habit status 5 times.", function()
		return (ns.DB().announceCount or 0) >= 5
	end)
	add("announce_25", "social", "Town Crier", "Announce your Jump Habit status 25 times.", function()
		return (ns.DB().announceCount or 0) >= 25
	end)
	add("ajh_peers", "social", "Shared Habit", "Jump while 2+ AJH players are on your guild board.", function()
		local db = ns.DB()
		if type(db.board) ~= "table" then
			return false
		end
		local n = 0
		for _ in pairs(db.board) do
			n = n + 1
			if n >= 2 then
				return true
			end
		end
		return false
	end, JUMP)

	-- Collection / meta (after location feats so same-jump unlocks cascade)
	add("meta_capitals", "collection", "Capital Circuit", "Jump in every capital city (yours and theirs).", function()
		for _, loc in ipairs(CITY_LOCATIONS) do
			if not ns.DB().achievements[loc.id] then
				return false
			end
		end
		return true
	end)
	add("meta_towns_friendly", "collection", "Hometown Hero", "Complete every friendly/neutral Town Jumper feat.", function()
		return ns.AllLocationFeatsEarned("town")
	end)
	add("meta_hostile", "collection", "Enemy Tourism", "Complete every Hostile Territory feat.", function()
		return ns.AllLocationFeatsEarned("hostile")
	end)
	add("meta_dungeons", "collection", "Dungeon Tourist", "Jump in every dungeon.", function()
		return ns.AllLocationFeatsEarned("dungeon")
	end)
	add("meta_raids", "collection", "Raid Tourist", "Jump in every raid.", function()
		return ns.AllLocationFeatsEarned("raid")
	end)

	-- Oddities
	add("ah_jump", "oddity", "Bid High", "Jump with the auction house open.", function(ctx)
		return ctx.atAuction
	end, JUMP)
	add("mail_jump", "oddity", "Postage Due", "Jump with the mailbox open.", function(ctx)
		return ctx.atMail
	end, JUMP)
	add("trainer_jump", "oddity", "Class Is in Session", "Jump with a class trainer open.", function(ctx)
		return ctx.atTrainer
	end, JUMP)
	add("gm_island", "oddity", "Wrong Neighborhood", "Jump on GM Island (if you somehow get there).", function(ctx)
		return ctx.gmIsland
	end, JUMP)
	add("idle_30", "oddity", "Archindula Noticed", "Jump after 30+ minutes without jumping.", function(ctx)
		return (ctx.idleGap or 0) >= 1800
	end, JUMP)
end

local FEAT_CATEGORIES = {
	{ id = "city", name = "City Jumper", desc = "Your faction's capital cities." },
	{ id = "town", name = "Town Jumper", desc = "Friendly and neutral towns." },
	{ id = "hostile", name = "Hostile Territory", desc = "Enemy cities and towns." },
	{ id = "dungeon", name = "Dungeon Jumper", desc = "Every dungeon." },
	{ id = "raid", name = "Raid Jumper", desc = "Every raid." },
	{ id = "milestone", name = "Habit Milestones", desc = "Jumps, levels, streaks, sessions." },
	{ id = "style", name = "Style Points", desc = "Camp, combat, mount, swim, indoors, night." },
	{ id = "travel", name = "Travel & Risk", desc = "Taxi, boats, contested, ghost." },
	{ id = "social", name = "Social Hops", desc = "Party, raid, announces, guild board." },
	{ id = "collection", name = "Collections", desc = "Finish whole location categories." },
	{ id = "oddity", name = "Oddities", desc = "AH, mail, trainer, GM Island, idle." },
}

function ns.GetPlayerFaction()
	local fac = UnitFactionGroup and UnitFactionGroup("player")
	if fac == "Alliance" or fac == "Horde" then
		return fac
	end
	return nil
end

-- City/town feats for the opposite faction show under Hostile; Neutral stays in Town.
function ns.ResolveFeatCategory(ach)
	local base = ach.baseCategory or ach.category
	if base ~= "city" and base ~= "town" then
		return base
	end
	local fac = ach.faction
	if not fac or fac == "Neutral" then
		return base
	end
	local mine = ns.GetPlayerFaction()
	if mine and fac ~= mine then
		return "hostile"
	end
	return base
end

function ns.GetFeatsInCategory(categoryId)
	local list = {}
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ns.ResolveFeatCategory(ach) == categoryId then
			list[#list + 1] = ach
		end
	end
	return list
end

function ns.CountCategoryProgress(categoryId)
	local total, earned = 0, 0
	ns.EnsureDB()
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ns.ResolveFeatCategory(ach) == categoryId then
			total = total + 1
			if ns.DB().achievements[ach.id] then
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
	"Archindula muttered: 'adequate airtime.'",
	"Archindula circled 'good form' on his clipboard.",
	"Archindula says the ground missed you briefly.",
	"Archindula awards you one polite golf clap.",
	"Archindula notes: hopping remains on brand.",
	"Archindula has added a gold star. Tiny one.",
	"Archindula checked the hop. It's... hop-shaped.",
	"Archindula says that one counted. Barely.",
	"Archindula filed a brief report titled 'Up.'",
	"Archindula raises an eyebrow. In approval.",
	"Archindula whispered 'nice' into the void.",
	"Archindula ranks this bounce: guild-acceptable.",
	"Archindula says knees were optional. You used them.",
	"Archindula stamped your ledger: JUMPED.",
	"Archindula almost wrote a poem. He didn't.",
	"Archindula says gravity blinked. You exploited it.",
	"Archindula records another vertical victory.",
	"Archindula nodded twice. That's a lot for him.",
	"Archindula says the floor owed you that distance.",
	"Archindula put it in the 'not embarrassing' pile.",
}


-- Forward declarations (assigned later)
local panel
local activeTab = "habit"
local toastFrame
local toastQueue = {}
local toastBusy = false

function ns.SoundsAllowed()
	-- Before DB exists, allow sounds (defaults are on).
	local db = ns.DB()
	if type(db) ~= "table" then
		return true
	end
	if db.soundsEnabled == false then
		return false
	end
	local vol = ns.ToNumberOr(db.soundVolume, 100) or 100
	return vol > 0
end

function ns.PlayAchievementSound()
	if not ns.SoundsAllowed() then
		return
	end
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

function ns.EnsureToastFrame()
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
	f:SetScale(1)

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
	if title.SetShadowOffset then
		title:SetShadowOffset(2, -2)
		title:SetShadowColor(0, 0, 0, 0.85)
	end
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

function ns.ShowNextToast()
	if toastBusy then
		return
	end
	local toast = tremove(toastQueue, 1)
	if not toast then
		return
	end

	toastBusy = true
	local f = ns.EnsureToastFrame()
	f.banner:SetText(toast.banner or "FEAT UNLOCKED")
	f.title:SetText(toast.name or "")
	f.pride:SetText(PRIDE_LINES[math.random(1, #PRIDE_LINES)])

	ns.PlayAchievementSound()

	f:Show()
	f:SetAlpha(0)

	local elapsed = 0
	local fadeIn = 0.35
	local holdUntil = 7.0
	local fadeOut = 1.25
	local total = holdUntil + fadeOut

	-- Alpha only ? SetScale every frame forces full layout and looks jumpy.
	f:SetScript("OnUpdate", function(self, dt)
		elapsed = elapsed + dt
		if elapsed < fadeIn then
			self:SetAlpha(elapsed / fadeIn)
		elseif elapsed < holdUntil then
			self:SetAlpha(1)
		elseif elapsed < total then
			self:SetAlpha(1 - ((elapsed - holdUntil) / fadeOut))
		else
			self:SetScript("OnUpdate", nil)
			self:SetAlpha(0)
			self:Hide()
			toastBusy = false
			ns.ShowNextToast()
		end
	end)
end

function ns.QueueToast(toast)
	tinsert(toastQueue, toast)
	ns.ShowNextToast()
end

function ns.QueueAchievementToast(ach)
	ns.QueueToast({
		banner = "FEAT UNLOCKED",
		name = ach.name,
		desc = ach.desc,
	})
end

function ns.AnnounceLevelUp(newLevel)
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

	ns.QueueToast({
		banner = "YOUR JUMP HABIT",
		name = string.format("IS NOW LEVEL %d!", newLevel),
		desc = detail,
	})
end

function ns.GetAchievementMask()
	-- Legacy bitmask for older peers. Cap at 31 bits so "%d" / C int paths
	-- never overflow (location feats alone exceed 32/53-bit masks).
	ns.EnsureDB()
	local mask = 0
	local limit = math.min(#ACHIEVEMENTS, 31)
	for i = 1, limit do
		local ach = ACHIEVEMENTS[i]
		if ach and ns.DB().achievements[ach.id] then
			mask = mask + (2 ^ (i - 1))
		end
	end
	return mask
end

function ns.CountAchievementsFromMask(mask)
	mask = tonumber(mask) or 0
	local n = 0
	local limit = math.min(#ACHIEVEMENTS, 31)
	for i = 1, limit do
		local bitv = 2 ^ (i - 1)
		if math.floor(mask / bitv) % 2 == 1 then
			n = n + 1
		end
	end
	return n
end

function ns.CountOwnAchievements()
	ns.EnsureDB()
	local n = 0
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ns.DB().achievements[ach.id] then
			n = n + 1
		end
	end
	return n
end

function ns.UnlockAchievement(ach)
	ns.EnsureDB()
	if ns.DB().achievements[ach.id] then
		return false
	end

	ns.DB().achievements[ach.id] = time()
	DEFAULT_CHAT_FRAME:AddMessage(string.format(
		"|cff88ff88AJH:|r Feat unlocked: |cffffffff%s|r - %s",
		ach.name,
		ach.desc
	))

	ns.QueueAchievementToast(ach)

	if ns.DB().autoAnnounce and IsInGuild() then
		SendChatMessage(
			string.format("Jump Habit Feat: %s - %s", ach.name, ach.desc),
			"GUILD"
		)
	end

	ns.BroadcastScore()
	return true
end

function ns.CheckAchievementsOnJump(extra)
	ns.EnsureDB()
	extra = extra or {}
	local fromJump = not not extra.fromJump
	extra.fromJump = fromJump
	local ctx = ns.GetJumpContext(extra)
	local earned = false
	for _, ach in ipairs(ACHIEVEMENTS) do
		if not ns.DB().achievements[ach.id] then
			-- Location / situational feats only on an accepted jump (never login/zone).
			if (ach.isLocation or ach.requiresJump) and not fromJump then
				-- skip
			elseif ach.test(ctx) then
				if ns.UnlockAchievement(ach) then
					earned = true
				end
			end
		end
	end
	return earned
end

-- Progress-only feats (milestones, announce counts, collections). Safe on login.
function ns.CheckAchievementsGeneral()
	return ns.CheckAchievementsOnJump({
		fromJump = false,
		dayStreak = ns.CountJumpDays() > 0 and ns.NoteJumpDay() or 0,
	})
end

function ns.ResetAchievements()
	ns.EnsureDB()
	ns.DB().achievements = {}
	ns.BroadcastScore()
	DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Feats reset for testing.")
	if panel and panel:IsShown() then
		if activeTab == "achieves" then
			ns.UpdateAchievements()
		elseif activeTab == "guild" then
			ns.UpdateLeaderboard()
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
	statsView = "main", -- "main" or "levels"
}
local lastGuildReply = 0
local jumpXPBar
-- Movable HUD bar only. Habit dialog bar uses HABIT_PANEL_XP_BAR_HEIGHT.
local JUMP_XP_BAR_HEIGHT = 14
local HABIT_PANEL_XP_BAR_HEIGHT = 22

-- Session statistics (not SavedVariables), except playTime / sessionJumpHigh in AJHSaved.
-- sessionJumps / lastAcceptedJumpTime / sessionStartTime declared near top of file.
local JUMP_TIME_RING_SIZE = 200
local jumpTimeRing = {}
local jumpTimeRingCount = 0
local jumpTimeRingNext = 1
-- Seconds of play already credited into ns.DB().playTime this login.
local playTimeFlushed = 0
local playTimeTicker
-- Attributed active time per accepted jump (matches jump cooldown cadence).
local JUMP_ACTIVITY_SEC = 0.8

function ns.EnsureSessionClock()
	if sessionStartTime <= 0 then
		sessionStartTime = GetTime()
	end
end

function ns.CurrentSessionElapsed()
	ns.EnsureSessionClock()
	return math.max(0, GetTime() - sessionStartTime)
end

function ns.FlushPlayTime()
	local db = ns.EnsureDB()
	if not db then
		return
	end
	local elapsed = ns.CurrentSessionElapsed()
	local delta = elapsed - playTimeFlushed
	if delta > 0 then
		db.playTime = (ns.ToNumberOr(db.playTime, 0) or 0) + delta
		playTimeFlushed = elapsed
	end
end

function ns.LifetimePlayTime()
	local db = ns.EnsureDB()
	if not db then
		return 0
	end
	ns.FlushPlayTime()
	return ns.ToNumberOr(db.playTime, 0) or 0
end

function ns.LifetimeJumpActivityTime()
	local db = ns.EnsureDB()
	if not db then
		return 0
	end
	return ns.ToNumberOr(db.jumpActivityTime, 0) or 0
end

function ns.NoteJumpActivity()
	local db = ns.EnsureDB()
	if not db then
		return
	end
	ns.FlushPlayTime()
	db.jumpActivityTime = (ns.ToNumberOr(db.jumpActivityTime, 0) or 0) + JUMP_ACTIVITY_SEC
end

function ns.FormatJumpIdlePct(jumpSec, totalSec)
	if not totalSec or totalSec <= 0 then
		return "?"
	end
	local jumpPct = math.min(100, (jumpSec / totalSec) * 100)
	local idlePct = math.max(0, 100 - jumpPct)
	return string.format("%.0f%% jumping ? %.0f%% idle", jumpPct, idlePct)
end

function ns.RecordSessionJump(now)
	ns.EnsureSessionClock()
	sessionJumps = sessionJumps + 1
	lastAcceptedJumpTime = now
	jumpTimeRing[jumpTimeRingNext] = now
	jumpTimeRingNext = (jumpTimeRingNext % JUMP_TIME_RING_SIZE) + 1
	if jumpTimeRingCount < JUMP_TIME_RING_SIZE then
		jumpTimeRingCount = jumpTimeRingCount + 1
	end
end

function ns.NoteSessionJumpHigh()
	ns.EnsureDB()
	local high = ns.DB().sessionJumpHigh or 0
	if sessionJumps > high then
		ns.DB().sessionJumpHigh = sessionJumps
	end
end

function ns.CountJumpsInWindow(windowSec)
	local cutoff = GetTime() - windowSec
	local n = 0
	for i = 1, jumpTimeRingCount do
		local t = jumpTimeRing[i]
		if t and t >= cutoff then
			n = n + 1
		end
	end
	return n
end

function ns.FormatDuration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	if h > 0 then
		return string.format("%dh %dm", h, m)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", s)
end

local statsTicker

function ns.StopStatsTicker()
	if statsTicker then
		statsTicker:Cancel()
		statsTicker = nil
	end
end

function ns.StartStatsTicker()
	ns.StopStatsTicker()
	if not (C_Timer and C_Timer.NewTicker) then
		return
	end
	statsTicker = C_Timer.NewTicker(1, function()
		if not panel or not panel:IsShown() or activeTab ~= "stats" or ui.statsView ~= "main" then
			ns.StopStatsTicker()
			return
		end
		panel:Update()
	end)
end

function ns.SyncStatsTicker()
	if panel and panel:IsShown() and activeTab == "stats" and ui.statsView == "main" then
		if not statsTicker then
			ns.StartStatsTicker()
		end
	else
		ns.StopStatsTicker()
	end
end

function ns.ShowStatsView(view)
	ui.statsView = view or "main"
	if ui.statsMain then
		ui.statsMain:SetShown(ui.statsView == "main")
	end
	if ui.statsLevels then
		ui.statsLevels:SetShown(ui.statsView == "levels")
	end
	if ui.statsView == "levels" and ui.levelScroll then
		ns.EnsureDB()
		local level = ns.GetLevel(ns.DB().xp)
		local function TryScroll(attempt)
			if type(ns.ScrollLevelsToCurrent) ~= "function" then
				return
			end
			local scroll = ui.levelScroll
			if scroll and (scroll:GetHeight() or 0) > 0 then
				ns.ScrollLevelsToCurrent(level)
				return
			end
			if (attempt or 0) < 8 then
				C_Timer.After(0.05, function()
					TryScroll((attempt or 0) + 1)
				end)
			end
		end
		C_Timer.After(0, function()
			TryScroll(0)
		end)
	end
	ns.SyncStatsTicker()
end

function ns.IsEditModeActive()
	local LibEditMode = ns.GetLibEditMode()
	if LibEditMode and LibEditMode.IsInEditMode then
		return LibEditMode:IsInEditMode()
	end
	return EditModeManagerFrame and EditModeManagerFrame:IsShown()
end

function ns.TrySetAtlas(texture, atlas, useAtlasSize)
	if not texture or not atlas then
		return false
	end
	if C_Texture and C_Texture.GetAtlasInfo then
		local info = C_Texture.GetAtlasInfo(atlas)
		if not info then
			return false
		end
	end
	if useAtlasSize == nil then
		useAtlasSize = true
	end
	return pcall(texture.SetAtlas, texture, atlas, useAtlasSize)
end

function ns.MatchDefaultStatusBarWidth()
	-- Use on-screen span (GetRight-GetLeft) so we match the visible XP / status
	-- bar even when GetWidth() is stale, scaled, or a half-size fallback.
	-- Do NOT fall back to MainMenuBar / UIParent ? those are much wider than the
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

function ns.DefaultJumpXPBarOffsetY()
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

function ns.CopyJumpXPBarState(src)
	return {
		shown = not not (src and src.shown),
		point = (src and src.point) or JUMP_XP_BAR_DEFAULT.point,
		x = ns.ToNumberOr(src and src.x, JUMP_XP_BAR_DEFAULT.x) or JUMP_XP_BAR_DEFAULT.x,
		y = ns.ToNumberOr(src and src.y, JUMP_XP_BAR_DEFAULT.y) or JUMP_XP_BAR_DEFAULT.y,
		widthPct = ns.ToNumberOr(src and src.widthPct, JUMP_XP_BAR_DEFAULT.widthPct) or JUMP_XP_BAR_DEFAULT.widthPct,
		userPlaced = not not (src and src.userPlaced),
	}
end

function ns.GetJumpXPBarSaved()
	ns.EnsureDB()
	local barDB = ns.DB().jumpXPBar
	barDB.point = type(barDB.point) == "string" and barDB.point or JUMP_XP_BAR_DEFAULT.point
	barDB.x = ns.ToNumberOr(barDB.x, JUMP_XP_BAR_DEFAULT.x) or JUMP_XP_BAR_DEFAULT.x
	barDB.y = ns.ToNumberOr(barDB.y, JUMP_XP_BAR_DEFAULT.y) or JUMP_XP_BAR_DEFAULT.y
	barDB.widthPct = ns.ToNumberOr(barDB.widthPct, 100) or 100
	if barDB.widthPct < 50 then
		barDB.widthPct = 50
	elseif barDB.widthPct > 100 then
		barDB.widthPct = 100
	end
	barDB.shown = not not barDB.shown
	ns.DB().showJumpXPBar = barDB.shown
	return barDB
end

function ns.GetJumpXPBarState()
	if jumpXPBarDraft then
		return jumpXPBarDraft
	end
	return ns.GetJumpXPBarSaved()
end

function ns.ApplyJumpXPBarLayout(holder, state)
	if not holder then
		return
	end
	state = state or ns.GetJumpXPBarState()
	local full = ns.MatchDefaultStatusBarWidth()
	local widthPct = ns.ToNumberOr(state.widthPct, 100) or 100
	if widthPct < 50 then
		widthPct = 50
	elseif widthPct > 100 then
		widthPct = 100
	end
	local width = full * (widthPct / 100)
	local point = (type(state.point) == "string" and state.point) or "BOTTOM"
	local x = ns.ToNumberOr(state.x, 0) or 0
	local y = ns.ToNumberOr(state.y, 55) or 55
	holder:SetSize(width, JUMP_XP_BAR_HEIGHT)
	holder:ClearAllPoints()
	holder:SetPoint(point, UIParent, point, x, y)
	if holder.LayoutChrome then
		holder:LayoutChrome()
	end
end

function ns.RestoreJumpXPBarFromSaved()
	if not jumpXPBar then
		return
	end
	JUMP_XP_BAR_DEFAULT.y = ns.DefaultJumpXPBarOffsetY()
	ns.ApplyJumpXPBarLayout(jumpXPBar, ns.GetJumpXPBarSaved())
	ns.UpdateJumpXPBar()
end

function ns.CommitJumpXPBarState(state, opts)
	ns.EnsureDB()
	state = state or ns.GetJumpXPBarState()
	opts = opts or {}
	local barDB = ns.DB().jumpXPBar

	-- Visibility always updates (hide button must work).
	if state.shown ~= nil then
		barDB.shown = not not state.shown
		ns.DB().showJumpXPBar = barDB.shown
	end

	if opts.visibilityOnly then
		return
	end

	local proposed = {
		shown = barDB.shown,
		point = state.point or barDB.point or "BOTTOM",
		x = tonumber(state.x)
			or ns.ToNumberOr(barDB.x, 0)
			or 0,
		y = tonumber(state.y)
			or ns.ToNumberOr(barDB.y, 55)
			or 55,
		widthPct = tonumber(state.widthPct)
			or ns.ToNumberOr(barDB.widthPct, 100)
			or 100,
		userPlaced = not not (state.userPlaced or barDB.userPlaced),
	}
	if proposed.widthPct < 50 then
		proposed.widthPct = 50
	elseif proposed.widthPct > 100 then
		proposed.widthPct = 100
	end

	-- Raise-only for position/size. Defaults cannot replace a customized bar.
	if ns.JumpXPBarLayoutScore(proposed) < ns.JumpXPBarLayoutScore(barDB) then
		return
	end
	-- Ignore non-userPlaced writes that look like Edit Mode defaults when we
	-- already have any customized layout saved.
	if not proposed.userPlaced and ns.JumpXPBarLayoutScore(barDB) > 0 then
		return
	end

	barDB.point = proposed.point
	barDB.x = proposed.x
	barDB.y = proposed.y
	barDB.widthPct = proposed.widthPct
	if proposed.userPlaced then
		barDB.userPlaced = true
	end

	if type(ns.DB().jumpXPBarLayouts) ~= "table" then
		ns.DB().jumpXPBarLayouts = {}
	end
	-- Only snapshot into Edit Mode layouts when the player actually placed it.
	if barDB.userPlaced then
		local layoutName = "Modern"
		local LibEditMode = ns.GetLibEditMode()
		if LibEditMode and LibEditMode.GetActiveLayoutName then
			layoutName = LibEditMode:GetActiveLayoutName() or layoutName
		end
		local layoutCopy = ns.CopyJumpXPBarState(barDB)
		local existingLayout = ns.DB().jumpXPBarLayouts[layoutName]
		if ns.JumpXPBarLayoutScore(layoutCopy) >= ns.JumpXPBarLayoutScore(existingLayout) then
			ns.DB().jumpXPBarLayouts[layoutName] = layoutCopy
		end
	end

end

function ns.PersistJumpXPBarDraft()
	if jumpXPBarDraft and jumpXPBarEditDirty then
		ns.CommitJumpXPBarState(jumpXPBarDraft)
	end
end

function ns.MarkJumpXPBarEditDirty()
	if not ns.IsEditModeActive() then
		return
	end
	jumpXPBarEditDirty = true
	ns.PersistJumpXPBarDraft()
	if EditModeManagerFrame and EditModeManagerFrame.SetHasActiveChanges then
		pcall(EditModeManagerFrame.SetHasActiveChanges, EditModeManagerFrame, true)
	end
end

function ns.BeginJumpXPBarEditSession()
	ns.EnsureDB()
	local saved = ns.GetJumpXPBarSaved()
	jumpXPBarBaseline = ns.CopyJumpXPBarState(saved)
	jumpXPBarDraft = ns.CopyJumpXPBarState(saved)
	jumpXPBarEditDirty = false
end

function ns.CommitJumpXPBarEditSession()
	if not jumpXPBarDraft then
		return
	end
	if jumpXPBarEditDirty then
		jumpXPBarDraft.shown = true
		jumpXPBarDraft.userPlaced = true
		ns.CommitJumpXPBarState(jumpXPBarDraft)
	end
	jumpXPBarBaseline = ns.CopyJumpXPBarState(jumpXPBarDraft)
	jumpXPBarDraft = ns.CopyJumpXPBarState(jumpXPBarDraft)
	jumpXPBarEditDirty = false
	ns.UpdateJumpXPBar()
end

function ns.RevertJumpXPBarEditSession()
	if not jumpXPBarBaseline then
		jumpXPBarDraft = nil
		jumpXPBarEditDirty = false
		return
	end
	jumpXPBarDraft = ns.CopyJumpXPBarState(jumpXPBarBaseline)
	jumpXPBarEditDirty = false
	if jumpXPBar then
		ns.ApplyJumpXPBarLayout(jumpXPBar, jumpXPBarDraft)
	end
	ns.UpdateJumpXPBar()
end

function ns.EndJumpXPBarEditSession()
	if jumpXPBarDraft and jumpXPBarEditDirty then
		jumpXPBarDraft.shown = true
		jumpXPBarDraft.userPlaced = true
		ns.CommitJumpXPBarState(jumpXPBarDraft)
	end
	jumpXPBarDraft = nil
	jumpXPBarBaseline = nil
	jumpXPBarEditDirty = false
	ns.UpdateJumpXPBar()
end

function ns.AnnounceStatus(channel)
	ns.EnsureDB()
	channel = string.upper(channel or "")
	if channel == "GUILD" and not IsInGuild() then
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r You are not in a guild.")
		return false
	end
	if channel == "PARTY" and not (IsInGroup and IsInGroup()) then
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r You are not in a party.")
		return false
	end
	local level = ns.GetLevel(ns.DB().xp)
	local jumps = ns.DB().jumps
	SendChatMessage(
		string.format(
			"Jump Habit: Level %d - %s jump%s",
			level,
			ns.FormatNumber(jumps),
			jumps == 1 and "" or "s"
		),
		channel
	)
	ns.DB().announceCount = (ns.ToNumberOr(ns.DB().announceCount, 0) or 0) + 1
	if ns.CheckAchievementsGeneral() and panel and panel:IsShown() and activeTab == "achieves" then
		ns.UpdateAchievements()
	end
	return true
end

local announceDialog

function ns.HideAnnounceDialog()
	if announceDialog then
		announceDialog:Hide()
	end
end

function ns.ShowAnnounceDialog()
	if not announceDialog then
		local f = CreateFrame("Frame", "AJHAnnounceDialog", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		f:SetSize(280, 220)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetFrameLevel(200)
		f:EnableMouse(true)
		f:SetMovable(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true,
				tileSize = 32,
				edgeSize = 32,
				insets = { left = 8, right = 8, top = 8, bottom = 8 },
			})
		end
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -18)
		title:SetText("Announce Jump Habit")
		title:SetTextColor(1, 0.82, 0)
		local prompt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		prompt:SetPoint("TOP", title, "BOTTOM", 0, -10)
		prompt:SetText("Choose a channel:")

		local prev = prompt
		local function MakeChannelButton(label, channel)
			local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
			btn:SetSize(160, 24)
			btn:SetPoint("TOP", prev, "BOTTOM", 0, -10)
			btn:SetText(label)
			btn:SetScript("OnClick", function()
				ns.AnnounceStatus(channel)
				ns.HideAnnounceDialog()
			end)
			prev = btn
			return btn
		end

		MakeChannelButton("Say", "SAY")
		MakeChannelButton("Party", "PARTY")
		MakeChannelButton("Guild", "GUILD")

		local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		cancel:SetSize(80, 24)
		cancel:SetPoint("TOP", prev, "BOTTOM", 0, -14)
		cancel:SetText("Cancel")
		cancel:SetScript("OnClick", ns.HideAnnounceDialog)

		tinsert(UISpecialFrames, "AJHAnnounceDialog")
		announceDialog = f
	end
	announceDialog:Show()
	announceDialog:Raise()
end

function ns.UpdateJumpXPBarToggleLabel()
	if ui.jumpXPBarCheck then
		ui.jumpXPBarCheck:SetChecked(not not ns.GetJumpXPBarSaved().shown)
	end
end

function ns.UpdateJumpXPBar()
	ns.EnsureDB()
	ns.UpdateJumpXPBarToggleLabel()
	if not jumpXPBar then
		return
	end

	local state = ns.GetJumpXPBarState()
	local editing = ns.IsEditModeActive()
	if not state.shown and not editing then
		jumpXPBar:Hide()
		return
	end

	if not jumpXPBar.isMoving then
		ns.ApplyJumpXPBarLayout(jumpXPBar, state)
	end

	local xp = ns.DB().xp
	local jumps = ns.DB().jumps
	local level = ns.GetLevel(xp)
	local intoLevel, needed, remaining, pct

	if level >= MAX_LEVEL then
		intoLevel = xp - xpForLevel[MAX_LEVEL]
		needed = 1
		remaining = 0
		pct = 100
		jumpXPBar.bar:SetMinMaxValues(0, 1)
		jumpXPBar.bar:SetValue(1)
		if jumpXPBar.text then
			jumpXPBar.text:SetText(string.format("Level %d  MAX", level))
		end
	else
		intoLevel = xp - xpForLevel[level]
		needed = xpForLevel[level + 1] - xpForLevel[level]
		remaining = needed - intoLevel
		pct = needed > 0 and math.floor((intoLevel / needed) * 100 + 0.5) or 0
		jumpXPBar.bar:SetMinMaxValues(0, needed)
		jumpXPBar.bar:SetValue(intoLevel)
		if jumpXPBar.text then
			jumpXPBar.text:SetText(string.format("Level %d  %d%%", level, pct))
		end
	end

	jumpXPBar.tipLevel = level
	jumpXPBar.tipInto = intoLevel
	jumpXPBar.tipNeeded = needed
	jumpXPBar.tipRemaining = remaining
	jumpXPBar.tipJumps = jumps
	jumpXPBar.tipMax = level >= MAX_LEVEL
	jumpXPBar.tipPct = pct

	if editing and not state.shown then
		jumpXPBar:SetAlpha(0.65)
	else
		jumpXPBar:SetAlpha(1)
	end
	jumpXPBar:Show()
end

function ns.SetJumpXPBarShown(shown)
	ns.EnsureDB()
	local state = ns.GetJumpXPBarState()
	state.shown = not not shown
	-- Visibility only ? never touch position/size (and never block hide).
	ns.CommitJumpXPBarState(state, { visibilityOnly = true })
	if jumpXPBarDraft then
		jumpXPBarDraft.shown = state.shown
	end
	ns.UpdateJumpXPBar()
end

function ns.SetupJumpXPBarEditMode(holder)
	local LibEditMode = ns.GetLibEditMode()
	if holder.editModeReady or not LibEditMode then
		return
	end
	holder.editModeReady = true
	holder.editModeName = "Jump Habit XP Bar"

	JUMP_XP_BAR_DEFAULT.y = ns.DefaultJumpXPBarOffsetY()

	LibEditMode:AddFrame(holder, function(frame, _layoutName, point, x, y)
		-- Ignore spurious callbacks outside Edit Mode (would lock in defaults).
		if not ns.IsEditModeActive() then
			ns.ApplyJumpXPBarLayout(frame, ns.GetJumpXPBarSaved())
			return
		end
		local state = ns.GetJumpXPBarState()
		state.point, state.x, state.y = point, x, y
		state.shown = true
		state.userPlaced = true
		if jumpXPBarDraft then
			ns.MarkJumpXPBarEditDirty()
		else
			ns.CommitJumpXPBarState(state)
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
				return ns.GetJumpXPBarState().widthPct
			end,
			set = function(_layoutName, value, _fromReset)
				if not ns.IsEditModeActive() and not _fromReset then
					return
				end
				-- Ignore Reset-to-default while we already have a custom layout.
				if _fromReset and ns.GetJumpXPBarSaved().userPlaced then
					return
				end
				local state = ns.GetJumpXPBarState()
				state.widthPct = value
				state.shown = true
				state.userPlaced = true
				if jumpXPBarDraft then
					ns.MarkJumpXPBarEditDirty()
				else
					ns.CommitJumpXPBarState(state)
				end
				if jumpXPBar then
					ns.ApplyJumpXPBarLayout(jumpXPBar, state)
				end
			end,
		},
	})

	LibEditMode:RegisterCallback("enter", function()
		ns.EnsureDB()
		ns.BeginJumpXPBarEditSession()
		ns.UpdateJumpXPBar()
	end)

	LibEditMode:RegisterCallback("exit", function()
		ns.EndJumpXPBarEditSession()
	end)

	-- Edit Mode layout info arrives after ADDON_LOADED; re-apply saved bar then.
	LibEditMode:RegisterCallback("layout", function()
		ns.RestoreJumpXPBarFromSaved()
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
				ns.CommitJumpXPBarEditSession()
			end)
		end
		if EditModeManagerFrame.RevertAllChanges then
			hooksecurefunc(EditModeManagerFrame, "RevertAllChanges", function()
				ns.RevertJumpXPBarEditSession()
			end)
		end
		EventRegistry:RegisterCallback("EditMode.SavedLayouts", function()
			ns.CommitJumpXPBarEditSession()
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

	ns.RestoreJumpXPBarFromSaved()
end

function ns.BuildJumpXPBar()
	if jumpXPBar then
		return jumpXPBar
	end

	ns.EnsureDB()

	-- 1.2.0 Status-tracking XP chrome (HUD atlases) with classic UI-XP-Bar fallback.
	-- Fill tinted Habit-dialog yellow (1.0, 0.82, 0).
	local holder = CreateFrame("Frame", "AJHJumpXPBar", UIParent)
	holder:SetFrameStrata("MEDIUM")
	holder:SetFrameLevel(50)
	holder:EnableMouse(true)
	holder:Hide()

	local barBg = holder:CreateTexture(nil, "BACKGROUND", nil, -1)
	barBg:SetPoint("TOPLEFT", 1, -1)
	barBg:SetPoint("BOTTOMRIGHT", -1, 1)
	local usedHudBg = ns.TrySetAtlas(barBg, "UI-HUD-ExperienceBar-Background")
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
	if ns.TrySetAtlas(statusTex, "UI-HUD-ExperienceBar-Fill") then
		fillOk = true
		statusTex:SetVertexColor(1.0, 0.82, 0.0)
		bar:SetStatusBarColor(1, 1, 1)
	end
	if not fillOk then
		bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
		local tex = bar:GetStatusBarTexture()
		if tex then
			tex:SetHorizTile(false)
		end
		bar:SetStatusBarColor(1.0, 0.82, 0.0)
	end

	local hudFrame = holder:CreateTexture(nil, "OVERLAY", nil, 7)
	hudFrame:SetAllPoints()
	local usedHudFrame = ns.TrySetAtlas(hudFrame, "UI-HUD-ExperienceBar-Frame")
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
		if ns.IsEditModeActive() then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Jump Habit Experience", 1.0, 0.82, 0.0)
		if self.tipMax then
			GameTooltip:AddLine(string.format("Level %d (max)", self.tipLevel or MAX_LEVEL), 1, 1, 1)
			GameTooltip:AddLine(
				string.format("XP past max: %s", ns.FormatNumber(self.tipInto or 0)),
				0.9, 0.9, 0.9
			)
		else
			GameTooltip:AddLine(string.format("Level %d", self.tipLevel or 1), 1, 1, 1)
			GameTooltip:AddLine(
				string.format(
					"%s / %s XP this level",
					ns.FormatNumber(self.tipInto or 0),
					ns.FormatNumber(self.tipNeeded or 0)
				),
				0.9, 0.9, 0.9
			)
			GameTooltip:AddLine(
				string.format("%s XP remaining", ns.FormatNumber(self.tipRemaining or 0)),
				0.9, 0.9, 0.9
			)
		end
		GameTooltip:AddLine(
			string.format("Total jumps: %s", ns.FormatNumber(self.tipJumps or 0)),
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

	ns.ApplyJumpXPBarLayout(holder)
	ns.SetupJumpXPBarEditMode(holder)
	if not holder.editModeReady then
		C_Timer.After(0, function()
			if jumpXPBar and not jumpXPBar.editModeReady then
				ns.SetupJumpXPBarEditMode(jumpXPBar)
			end
		end)
	end
	ns.UpdateJumpXPBar()
	return holder
end

function ns.StoreScore(key, name, jumps, achMask, xp, achs)
	local db = ns.EnsureDB()
	if not db then
		return
	end
	if type(db.board) ~= "table" then
		db.board = {}
	end
	local jumpsN = tonumber(jumps) or 0
	local xpN = tonumber(xp)
	if not xpN or xpN < 0 then
		-- Legacy peers only sent jumps; approximate XP from jumps.
		xpN = jumpsN
	end
	local achsN = tonumber(achs)
	if achsN == nil then
		-- Legacy: derive a (possibly truncated) count from the bitmask.
		achsN = ns.CountAchievementsFromMask(achMask)
	end
	local prev = db.board[key]
	-- Raise-only so a stale broadcast cannot demote a richer row.
	if type(prev) == "table" then
		if ns.ToNumberOr(prev.jumps, 0) > jumpsN then
			jumpsN = ns.ToNumberOr(prev.jumps, 0)
		end
		if ns.ToNumberOr(prev.xp, 0) > xpN then
			xpN = ns.ToNumberOr(prev.xp, 0)
		end
		if ns.ToNumberOr(prev.achs, 0) > achsN then
			achsN = ns.ToNumberOr(prev.achs, 0)
		end
	end
	db.board[key] = {
		name = name or (type(prev) == "table" and prev.name) or key,
		jumps = jumpsN,
		xp = xpN,
		achs = achsN,
		achMask = tonumber(achMask) or (type(prev) == "table" and prev.achMask) or 0,
		updated = time(),
	}
end

function ns.SendGuildAddonMessage(message)
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

function ns.SendWhisperAddonMessage(message, target)
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

function ns.IterOnlineGuildNames()
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

function ns.BroadcastScorePayload(message)
	local guildOk, guildResult = ns.SendGuildAddonMessage(message)
	local whispered = 0
	local whisperFail = 0
	for _, target in ipairs(ns.IterOnlineGuildNames()) do
		local wOk = ns.SendWhisperAddonMessage(message, target)
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

function ns.IsAjhAddonChannel(channel)
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

function ns.BroadcastScore()
	if not IsInGuild() then
		lastGuildSyncNote = "skip-not-in-guild"
		return
	end
	local db = ns.EnsureDB()
	if not db then
		lastGuildSyncNote = "skip-no-db"
		return
	end
	local key, name = ns.PlayerIdentity()
	if not key then
		lastGuildSyncNote = "skip-no-identity"
		return
	end
	local mask = ns.GetAchievementMask()
	local achs = ns.CountOwnAchievements()
	local jumps = ns.ToNumberOr(db.jumps, 0)
	local xp = ns.ToNumberOr(db.xp, 0)
	ns.StoreScore(key, name, jumps, mask, xp, achs)
	-- Y: feat count (correct with many feats). X/S: legacy capped 31-bit mask.
	local yMsg = string.format("Y:%d:%d:%d", jumps, achs, xp)
	local sMsg = string.format("S:%d:%d", jumps, mask)
	local xMsg = string.format("X:%d:%d:%d", jumps, mask, xp)
	ns.SendGuildAddonMessage(yMsg)
	ns.SendGuildAddonMessage(sMsg)
	ns.SendGuildAddonMessage(xMsg)
	local whispered = 0
	local whisperFail = 0
	for _, target in ipairs(ns.IterOnlineGuildNames()) do
		if ns.SendWhisperAddonMessage(yMsg, target) then
			whispered = whispered + 1
		else
			whisperFail = whisperFail + 1
		end
		ns.SendWhisperAddonMessage(sMsg, target)
		ns.SendWhisperAddonMessage(xMsg, target)
	end
	-- Also party/raid if grouped with them.
	if IsInGroup and IsInGroup() then
		pcall(function()
			local chatType = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
			if C_ChatInfo and C_ChatInfo.SendAddonMessage then
				C_ChatInfo.SendAddonMessage(ADDON_PREFIX, yMsg, chatType)
				C_ChatInfo.SendAddonMessage(ADDON_PREFIX, sMsg, chatType)
				C_ChatInfo.SendAddonMessage(ADDON_PREFIX, xMsg, chatType)
			end
		end)
	end
	lastGuildSendNote = string.format("whispered=%d fail=%d onlinePeers=%d", whispered, whisperFail, #ns.IterOnlineGuildNames())
	lastGuildSyncNote = "broadcast " .. lastGuildSendNote
end

function ns.RequestGuildScores()
	if not IsInGuild() then
		lastGuildSyncNote = "request-not-in-guild"
		return
	end
	ns.BroadcastScore()
	ns.SendGuildAddonMessage("R")
	local asked = 0
	for _, target in ipairs(ns.IterOnlineGuildNames()) do
		if ns.SendWhisperAddonMessage("R", target) then
			asked = asked + 1
		end
	end
	lastGuildSyncNote = string.format("request whisperedR=%d %s", asked, lastGuildSendNote)
end

function ns.CreateStatRow(parent, anchor, y)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", anchor, "TOPLEFT", 16, y)

	local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	value:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -16, y)

	return label, value
end

function ns.CreateScrollArea(parent)
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

function ns.PlayUISound(kit, fallback)
	if not ns.SoundsAllowed() then
		return
	end
	if SOUNDKIT and SOUNDKIT[kit] then
		PlaySound(SOUNDKIT[kit], "SFX")
	else
		PlaySound(fallback, "SFX")
	end
end

function ns.ScrollLevelsToCurrent(level)
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

function ns.UpdateSettingsButton()
	local btn = ui.settingsButton
	if not btn or not btn.icon then
		return
	end
	if activeTab == "settings" then
		btn.icon:SetVertexColor(1, 0.82, 0)
	else
		btn.icon:SetVertexColor(0.9, 0.9, 0.9)
	end
end

function ns.SetTab(id, silent)
	local changed = activeTab ~= id
	activeTab = id
	for tabId, page in pairs(ui.pages) do
		page:SetShown(tabId == id)
	end
	if panel and ui.tabButtons then
		if id == "settings" then
			-- Settings is a separate gear button, not a PanelTemplates tab.
			for _, tab in ipairs(ui.tabButtons) do
				if PanelTemplates_DeselectTab then
					PanelTemplates_DeselectTab(tab)
				end
			end
			panel.selectedTab = 0
		elseif ui.tabIndex and ui.tabIndex[id] then
			PanelTemplates_SetTab(panel, ui.tabIndex[id])
		end
	end
	ns.UpdateSettingsButton()
	if id == "stats" then
		ns.ShowStatsView("main")
	end
	if id == "guild" then
		ns.RequestGuildScores()
	end
	if panel then
		panel:Update()
	end
	if not silent and changed then
		ns.PlayUISound("IG_CHARACTER_INFO_TAB", 841)
	end
end

function ns.BuildLevelRows(parent)
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
		row.xp:SetText(ns.FormatNumber(xpForLevel[level]))

		row.diff = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.diff:SetPoint("CENTER", 20, 0)
		if level == 1 then
			row.diff:SetText("")
		else
			row.diff:SetText("+" .. ns.FormatNumber(xpForLevel[level] - xpForLevel[level - 1]))
		end

		ui.levelRows[level] = row
	end

	parent:SetSize(300, 24 + MAX_LEVEL * ROW_HEIGHT)
end

function ns.UpdateLevelRows(currentLevel)
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

function ns.EnsureBoardRow(parent, index)
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

function ns.UpdateLeaderboard()
	local db = ns.EnsureDB()
	if not db then
		return
	end
	local key, name = ns.PlayerIdentity()
	ns.StoreScore(key, name, db.jumps, ns.GetAchievementMask(), db.xp, ns.CountOwnAchievements())

	local entries = {}
	for entryKey, data in pairs(db.board) do
		if type(data) == "table" and type(data.jumps) == "number" then
			local achCount = ns.ToNumberOr(data.achs, nil)
			if achCount == nil then
				achCount = ns.CountAchievementsFromMask(data.achMask)
			end
			if entryKey == key then
				achCount = ns.CountOwnAchievements()
			end
			local entryXp = ns.ToNumberOr(data.xp, data.jumps)
			tinsert(entries, {
				key = entryKey,
				name = data.name or entryKey,
				jumps = data.jumps,
				level = ns.GetLevel(entryXp),
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
			ui.guildEmpty:SetText("Waiting for guildmates with AJH? Open this tab while they are online.")
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
		local row = ns.EnsureBoardRow(child, i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -20 - (i - 1) * ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", 0, -20 - (i - 1) * ROW_HEIGHT)
		row:Show()

		row.rank:SetText(tostring(i))
		row.name:SetText(entry.name)
		row.level:SetText(tostring(entry.level))
		row.jumps:SetText(ns.FormatNumber(entry.jumps))
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
local FEAT_CAT_COLS = 2
local FEAT_CAT_CARD_HEIGHT = 138
local FEAT_CAT_CARD_GAP = 12
local FEAT_CAT_PAD = 10
local FEAT_CAT_ICON = 42
local FEAT_CAT_BAR_H = 18
local FEAT_CAT_INSET = 8

local FEAT_CAT_ICONS = {
	city = "Interface\\Icons\\Achievement_Zone_EasternKingdoms_01",
	town = "Interface\\Icons\\Achievement_Zone_TirisfalGlades_01",
	hostile = "Interface\\Icons\\Ability_DualWield",
	dungeon = "Interface\\Icons\\Achievement_Dungeon_ClassicDungeonMaster",
	raid = "Interface\\Icons\\Achievement_Boss_Ragnaros",
	milestone = "Interface\\Icons\\Achievement_General",
	style = "Interface\\Icons\\Spell_Nature_Polymorph",
	travel = "Interface\\Icons\\Ability_TownWatch",
	social = "Interface\\Icons\\INV_Misc_GroupLooking",
	collection = "Interface\\Icons\\INV_Misc_Coin_01",
	oddity = "Interface\\Icons\\INV_Misc_Bomb_02",
}

function ns.HideFeatRows(rows)
	for _, row in pairs(rows) do
		row:Hide()
	end
end

function ns.StyleFeatItemRow(row, ach, done)
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

function ns.EnsureFeatItemRow(i)
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

function ns.EnsureFeatCategoryRow(i)
	local child = ui.achChild
	local row = ui.featCatRows[i]
	if row then
		return row
	end
	-- Category tiles: compact 2x2 cards (layout applied in UpdateAchievements).
	row = CreateFrame("Button", nil, child)
	row:SetHeight(FEAT_CAT_CARD_HEIGHT)
	row:RegisterForClicks("LeftButtonUp")

	row.shadow = row:CreateTexture(nil, "BACKGROUND", nil, -1)
	row.shadow:SetPoint("TOPLEFT", 4, -4)
	row.shadow:SetPoint("BOTTOMRIGHT", 0, 0)
	row.shadow:SetColorTexture(0, 0, 0, 0.4)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetPoint("TOPLEFT", 1, -1)
	row.bg:SetPoint("BOTTOMRIGHT", -1, 1)
	row.bg:SetColorTexture(0.10, 0.12, 0.10, 0.96)

	-- Thin 1px rim (same language as Habit bar edges ? not a fat tooltip stud border).
	local function CardEdge()
		local edge = row:CreateTexture(nil, "OVERLAY", nil, 7)
		edge:SetColorTexture(0.72, 0.62, 0.28, 0.95)
		edge:SetSize(1, 1)
		return edge
	end
	local eTop = CardEdge()
	eTop:SetPoint("TOPLEFT", row.bg, "TOPLEFT", 0, 0)
	eTop:SetPoint("TOPRIGHT", row.bg, "TOPRIGHT", 0, 0)
	local eBottom = CardEdge()
	eBottom:SetPoint("BOTTOMLEFT", row.bg, "BOTTOMLEFT", 0, 0)
	eBottom:SetPoint("BOTTOMRIGHT", row.bg, "BOTTOMRIGHT", 0, 0)
	local eLeft = CardEdge()
	eLeft:SetPoint("TOPLEFT", row.bg, "TOPLEFT", 0, 0)
	eLeft:SetPoint("BOTTOMLEFT", row.bg, "BOTTOMLEFT", 0, 0)
	local eRight = CardEdge()
	eRight:SetPoint("TOPRIGHT", row.bg, "TOPRIGHT", 0, 0)
	eRight:SetPoint("BOTTOMRIGHT", row.bg, "BOTTOMRIGHT", 0, 0)
	row.cardEdges = { eTop, eBottom, eLeft, eRight }

	row.hl = row:CreateTexture(nil, "HIGHLIGHT")
	row.hl:SetPoint("TOPLEFT", row.bg, "TOPLEFT", 1, -1)
	row.hl:SetPoint("BOTTOMRIGHT", row.bg, "BOTTOMRIGHT", -1, 1)
	row.hl:SetColorTexture(1, 0.9, 0.45, 0.10)

	-- Habit-style XP bar at the bottom: tooltip chrome + gold StatusBar + on-bar text.
	row.barWrap = CreateFrame("Frame", nil, row)
	row.barWrap:SetHeight(FEAT_CAT_BAR_H)
	row.barWrap:SetPoint("BOTTOMLEFT", row.bg, "BOTTOMLEFT", FEAT_CAT_INSET, FEAT_CAT_INSET)
	row.barWrap:SetPoint("BOTTOMRIGHT", row.bg, "BOTTOMRIGHT", -FEAT_CAT_INSET, FEAT_CAT_INSET)
	row.barWrap:SetFrameLevel(row:GetFrameLevel() + 2)

	local barBorder = CreateFrame("Frame", nil, row.barWrap, BackdropTemplateMixin and "BackdropTemplate" or nil)
	barBorder:SetPoint("TOPLEFT", 0, 0)
	barBorder:SetPoint("BOTTOMRIGHT", 0, 0)
	barBorder:SetFrameLevel(row.barWrap:GetFrameLevel() + 3)
	if barBorder.SetBackdrop then
		barBorder:SetBackdrop({
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		barBorder:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
	end
	row.barBorder = barBorder

	row.bar = CreateFrame("StatusBar", nil, row.barWrap)
	row.bar:SetPoint("TOPLEFT", row.barWrap, "TOPLEFT", 3, -3)
	row.bar:SetPoint("BOTTOMRIGHT", row.barWrap, "BOTTOMRIGHT", -3, 3)
	row.bar:SetMinMaxValues(0, 1)
	row.bar:SetValue(0)
	row.bar:SetFrameLevel(row.barWrap:GetFrameLevel() + 1)
	row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	row.bar:SetStatusBarColor(1.0, 0.82, 0.0, 1)
	local fillTex = row.bar:GetStatusBarTexture()
	if fillTex then
		fillTex:SetHorizTile(false)
		fillTex:SetVertTile(false)
	end
	local track = row.bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(0.08, 0.07, 0.04, 1)

	-- Count lives on the bar (same place as Habit "Jump Habit X/Y").
	row.progress = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.progress:SetPoint("CENTER", row.bar, "CENTER", 0, 0)
	row.progress:SetTextColor(1, 1, 1, 1)
	do
		local fontPath, fontSize = row.progress:GetFont()
		if fontPath then
			row.progress:SetFont(fontPath, fontSize or 11, "OUTLINE")
		end
	end

	-- Icon (achievement-themed art; thin gold rim).
	row.iconBorder = CreateFrame("Frame", nil, row)
	row.iconBorder:SetSize(FEAT_CAT_ICON, FEAT_CAT_ICON)
	row.iconBorder:SetPoint("TOP", row.bg, "TOP", 0, -FEAT_CAT_INSET - 2)
	row.iconBorder:SetFrameLevel(row:GetFrameLevel() + 2)
	local iconBg = row.iconBorder:CreateTexture(nil, "BACKGROUND")
	iconBg:SetAllPoints()
	iconBg:SetColorTexture(0.04, 0.04, 0.03, 1)
	row.iconBg = iconBg
	local function IconEdge()
		local edge = row.iconBorder:CreateTexture(nil, "OVERLAY")
		edge:SetColorTexture(1, 0.82, 0, 0.95)
		edge:SetSize(1, 1)
		return edge
	end
	local ibTop = IconEdge()
	ibTop:SetPoint("TOPLEFT", 0, 0)
	ibTop:SetPoint("TOPRIGHT", 0, 0)
	local ibBottom = IconEdge()
	ibBottom:SetPoint("BOTTOMLEFT", 0, 0)
	ibBottom:SetPoint("BOTTOMRIGHT", 0, 0)
	local ibLeft = IconEdge()
	ibLeft:SetPoint("TOPLEFT", 0, 0)
	ibLeft:SetPoint("BOTTOMLEFT", 0, 0)
	local ibRight = IconEdge()
	ibRight:SetPoint("TOPRIGHT", 0, 0)
	ibRight:SetPoint("BOTTOMRIGHT", 0, 0)
	row.iconEdges = { ibTop, ibBottom, ibLeft, ibRight }

	row.icon = row.iconBorder:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(FEAT_CAT_ICON - 4, FEAT_CAT_ICON - 4)
	row.icon:SetPoint("CENTER", 0, 0)
	row.icon:SetTexture(FEATS_ICON)
	if row.icon.SetTexCoord then
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	end

	row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.title:SetPoint("TOP", row.iconBorder, "BOTTOM", 0, -8)
	row.title:SetPoint("LEFT", row.bg, "LEFT", FEAT_CAT_INSET, 0)
	row.title:SetPoint("RIGHT", row.bg, "RIGHT", -FEAT_CAT_INSET, 0)
	row.title:SetJustifyH("CENTER")
	row.title:SetTextColor(1, 0.86, 0.25, 1)
	if row.title.SetMaxLines then
		row.title:SetMaxLines(1)
	end
	row.title:SetWordWrap(false)

	-- Description: room to wrap; hover tooltip always shows the full line.
	row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.desc:SetPoint("TOP", row.title, "BOTTOM", 0, -5)
	row.desc:SetPoint("LEFT", row.bg, "LEFT", FEAT_CAT_INSET + 2, 0)
	row.desc:SetPoint("RIGHT", row.bg, "RIGHT", -(FEAT_CAT_INSET + 2), 0)
	row.desc:SetPoint("BOTTOM", row.barWrap, "TOP", 0, 6)
	row.desc:SetJustifyH("CENTER")
	row.desc:SetJustifyV("TOP")
	row.desc:SetTextColor(0.82, 0.84, 0.78, 1)
	row.desc:SetWordWrap(true)
	if row.desc.SetNonSpaceWrap then
		row.desc:SetNonSpaceWrap(false)
	end
	-- No MaxLines / ellipsis ? tooltip covers overflow if any.

	row:SetScript("OnEnter", function(self)
		if not self.categoryName then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.categoryName, 1, 0.82, 0)
		if self.categoryDesc and self.categoryDesc ~= "" then
			GameTooltip:AddLine(self.categoryDesc, 1, 1, 1, true)
		end
		if self.categoryEarned and self.categoryTotal then
			GameTooltip:AddLine(
				string.format("%d / %d complete", self.categoryEarned, self.categoryTotal),
				0.9,
				0.9,
				0.7
			)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	row:SetScript("OnClick", function(self)
		if not self.categoryId then
			return
		end
		ui.featView = self.categoryId
		ns.PlayUISound("IG_CHARACTER_INFO_TAB", 841)
		ns.UpdateAchievements()
	end)

	ui.featCatRows[i] = row
	return row
end

function ns.UpdateAchievements()
	ns.EnsureDB()
	local child = ui.achChild
	if not child then
		return
	end

	local totalEarned = 0
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ns.DB().achievements[ach.id] then
			totalEarned = totalEarned + 1
		end
	end

	local view = ui.featView or "categories"
	local inCategory = view ~= "categories"

	if ui.featBack then
		ui.featBack:SetShown(inCategory)
	end
	if ui.achSummaryIcon then
		ui.achSummaryIcon:ClearAllPoints()
		if inCategory and ui.featBack then
			ui.achSummaryIcon:SetPoint("LEFT", ui.featBack, "RIGHT", 8, 0)
		else
			ui.achSummaryIcon:SetPoint("TOPLEFT", 12, -14)
		end
		ui.achSummaryIcon:Show()
	end
	if ui.achSummary then
		ui.achSummary:ClearAllPoints()
		if ui.achSummaryIcon then
			ui.achSummary:SetPoint("LEFT", ui.achSummaryIcon, "RIGHT", 6, 0)
		elseif inCategory and ui.featBack then
			ui.achSummary:SetPoint("LEFT", ui.featBack, "RIGHT", 8, 0)
		else
			ui.achSummary:SetPoint("TOPLEFT", 12, -16)
		end
	end

	if inCategory then
		ns.HideFeatRows(ui.featCatRows)

		local catName = view
		for _, cat in ipairs(FEAT_CATEGORIES) do
			if cat.id == view then
				catName = cat.name
				break
			end
		end

		local feats = ns.GetFeatsInCategory(view)
		local earned, total = ns.CountCategoryProgress(view)

		for i, ach in ipairs(feats) do
			local row = ns.EnsureFeatItemRow(i)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -(i - 1) * ACH_ROW_HEIGHT)
			row:SetPoint("TOPRIGHT", 0, -(i - 1) * ACH_ROW_HEIGHT)
			row:Show()
			ns.StyleFeatItemRow(row, ach, ns.DB().achievements[ach.id] ~= nil)
		end
		for i = #feats + 1, #ui.achRows do
			ui.achRows[i]:Hide()
		end

		child:SetSize(300, math.max(#feats, 1) * ACH_ROW_HEIGHT)
		if ui.achSummary then
			ui.achSummary:SetText(string.format("%s  ?  %d / %d", catName, earned, total))
		end
	else
		ns.HideFeatRows(ui.achRows)

		local contentW = child:GetWidth()
		if not contentW or contentW < 80 then
			contentW = 300
		end
		local cols = FEAT_CAT_COLS
		local gaps = cols - 1
		local cardW = (contentW - FEAT_CAT_PAD * 2 - FEAT_CAT_CARD_GAP * gaps) / cols
		local rowsNeeded = math.ceil(#FEAT_CATEGORIES / cols)

		local function SetIconEdgeColor(row, r, g, b, a)
			if not row.iconEdges then
				return
			end
			for _, edge in ipairs(row.iconEdges) do
				edge:SetColorTexture(r, g, b, a or 1)
			end
		end

		local function SetCardEdgeColor(row, r, g, b, a)
			if not row.cardEdges then
				return
			end
			for _, edge in ipairs(row.cardEdges) do
				edge:SetColorTexture(r, g, b, a or 1)
			end
		end

		local function SetCategoryBar(row, earned, total)
			if not row.bar then
				return
			end
			local maxV = (total and total > 0) and total or 1
			row.bar:SetMinMaxValues(0, maxV)
			row.bar:SetValue(math.min(earned or 0, maxV))
			if row.progress then
				row.progress:SetText(string.format("%d / %d", earned or 0, total or 0))
			end
		end

		for i, cat in ipairs(FEAT_CATEGORIES) do
			local row = ns.EnsureFeatCategoryRow(i)
			local earned, total = ns.CountCategoryProgress(cat.id)
			row.categoryId = cat.id
			row.categoryName = cat.name
			row.categoryDesc = cat.desc
			row.categoryEarned = earned
			row.categoryTotal = total
			row.title:SetText(cat.name)
			row.desc:SetText(cat.desc)
			row.icon:SetTexture(FEAT_CAT_ICONS[cat.id] or "Interface\\Icons\\INV_Misc_QuestionMark")
			SetCategoryBar(row, earned, total)
			if earned >= total and total > 0 then
				row.title:SetTextColor(1, 0.88, 0.2, 1)
				row.bg:SetColorTexture(0.18, 0.16, 0.08, 0.97)
				row.bar:SetStatusBarColor(1, 0.88, 0.2, 1)
				SetCardEdgeColor(row, 1, 0.82, 0, 1)
				SetIconEdgeColor(row, 1, 0.86, 0.25, 1)
			elseif earned > 0 then
				row.title:SetTextColor(1, 0.86, 0.35, 1)
				row.bg:SetColorTexture(0.11, 0.13, 0.10, 0.97)
				row.bar:SetStatusBarColor(1, 0.82, 0, 1)
				SetCardEdgeColor(row, 0.85, 0.72, 0.32, 0.95)
				SetIconEdgeColor(row, 0.95, 0.8, 0.3, 0.95)
			else
				row.title:SetTextColor(1, 0.82, 0.3, 1)
				row.bg:SetColorTexture(0.09, 0.11, 0.09, 0.96)
				row.bar:SetStatusBarColor(1, 0.82, 0, 1)
				SetCardEdgeColor(row, 0.62, 0.55, 0.32, 0.9)
				SetIconEdgeColor(row, 0.75, 0.65, 0.32, 0.9)
			end
			local col = (i - 1) % cols
			local gridRow = math.floor((i - 1) / cols)
			local x = FEAT_CAT_PAD + col * (cardW + FEAT_CAT_CARD_GAP)
			local y = -(FEAT_CAT_PAD + gridRow * (FEAT_CAT_CARD_HEIGHT + FEAT_CAT_CARD_GAP))
			row:ClearAllPoints()
			row:SetSize(cardW, FEAT_CAT_CARD_HEIGHT)
			row:SetPoint("TOPLEFT", x, y)
			SetCategoryBar(row, earned, total)
			row:Show()
		end
		for i = #FEAT_CATEGORIES + 1, #ui.featCatRows do
			ui.featCatRows[i]:Hide()
		end

		child:SetSize(
			contentW,
			FEAT_CAT_PAD * 2 + rowsNeeded * FEAT_CAT_CARD_HEIGHT + math.max(0, rowsNeeded - 1) * FEAT_CAT_CARD_GAP
		)
		if ui.achSummary then
			ui.achSummary:SetText(string.format("%d / %d feats", totalEarned, #ACHIEVEMENTS))
		end
	end
end

function ns.BuildPanel()
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

	-- Settings cog on the panel chrome (inside the main border, above the inset).
	local gear = CreateFrame("Button", "AJHSettingsButton", panel)
	gear:SetSize(16, 16)
	gear:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -38)
	gear:SetFrameLevel(panel:GetFrameLevel() + 10)
	local gearIcon = gear:CreateTexture(nil, "ARTWORK")
	gearIcon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
	gearIcon:SetSize(16, 16)
	gearIcon:SetPoint("CENTER")
	gearIcon:SetVertexColor(0.9, 0.9, 0.9)
	gear.icon = gearIcon
	gear:SetScript("OnClick", function()
		ns.SetTab("settings")
	end)
	gear:SetScript("OnEnter", function(self)
		self.icon:SetVertexColor(1, 1, 1)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("Settings")
		GameTooltip:Show()
	end)
	gear:SetScript("OnLeave", function(self)
		GameTooltip:Hide()
		ns.UpdateSettingsButton()
	end)
	ui.settingsButton = gear
	ui.tabs.settings = gear
	ns.UpdateSettingsButton()

	local tabDefs = {
		{ id = "habit", label = "Habit" },
		{ id = "stats", label = "Stats" },
		{ id = "achieves", label = "Feats" },
		{ id = "guild", label = "Guild" },
	}
	ui.tabIndex = {}
	ui.tabButtons = {}
	for i, def in ipairs(tabDefs) do
		local tab = CreateFrame("Button", "AJHFrameTab" .. i, panel, "PanelTabButtonTemplate")
		tab:SetID(i)
		tab:SetText(def.label or "")
		tab.tabId = def.id
		if i == 1 then
			tab:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 11, 2)
		else
			tab:SetPoint("LEFT", ui.tabButtons[i - 1], "RIGHT", 3, 0)
		end
		tab:SetScript("OnClick", function(self)
			ns.SetTab(self.tabId)
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

	local habitMain = CreateFrame("Frame", nil, habit)
	habitMain:SetAllPoints()
	ui.habitMain = habitMain

	local levelLabel = habitMain:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	levelLabel:SetPoint("TOP", 0, -8)
	levelLabel:SetText("LEVEL")
	levelLabel:SetTextColor(1, 0.82, 0)

	ui.level = habitMain:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	ui.level:SetPoint("TOP", levelLabel, "BOTTOM", 0, -2)
	-- Large gold level number.
	local levelFont = (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
	ui.level:SetFont(levelFont, 42, "OUTLINE")
	ui.level:SetTextColor(1, 0.82, 0)
	if ui.level.SetShadowOffset then
		ui.level:SetShadowOffset(2, -2)
		ui.level:SetShadowColor(0, 0, 0, 0.85)
	end

	-- Habit XP bar (dialog): 1.2.0 design ? tooltip border + gold fill + silver tip.
	local BAR_PAD = 22
	local barWrap = CreateFrame("Frame", nil, habitMain)
	barWrap:ClearAllPoints()
	barWrap:SetPoint("TOP", ui.level, "BOTTOM", 0, -14)
	barWrap:SetPoint("LEFT", habitMain, "LEFT", BAR_PAD, 0)
	barWrap:SetPoint("RIGHT", habitMain, "RIGHT", -BAR_PAD, 0)
	barWrap:SetHeight(HABIT_PANEL_XP_BAR_HEIGHT)
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
	-- Solid fill - UI-StatusBar has transparent margins that left black lines.
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
		-- Tip must stay inside the filled region (never spill left of the bar).
		local tipW = math.min(56, math.max(16, fillW * 0.38))
		tipW = math.min(tipW, fillW)
		if tipW < 8 then
			spark:Hide()
			return
		end
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

	ui.xpDetail = habitMain:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.xpDetail:SetPoint("TOP", barWrap, "BOTTOM", 0, -10)
	ui.xpDetail:SetTextColor(1, 0.82, 0)

	local statsLine = habitMain:CreateTexture(nil, "ARTWORK")
	statsLine:SetHeight(1)
	statsLine:SetColorTexture(0.55, 0.45, 0.15, 0.55)
	statsLine:SetPoint("LEFT", habitMain, "LEFT", 16, 0)
	statsLine:SetPoint("RIGHT", habitMain, "RIGHT", -16, 0)
	statsLine:SetPoint("TOP", ui.xpDetail, "BOTTOM", 0, -12)

	local function HabitStatRow(parent, anchor, yOff)
		local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
		local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		value:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, yOff)
		return label, value
	end

	ui.jumpLabel, ui.jumpValue = HabitStatRow(habitMain, statsLine, -14)
	ui.jumpLabel:SetText("Total jumps")

	ui.xpLabel, ui.xpValue = HabitStatRow(habitMain, ui.jumpLabel, -10)
	ui.xpLabel:SetText("Experience")
	-- Keep value aligned to the full-width line, not the shorter label.
	ui.xpValue:ClearAllPoints()
	ui.xpValue:SetPoint("TOPRIGHT", ui.jumpValue, "BOTTOMRIGHT", 0, -10)

	ui.nextLabel, ui.nextValue = HabitStatRow(habitMain, ui.xpLabel, -10)
	ui.nextLabel:SetText("XP to next level")
	ui.nextValue:ClearAllPoints()
	ui.nextValue:SetPoint("TOPRIGHT", ui.xpValue, "BOTTOMRIGHT", 0, -10)

	ui.rateLabel, ui.rateValue = HabitStatRow(habitMain, ui.nextLabel, -10)
	ui.rateLabel:SetText("XP per jump")
	ui.rateValue:ClearAllPoints()
	ui.rateValue:SetPoint("TOPRIGHT", ui.nextValue, "BOTTOMRIGHT", 0, -10)
	ui.rateValue:SetText(tostring(XP_PER_JUMP))

	-- Single Announce button (channel picked in a dialog).
	local announceBtn = CreateFrame("Button", nil, habitMain, "UIPanelButtonTemplate")
	announceBtn:SetSize(120, 22)
	announceBtn:SetPoint("BOTTOM", 0, 12)
	announceBtn:SetText("Announce")
	announceBtn:SetScript("OnClick", function()
		ns.ShowAnnounceDialog()
	end)
	ui.announceBtn = announceBtn

	-- Stats tab (statistics + nested Levels table)
	local statsPage = CreateFrame("Frame", nil, content)
	statsPage:SetAllPoints()
	statsPage:Hide()
	ui.pages.stats = statsPage

	local statsMain = CreateFrame("Frame", nil, statsPage)
	statsMain:SetAllPoints()
	ui.statsMain = statsMain

	local levelsBtn = CreateFrame("Button", nil, statsMain, "UIPanelButtonTemplate")
	levelsBtn:SetSize(72, 20)
	levelsBtn:SetPoint("TOPRIGHT", -6, -6)
	levelsBtn:SetText("Levels")
	levelsBtn:SetScript("OnClick", function()
		ns.ShowStatsView("levels")
		if panel then
			panel:Update()
		end
	end)

	local statsTitle = statsMain:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	statsTitle:SetPoint("TOP", 0, -8)
	statsTitle:SetText("Statistics")
	statsTitle:SetTextColor(1, 0.82, 0)

	local statsDivider = statsMain:CreateTexture(nil, "ARTWORK")
	statsDivider:SetHeight(1)
	statsDivider:SetColorTexture(0.55, 0.45, 0.15, 0.55)
	statsDivider:SetPoint("LEFT", statsMain, "LEFT", 16, 0)
	statsDivider:SetPoint("RIGHT", statsMain, "RIGHT", -16, 0)
	statsDivider:SetPoint("TOP", statsTitle, "BOTTOM", 0, -10)

	local prevStatValue = nil
	local function StatsRow(anchor, yOff, labelText)
		local label, value = HabitStatRow(statsMain, anchor, yOff)
		label:SetText(labelText)
		value:ClearAllPoints()
		if prevStatValue then
			value:SetPoint("TOPRIGHT", prevStatValue, "BOTTOMRIGHT", 0, yOff)
		else
			value:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, yOff)
		end
		prevStatValue = value
		return label, value
	end

	ui.statSessionJumpsLabel, ui.statSessionJumps = StatsRow(statsDivider, -14, "Session jumps")
	ui.statSessionHighLabel, ui.statSessionHigh = StatsRow(ui.statSessionJumpsLabel, -10, "Best session")
	ui.statSessionTimeLabel, ui.statSessionTime = StatsRow(ui.statSessionHighLabel, -10, "Session time")
	ui.statSessionActivityLabel, ui.statSessionActivity = StatsRow(ui.statSessionTimeLabel, -10, "Session activity")
	ui.statSessionRateLabel, ui.statSessionRate = StatsRow(ui.statSessionActivityLabel, -10, "Session rate")
	ui.statRecentRateLabel, ui.statRecentRate = StatsRow(ui.statSessionRateLabel, -10, "Recent rate (5m)")
	ui.statLifeJumpsLabel, ui.statLifeJumps = StatsRow(ui.statRecentRateLabel, -10, "Lifetime jumps")
	ui.statLifeLevelLabel, ui.statLifeLevel = StatsRow(ui.statLifeJumpsLabel, -10, "Lifetime level")
	ui.statLifeActivityLabel, ui.statLifeActivity = StatsRow(ui.statLifeLevelLabel, -10, "Lifetime activity")
	ui.statFeatsLabel, ui.statFeats = StatsRow(ui.statLifeActivityLabel, -10, "Feats unlocked")
	ui.statLastJumpLabel, ui.statLastJump = StatsRow(ui.statFeatsLabel, -10, "Time since last jump")

	local levels = CreateFrame("Frame", nil, statsPage)
	levels:SetAllPoints()
	levels:Hide()
	ui.statsLevels = levels

	local levelsBack = CreateFrame("Button", nil, levels, "UIPanelButtonTemplate")
	levelsBack:SetSize(60, 20)
	levelsBack:SetPoint("TOPLEFT", 6, -6)
	levelsBack:SetText("Back")
	levelsBack:SetScript("OnClick", function()
		ns.ShowStatsView("main")
		if panel then
			panel:Update()
		end
	end)

	local levelsTitle = levels:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	levelsTitle:SetPoint("TOP", 0, -8)
	levelsTitle:SetText("Levels")
	levelsTitle:SetTextColor(1, 0.82, 0)

	local levelsWrap, levelScroll, levelChild = ns.CreateScrollArea(levels)
	levelsWrap:ClearAllPoints()
	levelsWrap:SetPoint("TOPLEFT", 4, -32)
	levelsWrap:SetPoint("BOTTOMRIGHT", -4, 4)
	ui.levelScroll = levelScroll
	ui.levelChild = levelChild
	ns.BuildLevelRows(levelChild)

	ns.ShowStatsView("main")

	-- Achievements page
	local achieves = CreateFrame("Frame", nil, content)
	achieves:SetAllPoints()
	achieves:Hide()
	ui.pages.achieves = achieves

	ui.featBack = CreateFrame("Button", nil, achieves, "UIPanelButtonTemplate")
	ui.featBack:SetSize(56, 20)
	ui.featBack:SetPoint("TOPLEFT", 8, -12)
	ui.featBack:SetText("Back")
	ui.featBack:Hide()
	ui.featBack:SetScript("OnClick", function()
		ui.featView = "categories"
		ns.PlayUISound("IG_CHARACTER_INFO_TAB", 841)
		ns.UpdateAchievements()
	end)

	-- Flat gold diamond (rotated square): SVG-style, not a painted icon.
	ui.achSummaryIcon = CreateFrame("Frame", nil, achieves)
	ui.achSummaryIcon:SetSize(14, 14)
	ui.achSummaryIcon:SetPoint("TOPLEFT", 12, -14)
	local diamond = ui.achSummaryIcon:CreateTexture(nil, "ARTWORK")
	diamond:SetTexture("Interface\\Buttons\\WHITE8X8")
	diamond:SetSize(9, 9)
	diamond:SetPoint("CENTER", 0, 0)
	diamond:SetVertexColor(1, 0.82, 0, 1)
	if diamond.SetRotation then
		diamond:SetRotation(math.rad(45))
	end
	ui.achSummaryIcon.tex = diamond

	ui.achSummary = achieves:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.achSummary:SetPoint("LEFT", ui.achSummaryIcon, "RIGHT", 6, 0)
	ui.achSummary:SetTextColor(1, 0.82, 0)

	local achWrap, _, achChild = ns.CreateScrollArea(achieves)
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
			ns.ResetAchievements()
		end)
	end

	-- Guild page
	local guild = CreateFrame("Frame", nil, content)
	guild:SetAllPoints()
	guild:Hide()
	ui.pages.guild = guild

	local boardWrap, _, boardChild = ns.CreateScrollArea(guild)
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
		ns.RequestGuildScores()
		ns.UpdateLeaderboard()
	end)

	boardWrap:SetPoint("TOPLEFT", 4, -4)
	boardWrap:SetPoint("BOTTOMRIGHT", -4, 32)

	-- Settings page (sound enable + volume)
	local settings = CreateFrame("Frame", nil, content)
	settings:SetAllPoints()
	settings:Hide()
	ui.pages.settings = settings

	local settingsTitle = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	settingsTitle:SetPoint("TOP", 0, -12)
	settingsTitle:SetText("Settings")
	settingsTitle:SetTextColor(1, 0.82, 0)

	local soundCheck = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
	soundCheck:SetPoint("TOPLEFT", 20, -48)
	soundCheck:SetSize(26, 26)
	local soundCheckLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	soundCheckLabel:SetPoint("LEFT", soundCheck, "RIGHT", 4, 1)
	soundCheckLabel:SetText("Enable sounds")
	soundCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.DB().soundsEnabled = not not self:GetChecked()
	end)
	ui.soundCheck = soundCheck

	local announceCheck = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
	announceCheck:SetPoint("TOPLEFT", soundCheck, "BOTTOMLEFT", 0, -6)
	announceCheck:SetSize(26, 26)
	local announceCheckLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	announceCheckLabel:SetPoint("LEFT", announceCheck, "RIGHT", 4, 1)
	announceCheckLabel:SetText("Auto announce feats to guild")
	announceCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.DB().autoAnnounce = not not self:GetChecked()
	end)
	ui.announceCheck = announceCheck

	local xpBarCheck = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
	xpBarCheck:SetPoint("TOPLEFT", announceCheck, "BOTTOMLEFT", 0, -6)
	xpBarCheck:SetSize(26, 26)
	local xpBarCheckLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	xpBarCheckLabel:SetPoint("LEFT", xpBarCheck, "RIGHT", 4, 1)
	xpBarCheckLabel:SetText("Show Jump XP bar")
	xpBarCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.SetJumpXPBarShown(not not self:GetChecked())
	end)
	ui.jumpXPBarCheck = xpBarCheck

	local volumeLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	volumeLabel:SetPoint("TOPLEFT", 24, -156)
	volumeLabel:SetText("Sound volume")
	ui.soundVolumeLabel = volumeLabel

	local volumeValue = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	volumeValue:SetPoint("LEFT", volumeLabel, "RIGHT", 8, 0)
	ui.soundVolumeValue = volumeValue

	local volumeSlider
	local sliderOk = pcall(function()
		volumeSlider = CreateFrame("Slider", "AJHSoundVolumeSlider", settings, "OptionsSliderTemplate")
	end)
	if not sliderOk or not volumeSlider then
		volumeSlider = CreateFrame("Slider", "AJHSoundVolumeSlider", settings)
		volumeSlider:SetOrientation("HORIZONTAL")
		volumeSlider:SetHitRectInsets(0, 0, -10, -10)
		local thumb = volumeSlider:CreateTexture(nil, "OVERLAY")
		thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
		thumb:SetSize(24, 32)
		volumeSlider:SetThumbTexture(thumb)
		local bg = volumeSlider:CreateTexture(nil, "BACKGROUND")
		bg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
		bg:SetPoint("TOPLEFT", 0, 0)
		bg:SetPoint("BOTTOMRIGHT", 0, 0)
	end
	volumeSlider:SetPoint("TOPLEFT", 28, -188)
	volumeSlider:SetPoint("TOPRIGHT", -28, -188)
	volumeSlider:SetHeight(16)
	volumeSlider:SetMinMaxValues(0, 100)
	volumeSlider:SetValueStep(1)
	if volumeSlider.SetObeyStepOnDrag then
		volumeSlider:SetObeyStepOnDrag(true)
	end
	volumeSlider:SetScript("OnValueChanged", function(self, value)
		ns.EnsureDB()
		value = math.floor(value + 0.5)
		ns.DB().soundVolume = value
		if ui.soundVolumeValue then
			ui.soundVolumeValue:SetText(tostring(value))
		end
		local text = _G[self:GetName() .. "Text"]
		if text then
			text:SetText("Sound volume")
		end
	end)
	do
		local low = _G[volumeSlider:GetName() .. "Low"]
		local high = _G[volumeSlider:GetName() .. "High"]
		local text = _G[volumeSlider:GetName() .. "Text"]
		if low then
			low:SetText("0")
		end
		if high then
			high:SetText("100")
		end
		if text then
			text:SetText("Sound volume")
		end
	end
	ui.soundVolumeSlider = volumeSlider

	local volumeNote = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	volumeNote:SetPoint("TOPLEFT", 24, -228)
	volumeNote:SetPoint("TOPRIGHT", -24, -228)
	volumeNote:SetJustifyH("LEFT")
	volumeNote:SetText("Volume 0 mutes AJH sounds. Announce via Habit button or /ajh say|party|guild.")
	volumeNote:SetTextColor(0.7, 0.7, 0.7)

	panel:SetScript("OnShow", function()
		ns.PlayUISound("IG_CHARACTER_INFO_OPEN", 839)
		panel:Update()
		ns.SyncStatsTicker()
	end)
	panel:SetScript("OnHide", function()
		ns.PlayUISound("IG_CHARACTER_INFO_CLOSE", 840)
		ns.StopStatsTicker()
	end)

	function panel:Update()
		local db = ns.EnsureDB()
		if not db then
			return
		end
		ns.EnsureSessionClock()
		ns.FlushPlayTime()
		local xp = db.xp
		local jumps = db.jumps
		local level = ns.GetLevel(xp)

		ui.level:SetText(tostring(level))
		ui.jumpValue:SetText(ns.FormatNumber(jumps))
		ns.UpdateLevelRows(level)

		local xpGain = ns.GetJumpXPGain()
		if ns.HasCampBenefit() then
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
			ui.xpValue:SetText(ns.FormatNumber(xp - xpForLevel[MAX_LEVEL]))
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
				ns.FormatNumber(intoLevel),
				ns.FormatNumber(needed)
			))
			ui.xpDetail:SetText(string.format(
				"%d%%  -  %s until level %d",
				math.min(99, math.floor(pct * 100)),
				ns.FormatNumber(remaining),
				level + 1
			))
			ui.xpValue:SetText(ns.FormatNumber(intoLevel))
			ui.nextLabel:SetText("XP to next level")
			ui.nextValue:SetText(ns.FormatNumber(remaining))
		end

		if activeTab == "stats" and ui.statsView == "main" and ui.statSessionJumps then
			local now = GetTime()
			local elapsed = math.max(1, ns.CurrentSessionElapsed())
			local perMin = sessionJumps * 60 / elapsed
			local perHr = sessionJumps * 3600 / elapsed
			local recent = ns.CountJumpsInWindow(300)
			local recentPerMin = recent / 5
			local best = ns.DB().sessionJumpHigh or 0
			if sessionJumps > best then
				best = sessionJumps
			end
			local featEarned = ns.CountOwnAchievements()
			local featTotal = #ACHIEVEMENTS
			local lifePlay = ns.LifetimePlayTime()
			local sessionJumpSec = sessionJumps * JUMP_ACTIVITY_SEC
			local lifeJumpSec = ns.LifetimeJumpActivityTime()

			if best > 0 then
				local pctOfBest = math.floor((sessionJumps / best) * 100 + 0.5)
				ui.statSessionJumps:SetText(string.format("%s (%d%%)", ns.FormatNumber(sessionJumps), pctOfBest))
				ui.statSessionHigh:SetText(ns.FormatNumber(best))
			else
				ui.statSessionJumps:SetText(ns.FormatNumber(sessionJumps))
				ui.statSessionHigh:SetText("?")
			end
			ui.statSessionTime:SetText(ns.FormatDuration(elapsed))
			ui.statSessionActivity:SetText(ns.FormatJumpIdlePct(sessionJumpSec, elapsed))
			ui.statSessionRate:SetText(string.format("%.1f/min  ?  %.0f/hr", perMin, perHr))
			ui.statRecentRate:SetText(string.format("%.1f/min", recentPerMin))
			ui.statLifeJumps:SetText(ns.FormatNumber(jumps))
			ui.statLifeLevel:SetText(tostring(level))
			ui.statLifeActivity:SetText(ns.FormatJumpIdlePct(lifeJumpSec, lifePlay))
			if featTotal > 0 then
				local featPct = math.floor((featEarned / featTotal) * 100 + 0.5)
				ui.statFeats:SetText(string.format("%d / %d (%d%%)", featEarned, featTotal, featPct))
			else
				ui.statFeats:SetText(string.format("%d / %d", featEarned, featTotal))
			end
			if lastAcceptedJumpTime > 0 then
				ui.statLastJump:SetText(ns.FormatDuration(now - lastAcceptedJumpTime))
			else
				ui.statLastJump:SetText("?")
			end
		end

		if activeTab == "settings" and ui.soundCheck then
			ui.soundCheck:SetChecked(ns.DB().soundsEnabled ~= false)
			if ui.announceCheck then
				ui.announceCheck:SetChecked(not not ns.DB().autoAnnounce)
			end
			ns.UpdateJumpXPBarToggleLabel()
			local vol = ns.ToNumberOr(ns.DB().soundVolume, 100) or 100
			ui.soundVolumeSlider:SetValue(vol)
			ui.soundVolumeValue:SetText(tostring(math.floor(vol + 0.5)))
		end

		if activeTab == "guild" then
			ns.UpdateLeaderboard()
		elseif activeTab == "achieves" then
			ns.UpdateAchievements()
		end

		ns.UpdateJumpXPBar()
	end

	ns.SetTab("habit", true)
	return panel
end

function ns.TogglePanel()
	local f = ns.BuildPanel()
	if f:IsShown() then
		f:Hide()
	else
		f:Show()
		f:Update()
	end
end

-- Slash / binding entry point (Bindings.xml auto-loads; must not be in TOC).
function AJH_TogglePanel()
	ns.TogglePanel()
end

local minimapButton
local minimapDragging = false

function ns.UpdateMinimapButtonPosition()
	if not minimapButton then
		return
	end
	-- Do NOT call EnsureDB here ? position reads AJHSaved if present.
	local angle = math.rad((type(AJHSaved) == "table" and ns.DB().minimapPos) or 210)
	local radius = (Minimap:GetWidth() / 2) + 5
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function ns.BuildMinimapButton()
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
		ns.EnsureDB()
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Archindula's Jump Habit", C.accent[1], C.accent[2], C.accent[3])
		GameTooltip:AddLine(
			string.format("Level %d  -  %s jumps", ns.GetLevel(ns.DB().xp), ns.FormatNumber(ns.DB().jumps)),
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
		ns.TogglePanel()
	end)

	btn:SetScript("OnDragStart", function(self)
		minimapDragging = true
		GameTooltip:Hide()
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale
			ns.EnsureDB()
			ns.DB().minimapPos = math.deg(math.atan2(cy - my, cx - mx))
			ns.UpdateMinimapButtonPosition()
		end)
	end)

	btn:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		C_Timer.After(0, function()
			minimapDragging = false
		end)
	end)

	minimapButton = btn
	ns.UpdateMinimapButtonPosition()
	return btn
end

local JUMP_COOLDOWN = JUMP_ACTIVITY_SEC
local lastJumpTime = 0

function ns.OnJump()
	local now = GetTime()
	if now - lastJumpTime < JUMP_COOLDOWN then
		return
	end
	lastJumpTime = now
	local idleGap = (lastAcceptedJumpTime > 0) and (now - lastAcceptedJumpTime) or 0
	ns.RecordSessionJump(now)

	local db = ns.EnsureDB()
	if not db then
		return
	end
	local dayStreak = ns.NoteJumpDay()
	ns.NoteSessionJumpHigh()
	ns.NoteJumpActivity()
	local oldLevel = ns.GetLevel(db.xp)
	db.jumps = db.jumps + 1
	db.xp = db.xp + ns.GetJumpXPGain()
	local newLevel = ns.GetLevel(db.xp)
	if newLevel > oldLevel then
		ns.AnnounceLevelUp(newLevel)
		ns.BroadcastScore()
	elseif db.jumps % 25 == 0 then
		ns.BroadcastScore()
	end
	if ns.CheckAchievementsOnJump({ idleGap = idleGap, dayStreak = dayStreak, fromJump = true }) and panel and panel:IsShown() and activeTab == "achieves" then
		ns.UpdateAchievements()
	end
	if panel and panel:IsShown() then
		panel:Update()
	else
		ns.UpdateJumpXPBar()
	end
end

local uiBuilt = false
local jumpHookInstalled = false

-- Build UI on PLAYER_LOGIN, after SavedVariables are loaded.
function ns.EnsureUIBuilt()
	if uiBuilt then
		return
	end
	uiBuilt = true
	ns.EnsureSessionClock()
	ns.BuildPanel()
	ns.BuildJumpXPBar()
	ns.BuildMinimapButton()
	if not jumpHookInstalled then
		jumpHookInstalled = true
		hooksecurefunc("JumpOrAscendStart", ns.OnJump)
	end
	ns.RefreshCampBenefit()
	-- Keep lifetime play time moving even when the panel is closed.
	if C_Timer and C_Timer.NewTicker and not playTimeTicker then
		playTimeTicker = C_Timer.NewTicker(5, function()
			if type(AJHSaved) == "table" then
				ns.FlushPlayTime()
			end
		end)
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterUnitEvent("UNIT_AURA", "player")
loader:RegisterEvent("CHAT_MSG_ADDON")
loader:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name ~= ADDON_NAME then
			return
		end
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
		elseif RegisterAddonMessagePrefix then
			RegisterAddonMessagePrefix(ADDON_PREFIX)
		end
	elseif event == "PLAYER_LOGIN" then
		svReady = true
		local db = ns.EnsureDB()
		diagAfterBind = ns.DiagSnapshot("PLAYER_LOGIN")
		ns.DebugDump("PLAYER_LOGIN")
		ns.EnsureUIBuilt()
		if type(AJHSaved) == "table" then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff88ff88AJH:|r Loaded %s jumps (%s XP).",
				ns.FormatNumber(ns.DB().jumps),
				ns.FormatNumber(ns.DB().xp)
			))
		elseif db then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cffffcc00AJH:|r Starting temporary session at %s jumps (save file not loaded).",
				ns.FormatNumber(db.jumps)
			))
		end
		-- Forever often fails to load account SavedVariables after /reload or a
		-- full restart. We never invent AJHSaved={} so a good WTF file is kept.
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cffffcc00AJH:|r Forever bug ? addon saves sometimes never load after /reload or a full restart (WTF file can still be fine). AJH will not overwrite your save with zeros while that happens."
		)
		ns.RefreshCampBenefit()
		if panel then
			panel:Update()
		end
		ns.RestoreJumpXPBarFromSaved()
		if C_Timer and C_Timer.After then
			C_Timer.After(0.5, ns.RestoreJumpXPBarFromSaved)
			C_Timer.After(0.5, ns.TryLateSavedAdopt)
			C_Timer.After(2, ns.TryLateSavedAdopt)
			C_Timer.After(5, ns.TryLateSavedAdopt)
			C_Timer.After(1, function()
				if ns.EnsureDB() then
					-- Progress feats only — never location/situational (those need a real jump).
					ns.CheckAchievementsGeneral()
				end
			end)
		end
	elseif event == "PLAYER_LOGOUT" then
		diagAtLogout = ns.DiagSnapshot("PLAYER_LOGOUT")
		if DIAG_ENABLED then
			ns.DiagPrintSnapshot(diagAtLogout, true)
		end
		-- Only flush into the real SavedVariable. If Forever never loaded it,
		-- leave AJHSaved unset so the client does not write an empty table.
		if type(AJHSaved) == "table" then
			ns.EnsureDB()
			ns.FlushPlayTime()
		end
		if DIAG_ENABLED then
			ns.DiagReport("logout")
		end
	elseif event == "UNIT_AURA" then
		if ns.RefreshCampBenefit() and panel and panel:IsShown() then
			panel:Update()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.TryLateSavedAdopt()
		ns.EnsureDB()
		ns.RefreshCampBenefit()
		if panel then
			panel:Update()
		end
		C_Timer.After(0, function()
			ns.TryLateSavedAdopt()
			if ns.RefreshCampBenefit() and panel and panel:IsShown() then
				panel:Update()
			end
			-- Status bars are laid out by now; re-apply saved Jump XP bar layout.
			ns.RestoreJumpXPBarFromSaved()
		end)
		C_Timer.After(1, ns.RestoreJumpXPBarFromSaved)
		C_Timer.After(1, ns.TryLateSavedAdopt)
		C_Timer.After(3, ns.BroadcastScore)
		C_Timer.After(3, ns.TryLateSavedAdopt)
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...
		if prefix ~= ADDON_PREFIX then
			return
		end
		if not ns.IsAjhAddonChannel(channel) then
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
				ns.BroadcastScore()
			end
		else
			-- Y:jumps:achs:xp (feat count) ? preferred with many location feats.
			-- X:jumps:achMask:xp / S:jumps:achMask ? legacy bitmask (capped).
			local jumps, achs, achMask, xp
			jumps, achs, xp = message:match("^Y:(%d+):(%d+):(%d+)$")
			if jumps then
				achs = tonumber(achs) or 0
				achMask = 0
				xp = tonumber(xp)
			else
				jumps, achMask, xp = message:match("^X:(%d+):(%d+):(%d+)$")
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
				achs = nil
			end
			jumps = tonumber(jumps)
			achMask = tonumber(achMask) or 0
			xp = tonumber(xp)
			-- Allow 0 jumps; only reject missing parse / sender.
			if jumps == nil or not sender then
				return
			end
			local short = Ambiguate(sender, "short")
			local myKey, myName = ns.PlayerIdentity()
			local boardKey = Ambiguate(sender, "none") or sender
			if myName and short == myName then
				boardKey = myKey or boardKey
			elseif myKey and boardKey == myKey then
				boardKey = myKey
			end
			ns.StoreScore(boardKey, short, jumps, achMask, xp, achs)
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
				ns.UpdateLeaderboard()
			end
		end
	end
end)
SLASH_AJH1 = "/ajh"
SLASH_AJH2 = "/jumphabit"
SlashCmdList.AJH = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "say" or msg == "party" or msg == "guild" or msg == "g" then
		local channel = msg
		if channel == "g" then
			channel = "guild"
		end
		ns.AnnounceStatus(string.upper(channel))
		return
	end
	if msg == "sync" then
		ns.EnsureDB()
		if GuildRoster then
			pcall(GuildRoster)
		end
		ns.RequestGuildScores()
		ns.UpdateLeaderboard()
		local boardCount = 0
		if type(AJHSaved) == "table" and type(ns.DB().board) == "table" then
			for _ in pairs(ns.DB().board) do
				boardCount = boardCount + 1
			end
		end
		local online = ns.IterOnlineGuildNames()
		local prefixOk = "?"
		if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
			prefixOk = tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(ADDON_PREFIX))
		end
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH guild sync:|r")
		DEFAULT_CHAT_FRAME:AddMessage("  inGuild=" .. tostring(IsInGuild()) .. " prefixReg=" .. prefixOk)
		DEFAULT_CHAT_FRAME:AddMessage("  onlinePeers=" .. tostring(#online) .. " boardRows=" .. tostring(boardCount))
		DEFAULT_CHAT_FRAME:AddMessage("  lastSend=" .. tostring(lastGuildSendNote))
		DEFAULT_CHAT_FRAME:AddMessage("  lastSync=" .. tostring(lastGuildSyncNote))
		DEFAULT_CHAT_FRAME:AddMessage("  lastRecv=" .. tostring(lastGuildRecvNote))
		if #online > 0 then
			DEFAULT_CHAT_FRAME:AddMessage("  peers: " .. table.concat(online, ", "))
		else
			DEFAULT_CHAT_FRAME:AddMessage("  peers: (none online in roster ? wait a second and /ajh sync again)")
		end
		return
	end
	if msg == "debug" or msg == "copy" then
		ns.EnsureDB()
		ns.DebugDump("manual /ajh " .. msg)
		ns.ShowDebugCopyFrame(ns.GetDebugLogText())
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Debug window opened ? Ctrl+A, Ctrl+C to copy.")
		return
	end
	if msg == "diag" or msg == "diag on" or msg == "diag off" or msg:match("^diag%s") then
		local arg = msg:match("^diag%s*(.*)$") or ""
		arg = strtrim(arg)
		if arg == "on" then
			DIAG_ENABLED = true
			ns.DiagChat("auto diag ON")
			return
		elseif arg == "off" then
			DIAG_ENABLED = false
			ns.DiagChat("auto diag OFF")
			return
		end
		ns.DiagPrintSnapshot(ns.DiagSnapshot("manual/now"), true)
		if diagRawAtAddonLoaded then
			ns.DiagPrintSnapshot(diagRawAtAddonLoaded, true)
		end
		if diagAfterBind then
			ns.DiagPrintSnapshot(diagAfterBind, true)
		end
		ns.DiagReport("manual")
		return
	end
	ns.EnsureDB()
	if msg == "clear" or msg == "reset" then
		ns.ClearAccountProgress()
		local key = ns.PlayerIdentity()
		if key and ns.DB().board then
			ns.DB().board[key] = nil
		end
		ns.BroadcastScore()
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Jump count and XP reset.")
		if panel and panel:IsShown() then
			panel:Update()
		else
			ns.UpdateJumpXPBar()
		end
	elseif msg == "where" then
		local ctx = ns.GetJumpContext()
		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"|cff88ff88AJH:|r Zone: %s  |  Sub: %s  |  Mini: %s  |  Map: %s  |  Instance: %s",
			ctx.zone ~= "" and ctx.zone or "?",
			ctx.sub ~= "" and ctx.sub or "?",
			ctx.mini ~= "" and ctx.mini or "?",
			tostring(ctx.mapID or "?"),
			ctx.instanceType
		))
	elseif msg == "help" then
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH commands:|r")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh ? open panel")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh say | party | guild ? announce level & jumps")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh sync ? refresh guild leaderboard")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh where ? debug zone names")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh clear ? reset jumps and XP")
	else
		ns.TogglePanel()
	end
end
