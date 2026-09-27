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
ns.MAX_LEVEL = MAX_LEVEL
ns.XP_PER_JUMP = 1
local XP_PER_JUMP = ns.XP_PER_JUMP
ns.CAMP_XP_MULTIPLIER = 2
local CAMP_XP_MULTIPLIER = ns.CAMP_XP_MULTIPLIER
local ADDON_PREFIX = "AJH"
ns.ADDON_PREFIX = ADDON_PREFIX
local ROW_HEIGHT = 22
ns.ROW_HEIGHT = ROW_HEIGHT
local FROG_ICON = "Interface\\Icons\\Spell_Shaman_Hex"
ns.FROG_ICON = FROG_ICON
-- Retail achievements vibe: classic yellow achievement badge for the Feats tab portrait.
local FEATS_ICON = "Interface\\Icons\\Achievement_General"
ns.FEATS_ICON = FEATS_ICON

-- Session + UI state shared across AJH_*.lua
ns.S = ns.S or {}
local S = ns.S
S.sessionJumps = S.sessionJumps or 0
S.lastAcceptedJumpTime = S.lastAcceptedJumpTime or 0
S.sessionStartTime = S.sessionStartTime or 0

-- Local testing only. Enabled when Interface/AddOns/AJH/AJH_Dev exists
-- (gitignored; never shipped in the CurseForge zip). Not listed in the TOC.
local DEV_TOOLS = false
ns.DEV_TOOLS = DEV_TOOLS
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
				ns.DEV_TOOLS = true
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
ns.C = C

-- RuneScape cumulative XP required to reach each level.
local xpForLevel = { [1] = 0 }
ns.xpForLevel = xpForLevel
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
-- Never invent AJHSaved = {} when the client failed to load it Ã¢â‚¬â€ that empties the WTF file.
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
		f:EnableMouse(true)
		f:SetMovable(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		if UISpecialFrames then tinsert(UISpecialFrames, "AJHDebugCopyFrame") end
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.92)
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOP", 0, -14)
		title:SetText("AJH Debug â€” Ctrl+A / Ctrl+C")
		local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -36)
		scroll:SetPoint("BOTTOMRIGHT", -36, 44)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetFontObject(GameFontHighlightSmall)
		edit:SetWidth(460)
		edit:SetAutoFocus(false)
		edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
		scroll:SetScrollChild(edit)
		f.edit = edit
		local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		close:SetSize(80, 22)
		close:SetPoint("BOTTOMRIGHT", -16, 14)
		close:SetText("Close")
		close:SetScript("OnClick", function() f:Hide() end)
		debugCopyFrame = f
	end
	debugCopyFrame.edit:SetText(text or "")
	debugCopyFrame:Show()
	debugCopyFrame.edit:SetFocus()
	debugCopyFrame.edit:HighlightText()
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
	if type(db.trackedFeats) ~= "table" then
		db.trackedFeats = {}
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
	if db.showMinimapButton == nil then
		db.showMinimapButton = true
	else
		db.showMinimapButton = not not db.showMinimapButton
	end
	if db.showFeatToasts == nil then
		db.showFeatToasts = true
	else
		db.showFeatToasts = not not db.showFeatToasts
	end
	db.sessionJumpHigh = math.max(0, math.floor(ns.ToNumberOr(db.sessionJumpHigh, 0) or 0))
	db.playTime = math.max(0, ns.ToNumberOr(db.playTime, 0) or 0)
	db.jumpActivityTime = math.max(0, ns.ToNumberOr(db.jumpActivityTime, 0) or 0)
	if type(db.jumpDayKeys) ~= "table" then
		db.jumpDayKeys = {}
	end
	db.announceCount = math.max(0, math.floor(ns.ToNumberOr(db.announceCount, 0) or 0))
end

-- Forever sometimes leaves AJHSaved nil after /reload or a full restart even
-- when the WTF file is fine. Creating AJHSaved = {} would then be saved over
-- the good file. Use an ephemeral session table until/unless AJHSaved appears.
local svReady = false
local sessionDB = nil
local liveDB = nil
local warnedMissingSV = false
local dbDefaultsReady = false

