local ADDON_NAME, ns = ...
local LibEditMode = ns and ns.LibEditMode

BINDING_HEADER_AJH = "Archindula's Jump Habit"
BINDING_NAME_AJH_TOGGLE = "Toggle Archindula's Jump Habit"

local MAX_LEVEL = 99
local XP_PER_JUMP = 1
local CAMP_XP_MULTIPLIER = 2
local ADDON_PREFIX = "AJH"
local ROW_HEIGHT = 22
local FROG_ICON = "Interface\\Icons\\Spell_Shaman_Hex"

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

local function EnsureDB()
	if type(AJHDB) ~= "table" then
		AJHDB = {}
	end

	AJHDB.jumps = ToNumberOr(AJHDB.jumps, AJHDB.jumps)
	if type(AJHDB.jumps) ~= "number" then
		AJHDB.jumps = 0
	end

	AJHDB.xp = ToNumberOr(AJHDB.xp, AJHDB.xp)
	if type(AJHDB.xp) ~= "number" then
		AJHDB.xp = AJHDB.jumps * XP_PER_JUMP
	elseif AJHDB.jumps > 0 and AJHDB.xp == AJHDB.jumps * 10 then
		AJHDB.xp = AJHDB.jumps
	end

	if type(AJHDB.board) ~= "table" then
		AJHDB.board = {}
	end
	AJHDB.minimapPos = ToNumberOr(AJHDB.minimapPos, 210)
	if type(AJHDB.minimapPos) ~= "number" then
		AJHDB.minimapPos = 210
	end
	if type(AJHDB.achievements) ~= "table" then
		AJHDB.achievements = {}
	end
	-- Jump XP bar: single always-on saved config (shown + position + width).
	if type(AJHDB.jumpXPBar) ~= "table" then
		AJHDB.jumpXPBar = {}
	end
	local barDB = AJHDB.jumpXPBar

	-- Migrate older keys into the flat config.
	if barDB.shown == nil and AJHDB.showJumpXPBar ~= nil then
		barDB.shown = not not AJHDB.showJumpXPBar
	end
	if barDB.shown == nil then
		barDB.shown = false
	else
		barDB.shown = not not barDB.shown
	end
	AJHDB.showJumpXPBar = barDB.shown -- keep alias in sync for older UI code paths

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

	if type(AJHDB.jumpXPBarPos) == "table" then
		local legacy = AJHDB.jumpXPBarPos
		adoptPos(legacy)
		if barDB.widthPct == nil and type(legacy.fullWidth) == "number" and legacy.fullWidth > 0 and type(legacy.width) == "number" then
			barDB.widthPct = math.floor((legacy.width / legacy.fullWidth) * 100 + 0.5)
		end
		AJHDB.jumpXPBarPos = nil
	end
	if type(AJHDB.jumpXPBarLayouts) == "table" then
		local layouts = AJHDB.jumpXPBarLayouts
		adoptPos(layouts.__legacy)
		for _, data in pairs(layouts) do
			if type(data) == "table" and data.point then
				adoptPos(data)
				break
			end
		end
		-- Keep layouts table for per-layout copies, but flat config is source of truth.
	else
		AJHDB.jumpXPBarLayouts = {}
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
end

local function PlayerBackupKey()
	local name, realm = UnitFullName("player")
	if not name then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName() or "Unknown"
	end
	return string.format("%s-%s", name, realm)
end

local function BackupProgress()
	EnsureDB()
	if type(AJHGlobalDB) ~= "table" then
		AJHGlobalDB = {}
	end
	local key = PlayerBackupKey()
	if not key then
		return
	end
	AJHGlobalDB[key] = {
		jumps = AJHDB.jumps,
		xp = AJHDB.xp,
		achievements = AJHDB.achievements,
		minimapPos = AJHDB.minimapPos,
		jumpXPBar = AJHDB.jumpXPBar and {
			shown = not not AJHDB.jumpXPBar.shown,
			point = AJHDB.jumpXPBar.point,
			x = AJHDB.jumpXPBar.x,
			y = AJHDB.jumpXPBar.y,
			widthPct = AJHDB.jumpXPBar.widthPct,
			userPlaced = not not AJHDB.jumpXPBar.userPlaced,
		} or nil,
		showJumpXPBar = AJHDB.jumpXPBar and AJHDB.jumpXPBar.shown or AJHDB.showJumpXPBar,
	}