function ns.AdoptSavedIfPresent()
	if type(AJHSaved) ~= "table" then
		return false
	end
	if sessionDB and sessionDB ~= AJHSaved then
		ns.RaiseMergeRecord(AJHSaved, sessionDB)
		sessionDB = nil
		dbDefaultsReady = false
		ns.InvalidateOwnAchCount()
	end
	-- Fill defaults once per adopt/merge Ã¢â‚¬â€ not on every EnsureDB (jump hot path).
	if liveDB ~= AJHSaved or not dbDefaultsReady then
		ns.FillDBDefaults(AJHSaved)
		dbDefaultsReady = true
	end
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
		dbDefaultsReady = true
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
			"|cff88ff88AJH:|r Saved progress loaded late Ã¢â‚¬â€ %s jumps (%s XP).",
			tostring(AJHSaved.jumps or 0),
			tostring(AJHSaved.xp or 0)
		))
	end
	if S.panel then
		S.panel:Update()
	end
	if ns.RestoreJumpXPBarFromSaved then
		ns.RestoreJumpXPBarFromSaved()
	end
end

function ns.DiagReport(tag)
	ns.DebugDump(tag == "manual" and "manual diag" or (tag or "diag"))
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
	xp = tonumber(xp) or 0
	local lo, hi = 1, MAX_LEVEL
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if xp >= xpForLevel[mid] then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end

-- Camp Benefit: cache on UNIT_AURA (jump-hook aura reads are secret/tainted on Forever).
local campBenefitActive = false
local campBenefitSpellID

local function auraNameIsCampBenefit(name)
	return type(name) == "string" and strlower(name):find("camp benefit", 1, true) ~= nil
end

function ns.ScanCampBenefit()
	local function tryByName()
		if not (AuraUtil and AuraUtil.FindAuraByName) then return nil end
		return AuraUtil.FindAuraByName("Camp Benefit", "player", "HELPFUL")
	end
	local nameOk, name, _, _, _, _, _, _, _, _, spellID = pcall(tryByName)
	if not nameOk then
		if campBenefitSpellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
			local idOk, data = pcall(C_UnitAuras.GetPlayerAuraBySpellID, campBenefitSpellID)
			return idOk and data ~= nil
		end
		return false
	end
	if auraNameIsCampBenefit(name) then
		if type(spellID) == "number" and spellID > 0 then campBenefitSpellID = spellID end
		return true
	end
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
			if not ok then return false end
			if not data then break end
			if auraNameIsCampBenefit(data.name) then
				if type(data.spellId) == "number" and data.spellId > 0 then campBenefitSpellID = data.spellId end
				return true
			end
		end
		return false
	end
	if UnitBuff then
		for i = 1, 40 do
			local ok, buffName = pcall(UnitBuff, "player", i)
			if not ok then return false end
			if not buffName then break end
			if auraNameIsCampBenefit(buffName) then return true end
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
	return campBenefitActive and (XP_PER_JUMP * CAMP_XP_MULTIPLIER) or XP_PER_JUMP
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
function ns.NormName(s)
	return strlower(strtrim(s or ""))
end

function ns.FrameIsShown(frame)
	return frame and frame.IsShown and frame:IsShown()
end

-- Reused across GetJumpContext calls (avoid per-jump table/closure alloc).
local jumpCtxSpots
local jumpCtxMapID
local jumpCtxInPlace
local jumpCtxSpotContains
local jumpCtxMatchesLocation
local jumpCtxReusable

function ns.TodayKey(offsetDays)
	offsetDays = offsetDays or 0
	local t = time() - (offsetDays * 86400)
	return date("%Y-%m-%d", t)
end

local cachedJumpDayKey
local cachedJumpDayStreak

function ns.NoteJumpDay()
	local db = ns.EnsureDB()
	if not db then
		return 0
	end
	local key = ns.TodayKey(0)
	local already = db.jumpDayKeys[key]
	db.jumpDayKeys[key] = true
	-- Same calendar day already marked this session Ã¢â‚¬â€ reuse streak.
	if already and cachedJumpDayKey == key and cachedJumpDayStreak then
		return cachedJumpDayStreak
	end
	local streak = 0
	for i = 0, 60 do
		if db.jumpDayKeys[ns.TodayKey(i)] then
			streak = streak + 1
		else
			break
		end
	end
	cachedJumpDayKey = key
	cachedJumpDayStreak = streak
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

	-- Reuse spot list + match closures across jumps (hot path).
	local spots = jumpCtxSpots
	if not spots then
		spots = { "", "", "" }
		jumpCtxSpots = spots
	end
	spots[1] = ns.NormName(zone)
	spots[2] = ns.NormName(sub)
	spots[3] = ns.NormName(mini)
	jumpCtxMapID = mapID

	if not jumpCtxInPlace then
		jumpCtxInPlace = function(...)
			for i = 1, select("#", ...) do
				local want = ns.NormName(select(i, ...))
				for j = 1, 3 do
					local spot = jumpCtxSpots[j]
					if spot ~= "" and spot == want then
						return true
					end
				end
			end
			return false
		end
		jumpCtxSpotContains = function(...)
			for i = 1, select("#", ...) do
				local needle = ns.NormName(select(i, ...))
				if needle ~= "" then
					for j = 1, 3 do
						local spot = jumpCtxSpots[j]
						if spot ~= "" and spot:find(needle, 1, true) then
							return true
						end
					end
				end
			end
			return false
		end
		jumpCtxMatchesLocation = function(loc)
			local mid = jumpCtxMapID
			if loc.mapIDs and mid then
				for _, id in ipairs(loc.mapIDs) do
					if mid == id then
						return true
					end
				end
			end
			for _, name in ipairs(loc.match) do
				if jumpCtxInPlace(name) then
					return true
				end
			end
			return false
		end
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

	local inPlace = jumpCtxInPlace
	local spotContains = jumpCtxSpotContains
	local ctx = jumpCtxReusable
	if not ctx then
		ctx = {}
		jumpCtxReusable = ctx
	end
	ctx.zone = zone
	ctx.sub = sub
	ctx.mini = mini
	ctx.mapID = mapID
	ctx.instanceType = instanceType
	ctx.inPlace = inPlace
	ctx.spotContains = spotContains
	ctx.matchesLocation = jumpCtxMatchesLocation
	ctx.fromJump = not not extra.fromJump
	ctx.idleGap = tonumber(extra.idleGap) or 0
	ctx.dayStreak = tonumber(extra.dayStreak) or 0
	ctx.combat = UnitAffectingCombat and UnitAffectingCombat("player") or false
	ctx.mounted = IsMounted and IsMounted() or false
	ctx.swimming = (IsSwimming and IsSwimming()) or (IsSubmerged and IsSubmerged()) or false
	ctx.dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") or false
	ctx.ghost = UnitIsGhost and UnitIsGhost("player") or false
	ctx.taxi = UnitOnTaxi and UnitOnTaxi("player") or false
	ctx.grouped = IsInGroup and IsInGroup() or false
	ctx.raid = IsInRaid and IsInRaid() or false
	ctx.camp = ns.HasCampBenefit and ns.HasCampBenefit() or false
	ctx.hour = hour
	ctx.night = hour >= 21 or hour < 5
	ctx.pvpType = pvpType
	ctx.contested = pvpType == "contested"
	ctx.indoors = indoors
	ctx.atAuction = ns.FrameIsShown(AuctionFrame) or ns.FrameIsShown(AuctionHouseFrame)
	ctx.atMail = ns.FrameIsShown(MailFrame)
	ctx.atTrainer = ns.FrameIsShown(ClassTrainerFrame) or ns.FrameIsShown(TrainerFrame)
	ctx.onTransport = spotContains(
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
	) or inPlace("the thundercaller", "the purple princess", "the maiden's fancy")
	ctx.gmIsland = inPlace("gm island", "designer island") or spotContains("gm island")
	return ctx
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
ns.ACHIEVEMENTS = ACHIEVEMENTS
local CITY_LOCATIONS = ns.CITY_LOCATIONS
local TOWN_LOCATIONS = ns.TOWN_LOCATIONS
local DUNGEON_LOCATIONS = ns.DUNGEON_LOCATIONS
local RAID_LOCATIONS = ns.RAID_LOCATIONS
local FEAT_CATEGORIES = ns.FEAT_CATEGORIES
-- FEAT_CATEGORIES already on ns
local PRIDE_LINES = ns.PRIDE_LINES

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