end

local function RestoreProgress()
	EnsureDB()
	if type(AJHGlobalDB) ~= "table" then
		return
	end
	local key = PlayerBackupKey()
	local saved = key and AJHGlobalDB[key]
	if type(saved) ~= "table" then
		return
	end

	local savedJumps = ToNumberOr(saved.jumps, 0)
	if savedJumps > (AJHDB.jumps or 0) then
		AJHDB.jumps = savedJumps
		AJHDB.xp = ToNumberOr(saved.xp, savedJumps)
	end
	if (not AJHDB.minimapPos or AJHDB.minimapPos == 210) and saved.minimapPos then
		AJHDB.minimapPos = ToNumberOr(saved.minimapPos, 210)
	end
	if type(saved.jumpXPBar) == "table" then
		local backup = saved.jumpXPBar
		local bar = AJHDB.jumpXPBar
		if type(bar) ~= "table" then
			AJHDB.jumpXPBar = {
				shown = not not backup.shown,
				point = backup.point,
				x = backup.x,
				y = backup.y,
				widthPct = backup.widthPct,
				userPlaced = not not backup.userPlaced,
			}
		else
			-- Prefer account backup when per-character data looks unset.
			local charDefault = (not bar.userPlaced) and (not bar.shown)
			if backup.userPlaced and (not bar.userPlaced or charDefault) then
				bar.point = backup.point or bar.point
				bar.x = backup.x or bar.x
				bar.y = backup.y or bar.y
				bar.widthPct = backup.widthPct or bar.widthPct
				bar.userPlaced = true
			end
			if backup.shown and not bar.shown then
				bar.shown = true
			end
			for k, v in pairs(backup) do
				if bar[k] == nil then
					bar[k] = v
				end
			end
		end
		AJHDB.showJumpXPBar = not not AJHDB.jumpXPBar.shown
	elseif saved.showJumpXPBar and AJHDB.jumpXPBar and not AJHDB.jumpXPBar.shown then
		AJHDB.jumpXPBar.shown = true
		AJHDB.showJumpXPBar = true
	end
	if type(saved.achievements) == "table" then
		for id, when in pairs(saved.achievements) do
			if AJHDB.achievements[id] == nil then
				AJHDB.achievements[id] = when
			end
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

-- Zone/subzone names (English client). Brill + Undercity included for easy testing.
local CITIES = {
	["undercity"] = true,
	["orgrimmar"] = true,
	["thunder bluff"] = true,
	["silvermoon city"] = true,
	["stormwind city"] = true,
	["ironforge"] = true,
	["darnassus"] = true,
	["the exodar"] = true,
	["shattrath city"] = true,
}