do
	local function add(id, cat, name, desc, test, opts)
		ACHIEVEMENTS[#ACHIEVEMENTS + 1] = ns.MakeFeat(id, cat, name, desc, test, opts)
	end
	local JUMP = { requiresJump = true }
	local function flag(key)
		return function(ctx) return ctx[key] end
	end

	add("jumps_100", "milestone", "Century Hopper", "Reach 100 lifetime jumps.", function() return ns.DB().jumps >= 100 end)
	add("jumps_1000", "milestone", "Thousand Hops", "Reach 1,000 lifetime jumps.", function() return ns.DB().jumps >= 1000 end)
	add("jumps_10000", "milestone", "Leg Day Legend", "Reach 10,000 lifetime jumps.", function() return ns.DB().jumps >= 10000 end)
	add("level_10", "milestone", "Getting Air", "Reach Jump Habit level 10.", function() return ns.GetLevel(ns.DB().xp) >= 10 end)
	add("level_40", "milestone", "Serious Bounce", "Reach Jump Habit level 40.", function() return ns.GetLevel(ns.DB().xp) >= 40 end)
	add("level_70", "milestone", "Vertical Authority", "Reach Jump Habit level 70.", function() return ns.GetLevel(ns.DB().xp) >= 70 end)
	add("level_99", "milestone", "Habit Maxed", "Reach Jump Habit level 99.", function() return ns.GetLevel(ns.DB().xp) >= 99 end)
	add("streak_3", "milestone", "Three-Day Tick", "Jump on 3 consecutive calendar days.", function(ctx) return (ctx.dayStreak or 0) >= 3 end, JUMP)
	add("streak_7", "milestone", "Weekly Legs", "Jump on 7 consecutive calendar days.", function(ctx) return (ctx.dayStreak or 0) >= 7 end, JUMP)
	add("streak_30", "milestone", "Monthly Devotion", "Jump on 30 consecutive calendar days.", function(ctx) return (ctx.dayStreak or 0) >= 30 end, JUMP)
	add("session_50", "milestone", "Warm-Up Crush", "Make 50 jumps in a single session.", function() return S.sessionJumps >= 50 end)
	add("session_200", "milestone", "Session Savage", "Make 200 jumps in a single session.", function() return S.sessionJumps >= 200 end)

	for _, row in ipairs({
		{ "camp_jump", "style", "Camp Cadet", "Jump while Camp Benefit is active.", "camp" },
		{ "combat_jump", "style", "Fight Hop", "Jump while in combat.", "combat" },
		{ "mounted_jump", "style", "Saddle Skip", "Jump while mounted.", "mounted" },
		{ "swim_jump", "style", "Splash Hop", "Jump while swimming.", "swimming" },
		{ "indoor_jump", "style", "Ceiling Tester", "Jump while indoors.", "indoors" },
		{ "night_jump", "style", "Midnight Bounce", "Jump between 21:00 and 05:00.", "night" },
		{ "taxi_jump", "travel", "Bird Brain", "Jump while on a flight path.", "taxi" },
		{ "transport_jump", "travel", "Deck Cadet", "Jump on a boat or zeppelin deck.", "onTransport" },
		{ "contested_jump", "travel", "Orange Zone", "Jump in a contested PvP zone.", "contested" },
		{ "raid_jump", "social", "Raid Hop", "Jump while in a raid group.", "raid" },
		{ "ah_jump", "oddity", "Bid High", "Jump with the auction house open.", "atAuction" },
		{ "mail_jump", "oddity", "Postage Due", "Jump with the mailbox open.", "atMail" },
		{ "trainer_jump", "oddity", "Class Is in Session", "Jump with a class trainer open.", "atTrainer" },
		{ "gm_island", "oddity", "Wrong Neighborhood", "Jump on GM Island (if you somehow get there).", "gmIsland" },
	}) do
		add(row[1], row[2], row[3], row[4], flag(row[5]), JUMP)
	end
	add("ghost_jump", "travel", "Spectral Skip", "Jump while dead or as a ghost.", function(ctx) return ctx.dead or ctx.ghost end, JUMP)
	add("party_jump", "social", "Group Bounce", "Jump while in a party.", function(ctx) return ctx.grouped and not ctx.raid end, JUMP)
	add("announce_5", "social", "Guild Flex", "Announce your Jump Habit status 5 times.", function() return (ns.DB().announceCount or 0) >= 5 end)
	add("announce_25", "social", "Town Crier", "Announce your Jump Habit status 25 times.", function() return (ns.DB().announceCount or 0) >= 25 end)
	add("ajh_peers", "social", "Shared Habit", "Jump while 2+ AJH players are on your guild board.", function()
		local db = ns.DB()
		if type(db.board) ~= "table" then return false end
		local n = 0
		for _ in pairs(db.board) do
			n = n + 1
			if n >= 2 then return true end
		end
		return false
	end, JUMP)
	add("meta_capitals", "collection", "Capital Circuit", "Jump in every capital city (yours and theirs).", function()
		local achs = ns.DB().achievements
		for _, loc in ipairs(CITY_LOCATIONS) do
			if not achs[loc.id] then return false end
		end
		return true
	end)
	add("meta_towns_friendly", "collection", "Hometown Hero", "Complete every friendly/neutral Town Jumper feat.", function() return ns.AllLocationFeatsEarned("town") end)
	add("meta_hostile", "collection", "Enemy Tourism", "Complete every Hostile Territory feat.", function() return ns.AllLocationFeatsEarned("hostile") end)
	add("meta_dungeons", "collection", "Dungeon Tourist", "Jump in every dungeon.", function() return ns.AllLocationFeatsEarned("dungeon") end)
	add("meta_raids", "collection", "Raid Tourist", "Jump in every raid.", function() return ns.AllLocationFeatsEarned("raid") end)
	add("idle_30", "oddity", "Archindula Noticed", "Jump after 30+ minutes without jumping.", function(ctx) return (ctx.idleGap or 0) >= 1800 end, JUMP)
end

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

ns.MAX_TRACKED_FEATS = 5

function ns.FindAchievement(id)
	if not id then
		return nil
	end
	for _, ach in ipairs(ACHIEVEMENTS) do
		if ach.id == id then
			return ach
		end
	end
	return nil
end

function ns.IsFeatTracked(id)
	local db = ns.DB()
	if type(db) ~= "table" or type(db.trackedFeats) ~= "table" then
		return false
	end
	for _, trackedId in ipairs(db.trackedFeats) do
		if trackedId == id then
			return true
		end
	end
	return false
end

-- Drop completed / unknown ids. Returns true if the list changed.
function ns.PruneTrackedFeats()
	local db = ns.EnsureDB()
	if not db or type(db.trackedFeats) ~= "table" then
		return false
	end
	local achs = db.achievements
	local kept = {}
	local changed = false
	for _, id in ipairs(db.trackedFeats) do
		local ach = ns.FindAchievement(id)
		if ach and not (achs and achs[id]) then
			kept[#kept + 1] = id
		else
			changed = true
		end
	end
	if changed or #kept ~= #db.trackedFeats then
		db.trackedFeats = kept
		return true
	end
	return false
end

function ns.GetTrackedFeatList()
	ns.PruneTrackedFeats()
	local db = ns.DB()
	local list = {}
	if type(db) ~= "table" or type(db.trackedFeats) ~= "table" then
		return list
	end
	for _, id in ipairs(db.trackedFeats) do
		local ach = ns.FindAchievement(id)
		if ach then
			list[#list + 1] = ach
		end
	end
	return list
end

function ns.ToggleFeatTrack(id)
	local db = ns.EnsureDB()
	if not db or not id then
		return false
	end
	if type(db.trackedFeats) ~= "table" then
		db.trackedFeats = {}
	end

	for i, trackedId in ipairs(db.trackedFeats) do
		if trackedId == id then
			table.remove(db.trackedFeats, i)
			local ach = ns.FindAchievement(id)
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff88ff88AJH:|r Stopped tracking |cffffffff%s|r.",
				ach and ach.name or id
			))
			if ns.UpdateFeatTracker then
				ns.UpdateFeatTracker()
			end
			return false
		end
	end

	if db.achievements and db.achievements[id] then
		DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r That feat is already complete.")
		return false
	end
	if not ns.FindAchievement(id) then
		return false
	end
	if #db.trackedFeats >= ns.MAX_TRACKED_FEATS then
		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"|cff88ff88AJH:|r Already tracking %d feats (max).",
			ns.MAX_TRACKED_FEATS
		))
		return false
	end

	db.trackedFeats[#db.trackedFeats + 1] = id
	local ach = ns.FindAchievement(id)
	DEFAULT_CHAT_FRAME:AddMessage(string.format(
		"|cff88ff88AJH:|r Tracking |cffffffff%s|r.",
		ach and ach.name or id
	))
	if ns.UpdateFeatTracker then
		ns.UpdateFeatTracker()
	end
	return true
end
-- Shared UI/toast state (same ns.S table as above).
S.activeTab = S.activeTab or "habit"
S.toastQueue = S.toastQueue or {}
S.toastBusy = not not S.toastBusy

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
	if S.toastFrame then
		return S.toastFrame
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

	S.toastFrame = f
	return f
end

function ns.ShowNextToast()
	if S.toastBusy then
		return
	end
	local toast = tremove(S.toastQueue, 1)
	if not toast then
		return
	end

	S.toastBusy = true
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
			S.toastBusy = false
			ns.ShowNextToast()
		end
	end)
end

function ns.QueueToast(toast)
	tinsert(S.toastQueue, toast)
	ns.ShowNextToast()
end

function ns.QueueAchievementToast(ach)
	local db = ns.DB()
	if db and db.showFeatToasts == false then
		-- Banner off; still play fanfare when sounds are enabled.
		ns.PlayAchievementSound()
		return
	end
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
	local db = ns.EnsureDB()
	if not db then
		return 0
	end
	local mask = 0
	local achs = db.achievements
	local limit = math.min(#ACHIEVEMENTS, 31)
	for i = 1, limit do
		local ach = ACHIEVEMENTS[i]
		if ach and achs[ach.id] then
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

local ownAchCountCache

function ns.InvalidateOwnAchCount()
	ownAchCountCache = nil
end

function ns.CountOwnAchievements()
	if ownAchCountCache then
		return ownAchCountCache
	end
	local db = ns.EnsureDB()
	if not db then
		return 0
	end
	local n = 0
	local achs = db.achievements
	for _, ach in ipairs(ACHIEVEMENTS) do
		if achs[ach.id] then
			n = n + 1
		end
	end
	ownAchCountCache = n
	return n
end

function ns.UnlockAchievement(ach)
	local db = ns.EnsureDB()
	if not db then
		return false
	end
	if db.achievements[ach.id] then
		return false
	end

	db.achievements[ach.id] = time()
	ns.InvalidateOwnAchCount()
	ns.PruneTrackedFeats()
	if ns.UpdateFeatTracker then
		ns.UpdateFeatTracker()
	end
	DEFAULT_CHAT_FRAME:AddMessage(string.format(
		"|cff88ff88AJH:|r Feat unlocked: |cffffffff%s|r - %s",
		ach.name,
		ach.desc
	))

	ns.QueueAchievementToast(ach)

	if db.autoAnnounce and IsInGuild() then
		SendChatMessage(
			string.format("Jump Habit Feat: %s - %s", ach.name, ach.desc),
			"GUILD"
		)
	end

	ns.BroadcastScore()
	return true
end

function ns.CheckAchievementsOnJump(extra)
	local db = ns.EnsureDB()
	if not db then
		return false
	end
	extra = extra or {}
	local fromJump = not not extra.fromJump
	extra.fromJump = fromJump
	local ctx = ns.GetJumpContext(extra)
	local achs = db.achievements
	local earned = false
	for _, ach in ipairs(ACHIEVEMENTS) do
		if not achs[ach.id] then
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
	local db = ns.EnsureDB()
	if not db then
		return
	end
	db.achievements = {}
	db.trackedFeats = {}
	ns.InvalidateOwnAchCount()
	ns.BroadcastScore()
	DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Feats reset for testing.")
	if ns.UpdateFeatTracker then
		ns.UpdateFeatTracker()
	end
	if S.panel and S.panel:IsShown() then
		if S.activeTab == "achieves" then
			ns.UpdateAchievements()
		elseif S.activeTab == "guild" then
			ns.UpdateLeaderboard()
		end
	end
end

S.ui = S.ui or {}
local ui = S.ui
ui.tabs = ui.tabs or {}
ui.pages = ui.pages or {}
ui.levelRows = ui.levelRows or {}
ui.boardRows = ui.boardRows or {}
ui.achRows = ui.achRows or {}
ui.featCatRows = ui.featCatRows or {}
local lastGuildReply = 0
-- Shared guild-sync notes (AJH_UI.lua writes send/sync; core writes recv).
S.guildSendNote = S.guildSendNote or "none"
S.guildSyncNote = S.guildSyncNote or "not-run"
S.guildRecvNote = S.guildRecvNote or "none"
-- Movable HUD bar heights (used by AJH_UI.lua).
ns.JUMP_XP_BAR_HEIGHT = 14
ns.HABIT_PANEL_XP_BAR_HEIGHT = 22

-- Session statistics (not SavedVariables), except playTime / sessionJumpHigh in AJHSaved.
-- Session counters live on ns.S (shared with AJH_UI.lua).
local JUMP_TIME_RING_SIZE = 200
local jumpTimeRing = {}
local jumpTimeRingCount = 0
local jumpTimeRingNext = 1
-- Seconds of play already credited into ns.DB().playTime this login.
local playTimeFlushed = 0
local playTimeTicker
-- Attributed active time per accepted jump (matches jump cooldown cadence).
local JUMP_ACTIVITY_SEC = 0.8
ns.JUMP_ACTIVITY_SEC = JUMP_ACTIVITY_SEC

function ns.EnsureSessionClock()
	if S.sessionStartTime <= 0 then
		S.sessionStartTime = GetTime()
	end
end

function ns.CurrentSessionElapsed()
	ns.EnsureSessionClock()
	return math.max(0, GetTime() - S.sessionStartTime)
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
	return string.format("%.0f%% jumping - %.0f%% idle", jumpPct, idlePct)
end

function ns.RecordSessionJump(now)
	ns.EnsureSessionClock()
	S.sessionJumps = S.sessionJumps + 1
	S.lastAcceptedJumpTime = now
	jumpTimeRing[jumpTimeRingNext] = now
	jumpTimeRingNext = (jumpTimeRingNext % JUMP_TIME_RING_SIZE) + 1
	if jumpTimeRingCount < JUMP_TIME_RING_SIZE then
		jumpTimeRingCount = jumpTimeRingCount + 1
	end
end

function ns.NoteSessionJumpHigh()
	ns.EnsureDB()
	local high = ns.DB().sessionJumpHigh or 0
	if S.sessionJumps > high then
		ns.DB().sessionJumpHigh = S.sessionJumps
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
		if not S.panel or not S.panel:IsShown() or S.activeTab ~= "stats" or ui.statsView ~= "main" then
			ns.StopStatsTicker()
			return
		end
		S.panel:Update()
	end)