local TOWNS = {
	["brill"] = true,
	["goldshire"] = true,
	["razor hill"] = true,
	["bloodhoof village"] = true,
	["dolanaar"] = true,
	["kharanos"] = true,
	["sen'jin village"] = true,
	["the crossroads"] = true,
	["tarren mill"] = true,
	["southshore"] = true,
	["booty bay"] = true,
	["gadgetzan"] = true,
	["everlook"] = true,
	["ratchet"] = true,
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

	-- Undercity map id (Classic / Forever)
	local inUndercity = inPlace("Undercity") or mapID == 90
	local inBrill = inPlace("Brill")

	-- Capitals / towns exclude Brill & Undercity so those stay unique achievements.
	local isCity = false
	for _, spot in ipairs(spots) do
		if CITIES[spot] and spot ~= "undercity" then
			isCity = true
			break
		end
	end

	local isTown = false
	for _, spot in ipairs(spots) do
		if TOWNS[spot] and spot ~= "brill" then
			isTown = true
			break
		end
	end

	return {
		zone = zone,
		sub = sub,
		mini = mini,
		mapID = mapID,
		instanceType = instanceType,
		inPlace = inPlace,
		inBrill = inBrill,
		inUndercity = inUndercity,
		isCity = isCity,
		isTown = isTown,
	}
end

local ACHIEVEMENTS = {
	{
		id = "brill",
		name = "Brill Bound",
		desc = "Jump once in Brill.",
		test = function(ctx)
			return ctx.inBrill
		end,
	},
	{
		id = "undercity",
		name = "Undercity Spring",
		desc = "Jump once in Undercity.",
		test = function(ctx)
			return ctx.inUndercity
		end,
	},
	{
		id = "city",
		name = "Capital Hopper",
		desc = "Jump in a capital city other than Undercity.",
		test = function(ctx)
			return ctx.isCity
		end,
	},
	{
		id = "town",
		name = "Small Town Hero",
		desc = "Jump in a town or village other than Brill.",
		test = function(ctx)
			return ctx.isTown
		end,
	},
	{
		id = "dungeon",
		name = "Dungeon Bounce",
		desc = "Jump inside a dungeon.",
		test = function(ctx)
			return ctx.instanceType == "party"
		end,
	},
	{
		id = "raid",
		name = "Raid Riser",
		desc = "Jump inside a raid.",
		test = function(ctx)
			return ctx.instanceType == "raid"
		end,
	},
}

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
	BackupProgress()
	DEFAULT_CHAT_FRAME:AddMessage(string.format(
		"|cff88ff88AJH:|r Achievement earned: |cffffffff%s|r - %s",
		ach.name,
		ach.desc
	))

	QueueAchievementToast(ach)

	if IsInGuild() then
		SendChatMessage(
			string.format("Jump Habit Achievement: %s - %s", ach.name, ach.desc),
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
	DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r Achievements reset for testing.")
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
		StatusTrackingBarManager,
		MainMenuBar,
	}

	local best
	for _, frame in ipairs(candidates) do
		local w = Span(frame)
		if w and (not best or w > best) then
			best = w
		end
	end

	-- Prefer a child bar inside the manager if it's larger/more accurate.
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

	local parentW = UIParent and UIParent.GetWidth and UIParent:GetWidth()
	if parentW and parentW > 100 then
		return parentW
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
	local width = full * ((state.widthPct or 100) / 100)
	holder:SetSize(width, JUMP_XP_BAR_HEIGHT)
	holder:ClearAllPoints()
	holder:SetPoint(state.point or "BOTTOM", UIParent, state.point or "BOTTOM", state.x or 0, state.y or 55)
	if holder.LayoutChrome then
		holder:LayoutChrome()
	end
end

local function CommitJumpXPBarState(state)
	EnsureDB()
	state = state or GetJumpXPBarState()
	local barDB = AJHDB.jumpXPBar
	barDB.shown = not not state.shown
	barDB.point = state.point or "BOTTOM"
	barDB.x = tonumber(state.x) or 0
	barDB.y = tonumber(state.y) or 55
	barDB.widthPct = tonumber(state.widthPct) or 100
	if barDB.widthPct < 50 then
		barDB.widthPct = 50
	elseif barDB.widthPct > 100 then
		barDB.widthPct = 100
	end
	if state.userPlaced then
		barDB.userPlaced = true
	end
	AJHDB.showJumpXPBar = barDB.shown

	if type(AJHDB.jumpXPBarLayouts) ~= "table" then
		AJHDB.jumpXPBarLayouts = {}
	end
	local layoutName = "Modern"
	if LibEditMode and LibEditMode.GetActiveLayoutName then
		layoutName = LibEditMode:GetActiveLayoutName() or layoutName
	end
	AJHDB.jumpXPBarLayouts[layoutName] = CopyJumpXPBarState(barDB)
	BackupProgress()
end

local function PersistJumpXPBarDraft()
	-- Always write the live draft into SavedVariables so /reload keeps it,
	-- even if the player leaves Edit Mode without clicking Save Changes.
	if jumpXPBarDraft then
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
	end
	CommitJumpXPBarState(jumpXPBarDraft)
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
	CommitJumpXPBarState(jumpXPBarDraft) -- write reverted values to SV too
	jumpXPBarEditDirty = false
	if jumpXPBar then
		ApplyJumpXPBarLayout(jumpXPBar, jumpXPBarDraft)
	end
	UpdateJumpXPBar()
end

local function EndJumpXPBarEditSession()
	-- Flush any pending draft so exit-without-Save still survives /reload.
	if jumpXPBarDraft then
		if jumpXPBarEditDirty then
			jumpXPBarDraft.shown = true
		end
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
		ui.jumpXPBarToggle:SetText("Hide Jump XP Bar")
	else
		ui.jumpXPBarToggle:SetText("Show Jump XP Bar")
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
	-- Always persist visibility immediately (Survives /reload).
	CommitJumpXPBarState(state)
	if jumpXPBarDraft then
		MarkJumpXPBarEditDirty()
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
		BeginJumpXPBarEditSession()
		UpdateJumpXPBar()
	end)

	LibEditMode:RegisterCallback("exit", function()
		EndJumpXPBarEditSession()
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

	ApplyJumpXPBarLayout(holder, GetJumpXPBarSaved())
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

local function StoreScore(key, name, jumps, achMask)
	EnsureDB()
	AJHDB.board[key] = {
		name = name or key,
		jumps = jumps,
		achMask = tonumber(achMask) or 0,
		updated = time(),
	}
end

BroadcastScore = function()
	if not IsInGuild() then
		return
	end
	EnsureDB()
	local key, name = PlayerIdentity()
	local mask = GetAchievementMask()
	StoreScore(key, name, AJHDB.jumps, mask)
	C_ChatInfo.SendAddonMessage(
		ADDON_PREFIX,
		string.format("S:%d:%d", AJHDB.jumps, mask),
		"GUILD"
	)
end

local function RequestGuildScores()
	if not IsInGuild() then
		return
	end
	BroadcastScore()
	C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "R", "GUILD")
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
	local key = PlayerIdentity()
	StoreScore(key, (select(2, PlayerIdentity())), AJHDB.jumps, GetAchievementMask())

	local entries = {}
	for entryKey, data in pairs(AJHDB.board) do
		if type(data) == "table" and type(data.jumps) == "number" then
			local achCount = CountAchievementsFromMask(data.achMask)
			if entryKey == key then
				achCount = CountOwnAchievements()
			end
			tinsert(entries, {
				key = entryKey,
				name = data.name or entryKey,
				jumps = data.jumps,
				level = GetLevel(data.jumps),
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
		elseif #entries == 0 then
			ui.guildEmpty:SetText("No scores yet. Open this tab while guildmates with AJH are online.")
			ui.guildEmpty:Show()
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

UpdateAchievements = function()
	EnsureDB()
	local child = ui.achChild
	if not child then
		return
	end

	local earned = 0
	for i, ach in ipairs(ACHIEVEMENTS) do
		local row = ui.achRows[i]
		if not row then
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
		end

		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ACH_ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", 0, -(i - 1) * ACH_ROW_HEIGHT)
		row:Show()

		local done = AJHDB.achievements[ach.id] ~= nil
		if done then
			earned = earned + 1
		end

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

	child:SetSize(300, #ACHIEVEMENTS * ACH_ROW_HEIGHT)
	if ui.achSummary then
		ui.achSummary:SetText(string.format("%d / %d achievements", earned, #ACHIEVEMENTS))
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

	-- Habit XP bar: profession skillbar chrome at its native height.
	local BAR_PAD = 22 -- horizontal inset from habit page (shrinks bar width)
	local barWrap = CreateFrame("Frame", nil, habit)
	barWrap:ClearAllPoints()
	barWrap:SetPoint("TOP", ui.level, "BOTTOM", 0, -14)
	barWrap:SetPoint("LEFT", habit, "LEFT", BAR_PAD, 0)
	barWrap:SetPoint("RIGHT", habit, "RIGHT", -BAR_PAD, 0)
	local chromeH = 22
	if C_Texture and C_Texture.GetAtlasInfo then
		local info = C_Texture.GetAtlasInfo("Professions-skillbar-frame")
		if info and info.height and info.height > 0 then
			chromeH = info.height
		end
	end
	barWrap:SetHeight(chromeH)
	ui.barWrap = barWrap

	-- No full-wrap black plate (it showed outside the chrome). Track lives on the StatusBar.
	ui.bar = CreateFrame("StatusBar", nil, barWrap)
	-- Match the default skillbar inner track (inside the native frame art).
	local fillH = math.max(8, chromeH - 17)
	ui.bar:SetHeight(fillH)
	ui.bar:SetPoint("LEFT", barWrap, "LEFT", 3, 2)
	ui.bar:SetPoint("RIGHT", barWrap, "RIGHT", -3, 2)
	ui.bar:SetMinMaxValues(0, 1)
	ui.bar:SetValue(0)
	ui.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	local fillTex = ui.bar:GetStatusBarTexture()
	if fillTex then
		fillTex:SetHorizTile(false)
		-- Blue body; gold tip is drawn separately at the lead.
		if fillTex.SetGradient and CreateColor then
			fillTex:SetGradient("HORIZONTAL", CreateColor(0.10, 0.28, 0.62, 1), CreateColor(0.28, 0.58, 0.98, 1))
		else
			ui.bar:SetStatusBarColor(0.20, 0.48, 0.90, 1)
		end
	else
		ui.bar:SetStatusBarColor(0.20, 0.48, 0.90, 1)
	end

	local track = ui.bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(0, 0, 0, 1)

	-- Soft top highlight like the profession fill sheen.
	local sheen = ui.bar:CreateTexture(nil, "OVERLAY", nil, 1)
	sheen:SetPoint("TOPLEFT", 0, 0)
	sheen:SetPoint("TOPRIGHT", 0, 0)
	sheen:SetHeight(math.min(5, fillH - 2))
	sheen:SetColorTexture(1, 1, 1, 0.14)

	-- Gold fade at the leading edge of the fill.
	ui.barSpark = ui.bar:CreateTexture(nil, "OVERLAY", nil, 2)
	ui.barSpark:SetTexture("Interface\\Buttons\\WHITE8X8")
	ui.barSpark:SetWidth(16)
	ui.barSpark:SetPoint("TOP", 0, 0)
	ui.barSpark:SetPoint("BOTTOM", 0, 0)
	if ui.barSpark.SetGradient and CreateColor then
		ui.barSpark:SetGradient("HORIZONTAL", CreateColor(0.20, 0.50, 0.95, 0), CreateColor(1.0, 0.84, 0.32, 1))
	else
		ui.barSpark:SetColorTexture(1.0, 0.84, 0.32, 0.9)
	end
	ui.barSpark:Hide()
	ui.bar:SetScript("OnValueChanged", function(self, value)
		local spark = ui.barSpark
		local minV, maxV = self:GetMinMaxValues()
		local width = self:GetWidth()
		if not spark or not width or width <= 0 or not maxV or maxV <= minV then
			if spark then spark:Hide() end
			return
		end
		local pct = (value - minV) / (maxV - minV)
		if pct <= 0.01 or pct >= 0.99 then
			spark:Hide()
			return
		end
		local tipW = math.min(16, width * pct * 0.45)
		spark:SetWidth(math.max(8, tipW))
		spark:ClearAllPoints()
		spark:SetPoint("TOPRIGHT", self, "TOPLEFT", width * pct, 0)
		spark:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT", width * pct, 0)
		spark:Show()
	end)

	local border = barWrap:CreateTexture(nil, "OVERLAY", nil, 7)
	-- useAtlasSize=false so chrome width follows barWrap (true locks native width).
	local borderOk = false
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("Professions-skillbar-frame") then
		borderOk = pcall(border.SetAtlas, border, "Professions-skillbar-frame", false)
	end
	if borderOk then
		border:ClearAllPoints()
		border:SetAllPoints(barWrap)
	else
		border:Hide()
		local function Edge(point, relativePoint, w, h, dx, dy)
			local t = barWrap:CreateTexture(nil, "OVERLAY", nil, 7)
			t:SetColorTexture(0.85, 0.70, 0.30, 1)
			if w then t:SetWidth(w) end
			if h then t:SetHeight(h) end
			t:SetPoint(point, barWrap, relativePoint or point, dx or 0, dy or 0)
			return t
		end
		Edge("TOPLEFT", "TOPLEFT", nil, 1, 0, 0):SetPoint("TOPRIGHT", barWrap, "TOPRIGHT", 0, 0)
		Edge("BOTTOMLEFT", "BOTTOMLEFT", nil, 1, 0, 0):SetPoint("BOTTOMRIGHT", barWrap, "BOTTOMRIGHT", 0, 0)
		Edge("TOPLEFT", "TOPLEFT", 1, nil, 0, 0):SetPoint("BOTTOMLEFT", barWrap, "BOTTOMLEFT", 0, 0)
		Edge("TOPRIGHT", "TOPRIGHT", 1, nil, 0, 0):SetPoint("BOTTOMRIGHT", barWrap, "BOTTOMRIGHT", 0, 0)
	end

	ui.UpdateHabitBarFill = nil -- StatusBar drives fill directly

	ui.barText = barWrap:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ui.barText:SetDrawLayer("OVERLAY", 7)
	ui.barText:SetTextColor(1, 1, 1)
	if ui.barText.SetShadowOffset then
		ui.barText:SetShadowOffset(1, -1)
		ui.barText:SetShadowColor(0, 0, 0, 1)
	end

	-- Keep label above border atlas, centered on the fill.
	local labelFrame = CreateFrame("Frame", nil, barWrap)
	labelFrame:SetAllPoints(ui.bar)
	labelFrame:SetFrameLevel(barWrap:GetFrameLevel() + 5)
	ui.barText:SetParent(labelFrame)
	ui.barText:SetPoint("CENTER", labelFrame, "CENTER", 0, 0)

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

	local announceSay = MakeAnnounceButton(habit, "Announce in /say")
	announceSay:SetPoint("BOTTOMLEFT", 12, 10)
	announceSay:SetPoint("BOTTOMRIGHT", habit, "BOTTOM", -4, 10)
	announceSay:SetScript("OnClick", function()
		AnnounceStatus("SAY")
	end)

	local announceGuild = MakeAnnounceButton(habit, "Announce in /g")
	announceGuild:SetPoint("BOTTOMLEFT", habit, "BOTTOM", 4, 10)
	announceGuild:SetPoint("BOTTOMRIGHT", -12, 10)
	announceGuild:SetScript("OnClick", function()
		if not IsInGuild() then
			DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88AJH:|r You are not in a guild.")
			return
		end
		AnnounceStatus("GUILD")
	end)

	ui.jumpXPBarToggle = MakeAnnounceButton(habit, "Show Jump XP Bar")
	ui.jumpXPBarToggle:SetPoint("BOTTOMLEFT", 12, 36)
	ui.jumpXPBarToggle:SetPoint("BOTTOMRIGHT", -12, 36)
	ui.jumpXPBarToggle:SetScript("OnClick", function()
		EnsureDB()
		local shown = GetJumpXPBarSaved().shown
		SetJumpXPBarShown(not shown)
	end)
	UpdateJumpXPBarToggleLabel()

	-- Levels page
	local levels = CreateFrame("Frame", nil, content)
	levels:SetAllPoints()
	levels:Hide()
	ui.pages.levels = levels
	local _, _, levelChild = CreateScrollArea(levels)
	ui.levelChild = levelChild
	BuildLevelRows(levelChild)

	-- Achievements page
	local achieves = CreateFrame("Frame", nil, content)
	achieves:SetAllPoints()
	achieves:Hide()
	ui.pages.achieves = achieves

	ui.achSummary = achieves:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.achSummary:SetPoint("TOPLEFT", 12, -16)

	local achWrap, _, achChild = CreateScrollArea(achieves)
	achWrap:SetPoint("TOPLEFT", 4, -40)
	achWrap:SetPoint("BOTTOMRIGHT", -4, 32)
	ui.achChild = achChild

	local resetAch = CreateFrame("Button", nil, achieves, "UIPanelButtonTemplate")
	resetAch:SetPoint("BOTTOMLEFT", 12, 6)
	resetAch:SetPoint("BOTTOMRIGHT", -12, 6)
	resetAch:SetHeight(22)
	resetAch:SetText("Reset feats (testing)")
	resetAch:SetScript("OnClick", function()
		ResetAchievements()
	end)

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
	boardHeaderAchs:SetText("ACH")

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

-- Global for Bindings.xml / Key Bindings UI.
function AJH_TogglePanel()
	TogglePanel()
end

local minimapButton
local minimapDragging = false

local function UpdateMinimapButtonPosition()
	if not minimapButton then
		return
	end
	EnsureDB()
	local angle = math.rad(AJHDB.minimapPos or 210)
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
	BackupProgress()
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
		EnsureDB()
		C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
		BuildPanel()
		BuildJumpXPBar()
		BuildMinimapButton()
		hooksecurefunc("JumpOrAscendStart", OnJump)
		RefreshCampBenefit()
	elseif event == "PLAYER_LOGIN" then
		EnsureDB()
		RestoreProgress()
		BackupProgress()
		RefreshCampBenefit()
		if panel then
			panel:Update()
		end
		UpdateJumpXPBar()
	elseif event == "PLAYER_LOGOUT" then
		BackupProgress()
	elseif event == "UNIT_AURA" then
		if RefreshCampBenefit() and panel and panel:IsShown() then
			panel:Update()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		RefreshCampBenefit()
		C_Timer.After(0, function()
			if RefreshCampBenefit() and panel and panel:IsShown() then
				panel:Update()
			end
			-- Status bars are laid out by now; re-apply saved Jump XP bar layout.
			if jumpXPBar then
				JUMP_XP_BAR_DEFAULT.y = DefaultJumpXPBarOffsetY()
				ApplyJumpXPBarLayout(jumpXPBar, GetJumpXPBarSaved())
			end
			UpdateJumpXPBar()
		end)
		C_Timer.After(3, BroadcastScore)
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...
		if prefix ~= ADDON_PREFIX or channel ~= "GUILD" then
			return
		end
		if message == "R" then
			if GetTime() - lastGuildReply > 2 then
				lastGuildReply = GetTime()
				BroadcastScore()
			end
		else
			local jumps, achMask = message:match("^S:(%d+):(%d+)$")
			if not jumps then
				jumps = message:match("^S:(%d+)$")
				achMask = 0
			end
			jumps = tonumber(jumps)
			achMask = tonumber(achMask) or 0
			if not jumps or not sender then
				return
			end
			local short = Ambiguate(sender, "short")
			StoreScore(sender, short, jumps, achMask)
			if panel and panel:IsShown() and activeTab == "guild" then
				UpdateLeaderboard()
			end
		end
	end
end)

SLASH_AJH1 = "/ajh"
SLASH_AJH2 = "/jumphabit"
SlashCmdList.AJH = function(msg)
	EnsureDB()
	msg = strtrim(msg or ""):lower()
	if msg == "clear" or msg == "reset" then
		AJHDB.jumps = 0
		AJHDB.xp = 0
		BackupProgress()
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