end

function ns.SyncStatsTicker()
	if S.panel and S.panel:IsShown() and S.activeTab == "stats" and ui.statsView == "main" then
		if not statsTicker then
			ns.StartStatsTicker()
		end
	else
		ns.StopStatsTicker()
	end
end

function ns.ShowStatsView(view)
	ui.statsView = view or "main"
	local showMain = ui.statsView == "main"
	if ui.statsWrap then
		ui.statsWrap:SetShown(showMain)
	elseif ui.statsMain then
		ui.statsMain:SetShown(showMain)
	end
	if ui.levelsButton then
		ui.levelsButton:SetShown(showMain)
	end
	if ui.statsLevels then
		ui.statsLevels:SetShown(ui.statsView == "levels")
	end
	if showMain and type(ui.LayoutStatsScroll) == "function" then
		C_Timer.After(0, ui.LayoutStatsScroll)
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

local JUMP_COOLDOWN = JUMP_ACTIVITY_SEC
local lastJumpTime = 0

function ns.OnJump()
	local now = GetTime()
	if now - lastJumpTime < JUMP_COOLDOWN then
		return
	end
	lastJumpTime = now
	local idleGap = (S.lastAcceptedJumpTime > 0) and (now - S.lastAcceptedJumpTime) or 0
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
	if ns.CheckAchievementsOnJump({ idleGap = idleGap, dayStreak = dayStreak, fromJump = true }) and S.panel and S.panel:IsShown() and S.activeTab == "achieves" then
		ns.UpdateAchievements()
	end
	if S.panel and S.panel:IsShown() then
		S.panel:Update()
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
	if ns.EnsureFeatTracker then
		ns.EnsureFeatTracker()
	end
	if not jumpHookInstalled then
		jumpHookInstalled = true
		hooksecurefunc("JumpOrAscendStart", ns.OnJump)
	end
	ns.RefreshCampBenefit()
	-- Keep lifetime play time moving even when the S.panel is closed.
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
		if S.panel then
			S.panel:Update()
		end
		ns.RestoreJumpXPBarFromSaved()
		if C_Timer and C_Timer.After then
			C_Timer.After(0.5, ns.RestoreJumpXPBarFromSaved)
			C_Timer.After(0.5, ns.TryLateSavedAdopt)
			C_Timer.After(2, ns.TryLateSavedAdopt)
			C_Timer.After(5, ns.TryLateSavedAdopt)
			C_Timer.After(1, function()
				if ns.EnsureDB() then
					-- Progress feats only Ã¢â‚¬â€ never location/situational (those need a real jump).
					ns.CheckAchievementsGeneral()
				end
			end)
		end
	elseif event == "PLAYER_LOGOUT" then
		-- Only flush into the real SavedVariable. If Forever never loaded it,
		-- leave AJHSaved unset so the client does not write an empty table.
		if type(AJHSaved) == "table" then
			ns.EnsureDB()
			ns.FlushPlayTime()
		end
	elseif event == "UNIT_AURA" then
		if ns.RefreshCampBenefit() and S.panel and S.panel:IsShown() then
			S.panel:Update()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.TryLateSavedAdopt()
		ns.EnsureDB()
		ns.RefreshCampBenefit()
		if S.panel then
			S.panel:Update()
		end
		C_Timer.After(0, function()
			ns.TryLateSavedAdopt()
			if ns.RefreshCampBenefit() and S.panel and S.panel:IsShown() then
				S.panel:Update()
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
			S.guildRecvNote = string.format("drop-chan prefix=%s chan=%s sender=%s", tostring(prefix), tostring(channel), tostring(sender))
			return
		end
		if type(message) ~= "string" or message == "" then
			return
		end
		-- Trim accidental whitespace / nulls from some clients.
		message = message:match("^([^%z]+)") or message
		message = strtrim(message)
		S.guildRecvNote = string.format("recv chan=%s sender=%s msg=%s", tostring(channel), tostring(sender), message)
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
			if DEFAULT_CHAT_FRAME and (DEV_TOOLS or (S.panel and S.panel:IsShown() and S.activeTab == "guild")) then
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
			if S.panel and S.panel:IsShown() and S.activeTab == "guild" then
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
		DEFAULT_CHAT_FRAME:AddMessage("  lastSend=" .. tostring(S.guildSendNote))
		DEFAULT_CHAT_FRAME:AddMessage("  lastSync=" .. tostring(S.guildSyncNote))
		DEFAULT_CHAT_FRAME:AddMessage("  lastRecv=" .. tostring(S.guildRecvNote))
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
	if msg == "diag" or msg:match("^diag") then
		ns.DiagReport("manual")
		return
	end
	if msg == "dumpframe" or msg == "dumpui" then
		ns.EnsureDB()
		local lines = {}
		local function add(s)
			lines[#lines + 1] = s
			DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r " .. s)
		end
		local function dumpFrame(f, label, depth)
			if not f or depth > 3 then
				return
			end
			local name = (f.GetName and f:GetName()) or "(anon)"
			local objType = (f.GetObjectType and f:GetObjectType()) or "?"
			add(string.format("%s%s [%s]", label, name, objType))
			if f.backdropInfo then
				local bi = f.backdropInfo
				add(string.format("  backdrop edge=%s edgeSize=%s bg=%s",
					tostring(bi.edgeFile), tostring(bi.edgeSize), tostring(bi.bgFile)))
			end
			if f.GetBackdropBorderColor then
				local r, g, b, a = f:GetBackdropBorderColor()
				if r then
					add(string.format("  borderColor=%.2f,%.2f,%.2f,%.2f", r, g, b or 1, a or 1))
				end
			end
			if f.NineSlice then
				add("  has NineSlice")
				for _, key in ipairs({
					"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
					"TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
				}) do
					local p = f.NineSlice[key]
					if p then
						local atlas = p.GetAtlas and p:GetAtlas()
						local tex = p.GetTexture and p:GetTexture()
						add(string.format("  NS.%s atlas=%s tex=%s", key, tostring(atlas), tostring(tex)))
					end
				end
			end
			if f.GetNumRegions then
				for i = 1, f:GetNumRegions() do
					local r = select(i, f:GetRegions())
					if r and r.GetObjectType and r:GetObjectType() == "Texture" then
						local atlas = r.GetAtlas and r:GetAtlas()
						local tex = r.GetTexture and r:GetTexture()
						if (atlas and atlas ~= "") or tex then
							add(string.format("  tex[%d] atlas=%s file=%s", i, tostring(atlas), tostring(tex)))
						end
					end
				end
			end
			if depth < 2 and f.GetChildren then
				local kids = { f:GetChildren() }
				for i = 1, math.min(#kids, 12) do
					dumpFrame(kids[i], label .. "  ", depth + 1)
				end
			end
		end
		local focus = GetMouseFoci and GetMouseFoci() or nil
		local target = focus and focus[1]
		if not target and GetMouseFocus then
			target = GetMouseFocus()
		end
		add("--- mouse focus ---")
		dumpFrame(target, "", 0)
		for _, n in ipairs({
			"PrimaryProfession1", "PrimaryProfession2",
			"SecondaryProfession1", "SecondaryProfession2", "SecondaryProfession3",
			"SpellBookFrame",
		}) do
			if _G[n] then
				add("--- " .. n .. " ---")
				dumpFrame(_G[n], "", 0)
			end
		end
		AJHSaved = AJHSaved or {}
		AJHSaved.uiDump = table.concat(lines, "\n")
		add("Saved to AJHSaved.uiDump — /reload then share if needed.")
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
		if S.panel and S.panel:IsShown() then
			S.panel:Update()
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
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh ? open S.panel")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh say | party | guild ? announce level & jumps")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh sync ? refresh guild leaderboard")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh where ? debug zone names")
		DEFAULT_CHAT_FRAME:AddMessage("  /ajh clear ? reset jumps and XP")
	else
		ns.TogglePanel()
	end
end
