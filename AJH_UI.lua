local ADDON_NAME, ns = ...
local S = ns.S
local C = ns.C
local ui = S.ui
ui.achRows = ui.achRows or {}
ui.featCatRows = ui.featCatRows or {}
local ROW_HEIGHT = ns.ROW_HEIGHT
local FROG_ICON = ns.FROG_ICON
local FEATS_ICON = ns.FEATS_ICON
local MAX_LEVEL = ns.MAX_LEVEL
local xpForLevel = ns.xpForLevel
local ACHIEVEMENTS = ns.ACHIEVEMENTS
local FEAT_CATEGORIES = ns.FEAT_CATEGORIES
local DEV_TOOLS = ns.DEV_TOOLS
local ADDON_PREFIX = ns.ADDON_PREFIX
local JUMP_XP_BAR_HEIGHT = ns.JUMP_XP_BAR_HEIGHT
local HABIT_PANEL_XP_BAR_HEIGHT = ns.HABIT_PANEL_XP_BAR_HEIGHT
local JUMP_ACTIVITY_SEC = ns.JUMP_ACTIVITY_SEC or 0.8
local XP_PER_JUMP = ns.XP_PER_JUMP or 1
local CAMP_XP_MULTIPLIER = ns.CAMP_XP_MULTIPLIER or 2

-- Locals used only inside UI builders (not shared).
local announceDialog
local jumpXPBar
local minimapButton
local minimapDragging

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
	if ns.CheckAchievementsGeneral() and S.panel and S.panel:IsShown() and S.activeTab == "achieves" then
		ns.UpdateAchievements()
	end
	return true
end


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
			jumpXPBar.text:SetText(string.format(
				"%s / MAX - 100%%",
				ns.FormatNumber(intoLevel)
			))
		end
	else
		intoLevel = xp - xpForLevel[level]
		needed = xpForLevel[level + 1] - xpForLevel[level]
		remaining = needed - intoLevel
		pct = needed > 0 and math.floor((intoLevel / needed) * 100 + 0.5) or 0
		jumpXPBar.bar:SetMinMaxValues(0, needed)
		jumpXPBar.bar:SetValue(intoLevel)
		if jumpXPBar.text then
			jumpXPBar.text:SetText(string.format(
				"%s / %s - %d%%",
				ns.FormatNumber(intoLevel),
				ns.FormatNumber(needed),
				pct
			))
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
	text:Hide()

	-- Gold frog on the left of the on-screen XP bar.
	local frogSize = math.max((JUMP_XP_BAR_HEIGHT or 11) + 6, 18)
	local frog = holder:CreateTexture(nil, "OVERLAY", nil, 7)
	frog:SetSize(frogSize, frogSize)
	frog:SetPoint("LEFT", holder, "LEFT", 1, 0)
	frog:SetTexture("Interface\\AddOns\\AJH\\AJH-gold-frog")
	if frog.SetTexCoord then
		frog:SetTexCoord(0.06, 0.94, 0.06, 0.94)
	end
	if frog.SetBlendMode then
		frog:SetBlendMode("BLEND")
	end
	holder.frog = frog
	frog:Hide()

	holder:SetScript("OnEnter", function(self)
		if self.text then
			self.text:Show()
		end
		if self.frog then
			self.frog:Show()
		end
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
	holder:SetScript("OnLeave", function(self)
		GameTooltip:Hide()
		if self.text then
			self.text:Hide()
		end
		if self.frog then
			self.frog:Hide()
		end
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

-- Guild notes live on ns.S (shared with slash /ajh sync in AJH.lua).

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
	local peers = ns.IterOnlineGuildNames()
	local whispered = 0
	local whisperFail = 0
	for i = 1, #peers do
		local wOk = ns.SendWhisperAddonMessage(message, peers[i])
		if wOk then
			whispered = whispered + 1
		else
			whisperFail = whisperFail + 1
		end
	end
	S.guildSendNote = string.format(
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
		S.guildSyncNote = "skip-not-in-guild"
		return
	end
	local db = ns.EnsureDB()
	if not db then
		S.guildSyncNote = "skip-no-db"
		return
	end
	local key, name = ns.PlayerIdentity()
	if not key then
		S.guildSyncNote = "skip-no-identity"
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
	local guildOk = ns.SendGuildAddonMessage(yMsg)
	ns.SendGuildAddonMessage(sMsg)
	ns.SendGuildAddonMessage(xMsg)
	local peers = ns.IterOnlineGuildNames()
	local whispered = 0
	local whisperFail = 0
	for i = 1, #peers do
		local target = peers[i]
		-- Always whisper Y (modern). Only fan out legacy S/X if guild send failed.
		if ns.SendWhisperAddonMessage(yMsg, target) then
			whispered = whispered + 1
		else
			whisperFail = whisperFail + 1
		end
		if not guildOk then
			ns.SendWhisperAddonMessage(sMsg, target)
			ns.SendWhisperAddonMessage(xMsg, target)
		end
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
	S.guildSendNote = string.format("whispered=%d fail=%d onlinePeers=%d guildOk=%s", whispered, whisperFail, #peers, tostring(guildOk))
	S.guildSyncNote = "broadcast " .. S.guildSendNote
end

function ns.RequestGuildScores()
	if not IsInGuild() then
		S.guildSyncNote = "request-not-in-guild"
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
	S.guildSyncNote = string.format("request whisperedR=%d %s", asked, S.guildSendNote)
end

function ns.CreateStatRow(parent, anchor, y)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", anchor, "TOPLEFT", 16, y)

	local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	value:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -16, y)

	return label, value
end

-- Prefer Forever/Blizzard character-sheet category header art when available.
-- Do NOT Show/Expand CharacterFrame or call PaperDollFrame_UpdateStats from here —
-- that taints Camelot secret-value paths in UpdateStats.
local function EnsureCharacterCategoryArtLoaded()
	pcall(function()
		if C_AddOns and C_AddOns.LoadAddOn then
			C_AddOns.LoadAddOn("Blizzard_CharacterUI")
			C_AddOns.LoadAddOn("Blizzard_UIPanels_Game")
			C_AddOns.LoadAddOn("Blizzard_CharacterFrame")
		elseif LoadAddOn then
			LoadAddOn("Blizzard_CharacterUI")
			LoadAddOn("Blizzard_CharacterFrame")
		end
	end)
end

local CATEGORY_TEMPLATES = {
	"CharacterStatFrameCategoryTemplate",
	"StatCategoryTemplate",
	"CharacterFrameCategoryTemplate",
}

local CATEGORY_ATLAS_SETS = {
	{ "UI-Character-Info-Categories-Left", "_UI-Character-Info-Categories-Tile", "UI-Character-Info-Categories-Right" },
	{ "characterinfo-categories-left", "_characterinfo-categories-tile", "characterinfo-categories-right" },
	{ "UI-Frame-DiamondMetal-Header-CornerLeft", "_UI-Frame-DiamondMetal-Header-Tile", "UI-Frame-DiamondMetal-Header-CornerRight" },
}

local function FindLiveStatCategoryFrame()
	for i = 1, 10 do
		local f = _G["CharacterStatsPaneCategory" .. i]
			or _G["CharacterStatsPaneCategoryFrame" .. i]
			or _G["PaperDollFrameStatCategory" .. i]
			or _G["StatCategoryFrame" .. i]
		if f then
			return f
		end
	end
	local function walk(frame, depth)
		if not frame or depth > 7 then
			return nil
		end
		if frame.Category or frame.Toolbar or frame.TitleBg then
			return frame
		end
		local nameText = frame.NameText or frame.TitleText
		if nameText and nameText.GetText then
			local t = nameText:GetText()
			if t == "General" or t == "Primary Attributes" or t == GENERAL then
				return frame
			end
		end
		if frame.GetChildren then
			local kids = { frame:GetChildren() }
			for i = 1, #kids do
				local found = walk(kids[i], depth + 1)
				if found then
					return found
				end
			end
		end
		return nil
	end
	return walk(_G.CharacterStatsPane, 0)
		or walk(_G.PaperDollFrame, 0)
		or walk(_G.CharacterFrame, 0)
end

local function GetCategoryTitleHeight(src)
	local base = 28
	if src then
		local candidates = {
			src.Toolbar,
			src.TitleBg,
			src.Background,
			src.Left,
			src.Toolbar and src.Toolbar.Left,
			src.Toolbar and src.Toolbar.Middle,
		}
		for i = 1, #candidates do
			local c = candidates[i]
			if c and c.GetHeight then
				local h = c:GetHeight()
				if h and h >= 18 and h <= 40 then
					base = math.floor(h + 0.5)
					break
				end
			end
		end
	end
	return base + 15
end

local function GetCategoryArtSource(src)
	if not src then
		return nil
	end
	-- Title chrome often lives on a Toolbar / header child, not the full category.
	if src.Toolbar and (src.Toolbar.Left or src.Toolbar.Middle) then
		return src.Toolbar
	end
	if src.Header and (src.Header.Left or src.Header.Middle) then
		return src.Header
	end
	return src
end

local function CloneTextureOnto(dest, src)
	if not dest or not src then
		return false
	end
	local atlas = src.GetAtlas and src:GetAtlas()
	if atlas and atlas ~= "" then
		return ns.TrySetAtlas(dest, atlas, false)
	end
	local path = src.GetTexture and src:GetTexture()
	if path then
		dest:SetTexture(path)
		if src.GetTexCoord then
			local l, r, t, b = src:GetTexCoord()
			if l then
				dest:SetTexCoord(l, r, t, b)
			end
		end
		if src.GetVertexColor then
			local cr, cg, cb, ca = src:GetVertexColor()
			if cr then
				dest:SetVertexColor(cr, cg, cb, ca or 1)
			end
		end
		return true
	end
	return false
end

local function ApplyLiveCategoryArt(left, mid, right, src)
	src = GetCategoryArtSource(src)
	if not src then
		return false
	end
	local L = src.Left or src.LeftEdge or src.BgLeft
	local M = src.Middle or src.Center or src.BgMiddle
	local R = src.Right or src.RightEdge or src.BgRight
	if L and M and R then
		return CloneTextureOnto(left, L) and CloneTextureOnto(mid, M) and CloneTextureOnto(right, R)
	end
	-- Fallback: first three shown textures on the source.
	local regions = { src:GetRegions() }
	local textures = {}
	for i = 1, #regions do
		local r = regions[i]
		if r and r.GetObjectType and r:GetObjectType() == "Texture" and r:IsShown() then
			textures[#textures + 1] = r
		end
	end
	if #textures >= 3 then
		return CloneTextureOnto(left, textures[1])
			and CloneTextureOnto(mid, textures[2])
			and CloneTextureOnto(right, textures[3])
	end
	return false
end

local function ApplyLabelFrameArt(left, mid, right)
	local path = "Interface\\Glues\\CharacterCreate\\CharacterCreate-LabelFrame"
	left:SetTexture(path)
	left:SetTexCoord(0, 0.1953125, 0, 1)
	mid:SetTexture(path)
	mid:SetTexCoord(0.1953125, 0.8046875, 0, 1)
	right:SetTexture(path)
	right:SetTexCoord(0.8046875, 1, 0, 1)
	return true
end

local function StyleHeaderLabel(fs, text, live)
	if not fs or not fs.SetText then
		return
	end
	fs:SetText(text or "")
	local srcText = live and (live.NameText or live.TitleText or live.Text or live.Label)
	if srcText and srcText.GetTextColor then
		local r, g, b, a = srcText:GetTextColor()
		if r then
			fs:SetTextColor(r, g, b, a or 1)
			return
		end
	end
	-- Character sheet titles are near-white.
	fs:SetTextColor(0.98, 0.96, 0.90)
end

-- Same assets as Forever character-sheet category headings (General, etc.).
-- Never paint fake gold rails — those never look right next to the real art.
function ns.CreateSectionHeader(parent, text)
	EnsureCharacterCategoryArtLoaded()
	local live = FindLiveStatCategoryFrame()
	local HEADER_H = GetCategoryTitleHeight(live)

	-- 1) Exact Blizzard/Forever category template when available.
	for i = 1, #CATEGORY_TEMPLATES do
		local ok, btn = pcall(CreateFrame, "Button", nil, parent, CATEGORY_TEMPLATES[i])
		if ok and btn then
			btn:EnableMouse(false)
			btn:SetHeight(HEADER_H)
			if btn.Toolbar and btn.Toolbar.Hide then
				-- Keep toolbar textures visible; only kill the collapse control.
				local collapse = btn.Toolbar.CollapseButton or btn.Toolbar.Button or btn.CollapseButton
				if collapse and collapse.Hide then
					collapse:Hide()
					collapse:EnableMouse(false)
				end
			elseif btn.CollapseButton then
				btn.CollapseButton:Hide()
				btn.CollapseButton:EnableMouse(false)
			end
			if btn.SetText then
				btn:SetText(text or "")
			end
			local fs = btn.Text or btn.Label or btn.Title or btn.NameText
				or (btn.GetFontString and btn:GetFontString())
			StyleHeaderLabel(fs, text, live)
			btn.label = fs
			return btn
		end
	end

	-- 2) Build left/mid/right from live category art or known atlases.
	local h = CreateFrame("Frame", nil, parent)
	h:SetHeight(HEADER_H)

	local left = h:CreateTexture(nil, "BACKGROUND")
	left:SetSize(math.floor(HEADER_H * 0.7), HEADER_H)
	left:SetPoint("LEFT", 0, 0)
	local right = h:CreateTexture(nil, "BACKGROUND")
	right:SetSize(math.floor(HEADER_H * 0.7), HEADER_H)
	right:SetPoint("RIGHT", 0, 0)
	local mid = h:CreateTexture(nil, "BACKGROUND")
	mid:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
	mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)

	local artOk = ApplyLiveCategoryArt(left, mid, right, live)
	if not artOk then
		for _, set in ipairs(CATEGORY_ATLAS_SETS) do
			if ns.TrySetAtlas(left, set[1], false)
				and ns.TrySetAtlas(mid, set[2], false)
				and ns.TrySetAtlas(right, set[3], false)
			then
				if mid.SetHorizTile then
					mid:SetHorizTile(true)
				end
				artOk = true
				break
			end
		end
	end
	if not artOk then
		artOk = ApplyLabelFrameArt(left, mid, right)
	end
	if not artOk then
		left:SetColorTexture(0.16, 0.12, 0.08, 0.98)
		mid:SetColorTexture(0.16, 0.12, 0.08, 0.98)
		right:SetColorTexture(0.16, 0.12, 0.08, 0.98)
	end

	local label = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("CENTER", 0, 0)
	StyleHeaderLabel(label, text, live)
	if label.SetShadowOffset then
		label:SetShadowOffset(1, -1)
		label:SetShadowColor(0, 0, 0, 0.9)
	end
	h.label = label
	h._ajhLeft, h._ajhMid, h._ajhRight = left, mid, right

	-- If CharacterFrame wasn't ready at build time, re-bind real art on first show.
	if not live then
		h:SetScript("OnShow", function(self)
			if self._ajhArtBound then
				return
			end
			EnsureCharacterCategoryArtLoaded()
			local src = FindLiveStatCategoryFrame()
			if src and ApplyLiveCategoryArt(self._ajhLeft, self._ajhMid, self._ajhRight, src) then
				self:SetHeight(GetCategoryTitleHeight(src))
				StyleHeaderLabel(self.label, text, src)
				self._ajhArtBound = true
			end
		end)
	end
	return h
end

-- Stat row with character-sheet zebra striping (odd dark / even mid-brown).
function ns.CreateModernStatRow(parent, relativeTo, yOff, labelText, stripeIndex)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(22)
	if relativeTo then
		row:SetPoint("TOPLEFT", relativeTo, "BOTTOMLEFT", 0, yOff or -1)
		row:SetPoint("TOPRIGHT", relativeTo, "BOTTOMRIGHT", 0, yOff or -1)
	end
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	local odd = ((stripeIndex or 1) % 2) == 1
	if odd then
		row.bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
	else
		row.bg:SetColorTexture(0.17, 0.13, 0.09, 0.88)
	end

	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.label:SetPoint("LEFT", 10, 0)
	row.label:SetText(labelText or "")
	row.label:SetTextColor(1, 0.82, 0)

	row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.value:SetPoint("RIGHT", -10, 0)
	row.value:SetTextColor(0.95, 0.95, 0.92)
	return row
end

local function HideNineSlice(nine)
	if not nine then
		return
	end
	for _, key in ipairs({
		"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
		"TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Center",
	}) do
		local piece = nine[key]
		if piece and piece.Hide then
			piece:Hide()
		end
	end
end

local function TintNineSlice(nine, r, g, b)
	if not nine then
		return
	end
	for _, key in ipairs({
		"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
		"TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
	}) do
		local piece = nine[key]
		if piece and piece.SetVertexColor then
			piece:SetVertexColor(r, g, b)
		end
	end
end

-- Light chrome only: keep Blizzard ButtonFrame title/border colours untouched.
-- Do NOT call ButtonFrameTemplate_HidePortrait (blanks CloseButton on Forever).
function ns.ApplyModernPanelChrome(frame)
	if not frame then
		return
	end

	local function KillChromeStrips()
		if ButtonFrameTemplate_HideAttic then
			pcall(ButtonFrameTemplate_HideAttic, frame)
		end
		if ButtonFrameTemplate_HideButtonBar then
			pcall(ButtonFrameTemplate_HideButtonBar, frame)
		end
		for _, key in ipairs({
			"TopTileStreaks", "TitleBg", "TopBorder", "Attic", "BgTop", "Top",
			"BottomTileStreaks", "BtnBarTop", "BtnBarBottom", "ButtonBar",
			"BottomBorder", "BgBottom", "Bottom",
		}) do
			local piece = frame[key]
			if piece and piece.Hide then
				piece:Hide()
			end
		end
	end
	KillChromeStrips()
	if not frame._ajhAtticHooked then
		frame._ajhAtticHooked = true
		frame:HookScript("OnShow", KillChromeStrips)
	end

	local flatR, flatG, flatB = 0.06, 0.055, 0.05

	-- Flat dark plate over the title→inset gap.
	local cover = frame._ajhAtticCover
	if not cover then
		cover = frame:CreateTexture(nil, "ARTWORK", nil, 7)
		frame._ajhAtticCover = cover
	end
	cover:SetTexture("Interface\\Buttons\\WHITE8X8")
	cover:SetVertexColor(flatR, flatG, flatB, 1)
	cover:ClearAllPoints()
	cover:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -20)
	cover:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -20)
	if frame.Inset then
		cover:SetPoint("BOTTOMLEFT", frame.Inset, "TOPLEFT", 0, 0)
		cover:SetPoint("BOTTOMRIGHT", frame.Inset, "TOPRIGHT", 0, 0)
	else
		cover:SetHeight(48)
	end
	cover:Show()

	-- Same treatment for the bottom button-bar grey strip.
	local bottomCover = frame._ajhBottomCover
	if not bottomCover then
		bottomCover = frame:CreateTexture(nil, "ARTWORK", nil, 7)
		frame._ajhBottomCover = bottomCover
	end
	bottomCover:SetTexture("Interface\\Buttons\\WHITE8X8")
	bottomCover:SetVertexColor(flatR, flatG, flatB, 1)
	bottomCover:ClearAllPoints()
	bottomCover:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 3, 3)
	bottomCover:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
	if frame.Inset then
		bottomCover:SetPoint("TOPLEFT", frame.Inset, "BOTTOMLEFT", 0, 0)
		bottomCover:SetPoint("TOPRIGHT", frame.Inset, "BOTTOMRIGHT", 0, 0)
	else
		bottomCover:SetHeight(28)
	end
	bottomCover:Show()

	if frame.Inset then
		-- Drop the inner "window" border so content sits flush like CharacterFrame.
		HideNineSlice(frame.Inset.NineSlice)
		-- Replace the default stone rock inset fill with a flat colour.
		if frame.Inset.Bg then
			local bg = frame.Inset.Bg
			bg:Show()
			if bg.SetHorizTile then
				bg:SetHorizTile(false)
				bg:SetVertTile(false)
			end
			bg:SetTexture("Interface\\Buttons\\WHITE8X8")
			bg:SetVertexColor(0.06, 0.055, 0.05, 1)
		end
	end
	-- Raise CloseButton above NineSlice so the X isn't covered by the gold corner.
	if frame.CloseButton then
		local cb = frame.CloseButton
		local nsLevel = frame.NineSlice and frame.NineSlice.GetFrameLevel and frame.NineSlice:GetFrameLevel()
		local base = math.max(frame:GetFrameLevel(), nsLevel or 0)
		cb:SetFrameLevel(base + 10)
		cb:EnableMouse(true)
		cb:Show()
	end

	-- Vertically centre the title in the header bar (stock layout sits a hair high).
	-- Leave room on the right for the settings cog + close button.
	local titleContainer = frame.TitleContainer
	local title = (titleContainer and titleContainer.TitleText) or frame.TitleText
	if titleContainer then
		titleContainer:ClearAllPoints()
		titleContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 60, 0)
		titleContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -54, 0)
		titleContainer:SetHeight(22)
	end
	if title then
		title:ClearAllPoints()
		if titleContainer then
			title:SetPoint("CENTER", titleContainer, "CENTER", 0, 0)
		else
			title:SetPoint("TOP", frame, "TOP", 0, -5)
		end
		title:SetJustifyV("MIDDLE")
	end
end

-- Flat page fill so no stone rock shows through scroll children / content frames.
function ns.ApplyContentFill(frame)
	if not frame then
		return
	end
	local fill = frame._ajhContentFillTex
	if not fill then
		fill = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
		fill:SetAllPoints()
		frame._ajhContentFillTex = fill
	end
	fill:Show()
	if fill.SetHorizTile then
		fill:SetHorizTile(false)
		fill:SetVertTile(false)
	end
	fill:SetTexture("Interface\\Buttons\\WHITE8X8")
	fill:SetVertexColor(0.06, 0.055, 0.05, 1)
	frame._ajhContentFill = true
end

-- Modern Forever scroll area: thin MinimalScrollBar (character-panel style),
-- not WowTrimScrollBar / UIPanelScrollFrameTemplate (thick silver chrome).
-- opts.overlayBar (default true): bar draws over content (feat cards).
-- opts.overlayBar = false: content ends left of the bar (tables / section headers).
function ns.CreateScrollArea(parent, opts)
	opts = opts or {}
	local overlayBar = opts.overlayBar
	if overlayBar == nil then
		overlayBar = true
	end

	local wrap = CreateFrame("Frame", nil, parent)
	wrap:SetPoint("TOPLEFT", 4, -4)
	wrap:SetPoint("BOTTOMRIGHT", -4, 4)

	local scrollBar
	do
		-- Prefer the slim character-sidebar bar first.
		local templates = {
			"MinimalScrollBar",
			"WowMinimalScrollBar",
			"UIPanelScrollBarMinimalTemplate",
		}
		for i = 1, #templates do
			local ok, bar = pcall(CreateFrame, "EventFrame", nil, wrap, templates[i])
			if not (ok and bar) then
				ok, bar = pcall(CreateFrame, "Frame", nil, wrap, templates[i])
			end
			if ok and bar then
				scrollBar = bar
				break
			end
		end
		if scrollBar then
			if scrollBar.SetHideIfUnscrollable then
				scrollBar:SetHideIfUnscrollable(true)
			end
			if scrollBar.SetWidth then
				local w = scrollBar:GetWidth()
				if not w or w > 14 then
					scrollBar:SetWidth(10)
				end
			end
		end
	end

	local scroll
	do
		local ok, sf = pcall(CreateFrame, "ScrollFrame", nil, wrap, "ScrollFrameTemplate")
		if ok and sf then
			scroll = sf
		else
			scroll = CreateFrame("ScrollFrame", nil, wrap, "UIPanelScrollFrameTemplate")
		end
	end

	-- ScrollFrameTemplate may ship its own bar/steppers — hide those so we only
	-- keep the single MinimalScrollBar (avoids the double down-arrow look).
	local function HideBuiltinScrollChrome(sf)
		if not sf then
			return
		end
		local builtin = sf.ScrollBar or sf.scrollBar
		if builtin and builtin ~= scrollBar then
			builtin:Hide()
			builtin:EnableMouse(false)
			if builtin.ClearAllPoints then
				builtin:ClearAllPoints()
			end
			if builtin.SetAlpha then
				builtin:SetAlpha(0)
			end
			for _, key in ipairs({
				"ScrollUpButton", "ScrollDownButton", "Back", "Forward",
				"ThumbTexture", "Track",
			}) do
				local piece = builtin[key]
				if piece and piece.Hide then
					piece:Hide()
				end
			end
		end
		local name = sf.GetName and sf:GetName()
		if name then
			for _, suffix in ipairs({ "ScrollBar", "ScrollBarScrollUpButton", "ScrollBarScrollDownButton" }) do
				local f = _G[name .. suffix]
				if f and f ~= scrollBar and f.Hide then
					f:Hide()
					if f.EnableMouse then
						f:EnableMouse(false)
					end
				end
			end
		end
	end
	HideBuiltinScrollChrome(scroll)

	local function AnchorScrollAndBar()
		if not scrollBar then
			scroll:SetPoint("TOPLEFT", 2, -2)
			scroll:SetPoint("BOTTOMRIGHT", -2, 2)
			return
		end
		scrollBar:ClearAllPoints()
		scroll:ClearAllPoints()
		if overlayBar then
			scroll:SetPoint("TOPLEFT", wrap, "TOPLEFT", 2, -2)
			scroll:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -2, 2)
			scrollBar:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -2, -4)
			scrollBar:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -2, 4)
		else
			scrollBar:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -2, -4)
			scrollBar:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -2, 4)
			scroll:SetPoint("TOPLEFT", wrap, "TOPLEFT", 2, -2)
			scroll:SetPoint("BOTTOMLEFT", wrap, "BOTTOMLEFT", 2, 2)
			scroll:SetPoint("RIGHT", scrollBar, "LEFT", -4, 0)
		end
	end
	AnchorScrollAndBar()

	if scrollBar then
		local wired = false
		if ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar then
			wired = pcall(ScrollUtil.InitScrollFrameWithScrollBar, scroll, scrollBar)
		end
		if not wired and scrollBar.Init then
			wired = pcall(scrollBar.Init, scrollBar, scroll)
		end
		-- Init can re-anchor; restore our layout.
		AnchorScrollAndBar()
		HideBuiltinScrollChrome(scroll)

		if not wired then
			scroll.ScrollBar = scrollBar
			scroll:SetScript("OnScrollRangeChanged", function(self, _x, yrange)
				yrange = yrange or 0
				if scrollBar.Update then
					pcall(scrollBar.Update, scrollBar)
				elseif scrollBar.SetMinMaxValues then
					scrollBar:SetMinMaxValues(0, yrange)
					local val = self:GetVerticalScroll() or 0
					scrollBar:SetValue(math.min(val, yrange))
				end
				if scrollBar.SetShown and scrollBar.SetHideIfUnscrollable then
					scrollBar:SetShown(yrange > 1)
				end
			end)
			scroll:SetScript("OnVerticalScroll", function(self, offset)
				if scrollBar.SetValue then
					scrollBar:SetValue(offset or 0)
				end
			end)
			scroll:EnableMouseWheel(true)
			scroll:SetScript("OnMouseWheel", function(self, delta)
				local cur = self:GetVerticalScroll() or 0
				local maxV = self:GetVerticalScrollRange() or 0
				local step = 40
				self:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * step)))
			end)
		end
	end

	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)

	scroll:HookScript("OnSizeChanged", function(self, width)
		local w = width or self:GetWidth() or 0
		if w > 0 then
			child:SetWidth(w)
		end
	end)

	wrap.scrollBar = scrollBar
	wrap.scroll = scroll
	wrap.child = child
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

-- Shared section / table chrome insets (Stats, Levels, Guild).
local SECTION_INSET = 10
local SECTION_TOP = -6
local SECTION_BELOW = -6
local COL_HEADER_H = 22

function ns.ScrollLevelsToCurrent(level)
	local scroll = ui.levelScroll
	local child = ui.levelChild
	if not scroll or not child or not level then
		return
	end
	local sectionH = (ui.levelsSectionHeader and ui.levelsSectionHeader:GetHeight()) or 28
	local colH = (ui.levelColHeader and ui.levelColHeader:GetHeight()) or COL_HEADER_H
	local firstRowTop = math.abs(SECTION_TOP) + sectionH + math.abs(SECTION_BELOW) + colH
	local rowTop = firstRowTop + (level - 1) * ROW_HEIGHT
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
	if S.activeTab == "settings" then
		btn.icon:SetVertexColor(1, 0.82, 0)
	else
		btn.icon:SetVertexColor(0.9, 0.9, 0.9)
	end
end

function ns.SetTab(id, silent)
	local changed = S.activeTab ~= id
	S.activeTab = id
	for tabId, page in pairs(ui.pages) do
		page:SetShown(tabId == id)
	end
	if S.panel and ui.tabButtons then
		if id == "settings" then
			-- Settings is a separate gear button, not a PanelTemplates tab.
			for _, tab in ipairs(ui.tabButtons) do
				if PanelTemplates_DeselectTab then
					PanelTemplates_DeselectTab(tab)
				end
			end
			S.panel.selectedTab = 0
		elseif ui.tabIndex and ui.tabIndex[id] then
			PanelTemplates_SetTab(S.panel, ui.tabIndex[id])
		end
	end
	ns.UpdateSettingsButton()
	if id == "stats" then
		ns.ShowStatsView("main")
	end
	if id == "guild" then
		ns.RequestGuildScores()
	end
	if S.panel then
		S.panel:Update()
	end
	if not silent and changed then
		ns.PlayUISound("IG_CHARACTER_INFO_TAB", 841)
	end
end

local LEVEL_COL = {
	pad = SECTION_INSET,
	level = 48,
	diff = 90,
}

local function LayoutLevelColumns(row)
	if not row then
		return
	end
	local pad = LEVEL_COL.pad
	if row.level then
		row.level:ClearAllPoints()
		row.level:SetPoint("LEFT", pad, 0)
		row.level:SetWidth(LEVEL_COL.level)
		row.level:SetJustifyH("LEFT")
	end
	if row.xp then
		row.xp:ClearAllPoints()
		row.xp:SetPoint("RIGHT", -pad, 0)
		row.xp:SetJustifyH("RIGHT")
	end
	if row.diff then
		row.diff:ClearAllPoints()
		row.diff:SetPoint("RIGHT", row.xp, "LEFT", -12, 0)
		row.diff:SetWidth(LEVEL_COL.diff)
		row.diff:SetJustifyH("RIGHT")
	end
end

function ns.BuildLevelRows(parent)
	-- Section header IN the scroll child (same pattern as Stats "This Session").
	local section = ns.CreateSectionHeader(parent, "Levels")
	section:SetPoint("TOPLEFT", SECTION_INSET, SECTION_TOP)
	section:SetPoint("TOPRIGHT", -SECTION_INSET, SECTION_TOP)
	ui.levelsSectionHeader = section

	local sectionH = section:GetHeight() or 28
	local colY = SECTION_TOP - sectionH + SECTION_BELOW

	local colHeader = CreateFrame("Frame", nil, parent)
	colHeader:SetHeight(COL_HEADER_H)
	colHeader:SetPoint("TOPLEFT", 0, colY)
	colHeader:SetPoint("TOPRIGHT", 0, colY)
	colHeader.bg = colHeader:CreateTexture(nil, "BACKGROUND")
	colHeader.bg:SetAllPoints()
	colHeader.bg:SetColorTexture(0.12, 0.10, 0.07, 0.95)
	colHeader.level = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.level:SetText("Level")
	colHeader.level:SetTextColor(1, 0.82, 0)
	colHeader.diff = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.diff:SetText("To reach")
	colHeader.diff:SetTextColor(1, 0.82, 0)
	colHeader.xp = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.xp:SetText("Total XP")
	colHeader.xp:SetTextColor(1, 0.82, 0)
	LayoutLevelColumns(colHeader)
	ui.levelColHeader = colHeader

	local firstRowY = colY - COL_HEADER_H
	for level = 1, MAX_LEVEL do
		local row = CreateFrame("Frame", nil, parent)
		local y = firstRowY - (level - 1) * ROW_HEIGHT
		row:SetPoint("TOPLEFT", 0, y)
		row:SetPoint("TOPRIGHT", 0, y)
		row:SetHeight(ROW_HEIGHT)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		local odd = (level % 2) == 1
		if odd then
			row.bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
		else
			row.bg:SetColorTexture(0.17, 0.13, 0.09, 0.88)
		end
		row._ajhOdd = odd

		row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.level:SetText(tostring(level))

		row.xp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.xp:SetText(ns.FormatNumber(xpForLevel[level]))

		row.diff = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		if level == 1 then
			row.diff:SetText("—")
		else
			row.diff:SetText("+" .. ns.FormatNumber(xpForLevel[level] - xpForLevel[level - 1]))
		end
		LayoutLevelColumns(row)

		ui.levelRows[level] = row
	end

	parent:SetHeight(math.abs(firstRowY) + MAX_LEVEL * ROW_HEIGHT + 8)
end

function ns.UpdateLevelRows(currentLevel)
	for level, row in pairs(ui.levelRows) do
		if level == currentLevel then
			row.bg:SetColorTexture(0.28, 0.22, 0.08, 0.95)
			row.bg:Show()
			row.level:SetTextColor(1, 0.82, 0, 1)
			row.xp:SetTextColor(1, 0.82, 0, 1)
			row.diff:SetTextColor(1, 0.82, 0, 1)
		else
			if row._ajhOdd then
				row.bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
			else
				row.bg:SetColorTexture(0.17, 0.13, 0.09, 0.88)
			end
			row.bg:Show()
			row.level:SetTextColor(0.95, 0.95, 0.92, 1)
			row.xp:SetTextColor(0.95, 0.95, 0.92, 1)
			row.diff:SetTextColor(0.75, 0.72, 0.65, 1)
		end
	end
end

-- Guild leaderboard column geometry (shared by header + rows).
local BOARD_COL = {
	pad = SECTION_INSET,
	rank = 28,
	level = 40,
	jumps = 56,
	feats = 72,
}

local function LayoutBoardColumns(row)
	if not row then
		return
	end
	local pad = BOARD_COL.pad
	if row.rank then
		row.rank:ClearAllPoints()
		row.rank:SetPoint("LEFT", pad, 0)
		row.rank:SetWidth(BOARD_COL.rank)
		row.rank:SetJustifyH("CENTER")
	end
	if row.achs then
		row.achs:ClearAllPoints()
		row.achs:SetPoint("RIGHT", -pad, 0)
		row.achs:SetWidth(BOARD_COL.feats)
		row.achs:SetJustifyH("RIGHT")
	end
	if row.jumps then
		row.jumps:ClearAllPoints()
		row.jumps:SetPoint("RIGHT", row.achs, "LEFT", -8, 0)
		row.jumps:SetWidth(BOARD_COL.jumps)
		row.jumps:SetJustifyH("RIGHT")
	end
	if row.level then
		row.level:ClearAllPoints()
		row.level:SetPoint("RIGHT", row.jumps, "LEFT", -8, 0)
		row.level:SetWidth(BOARD_COL.level)
		row.level:SetJustifyH("RIGHT")
	end
	if row.name then
		row.name:ClearAllPoints()
		row.name:SetPoint("LEFT", row.rank, "RIGHT", 8, 0)
		row.name:SetPoint("RIGHT", row.level, "LEFT", -8, 0)
		row.name:SetJustifyH("LEFT")
	end
end

function ns.EnsureBoardRow(parent, index)
	local row = ui.boardRows[index]
	if row then
		return row
	end

	row = CreateFrame("Frame", nil, parent)
	row:SetHeight(22)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	local odd = (index % 2) == 1
	if odd then
		row.bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
	else
		row.bg:SetColorTexture(0.17, 0.13, 0.09, 0.88)
	end

	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.jumps = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.achs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	LayoutBoardColumns(row)

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

	-- Hint under the section header — never overlay the table.
	if ui.guildHint then
		if not IsInGuild() then
			ui.guildHint:SetText("Join a guild to share Jump Habit scores with others.")
			ui.guildHint:Show()
		elseif #entries <= 1 then
			ui.guildHint:SetText("Waiting for guildmates with AJH — open this tab while they are online.")
			ui.guildHint:Show()
		else
			ui.guildHint:Hide()
		end
	end
	if ui.guildEmpty then
		ui.guildEmpty:Hide()
	end
	if ui.LayoutGuildScroll then
		ui.LayoutGuildScroll()
	end

	local child = ui.boardChild
	if not child then
		return
	end

	local scroll = ui.boardScroll
	local contentW = (scroll and scroll:GetWidth()) or child:GetWidth() or 0
	if contentW > 80 then
		child:SetWidth(contentW)
	end

	local headerH = (ui.boardColHeader and ui.boardColHeader:GetHeight()) or COL_HEADER_H
	local y = -headerH

	for i, entry in ipairs(entries) do
		local row = ns.EnsureBoardRow(child, i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, y - (i - 1) * 22)
		row:SetPoint("TOPRIGHT", 0, y - (i - 1) * 22)
		row:Show()
		LayoutBoardColumns(row)

		row.rank:SetText(tostring(i))
		row.name:SetText(entry.name)
		row.level:SetText(tostring(entry.level))
		row.jumps:SetText(ns.FormatNumber(entry.jumps))
		row.achs:SetText(string.format("%d / %d", entry.achs, #ACHIEVEMENTS))

		local mine = entry.key == key
		local gold = mine and 1 or 0.95
		local g2 = mine and 0.82 or 0.95
		local g3 = mine and 0 or 0.92
		row.rank:SetTextColor(gold, g2, g3, 1)
		row.name:SetTextColor(gold, g2, g3, 1)
		row.level:SetTextColor(gold, g2, g3, 1)
		row.jumps:SetTextColor(gold, g2, g3, 1)
		row.achs:SetTextColor(gold, g2, g3, 1)
	end

	for i = #entries + 1, #ui.boardRows do
		ui.boardRows[i]:Hide()
	end

	child:SetHeight(headerH + math.max(#entries, 1) * 22 + 8)
	if scroll and scroll.UpdateScrollChildRect then
		scroll:UpdateScrollChildRect()
	end
end

local ACH_ROW_HEIGHT = 36
local FEAT_CAT_COLS = 2
local FEAT_CAT_CARD_HEIGHT = 138
local FEAT_CAT_CARD_GAP = 4
local FEAT_CAT_PAD = 2
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
	if type(rows) ~= "table" then
		return
	end
	for _, row in pairs(rows) do
		row:Hide()
	end
end

function ns.StyleFeatItemRow(row, ach, done, stripeIndex)
	row.featId = ach and ach.id or nil
	row.title:SetText(ach.name)
	row.desc:SetText(ach.desc)
	local odd = ((stripeIndex or 1) % 2) == 1
	local tracked = (not done) and ach and ns.IsFeatTracked(ach.id)
	if done then
		row.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
		row.bg:SetColorTexture(0.28, 0.22, 0.08, 0.95)
		row.title:SetTextColor(1, 0.82, 0, 1)
		row.desc:SetTextColor(0.95, 0.90, 0.75, 1)
	else
		if tracked then
			-- Same frog as the objective tracker — not a checkmark (that reads as "done").
			row.icon:SetTexture("Interface\\AddOns\\AJH\\AJH-gold-frog")
			if row.icon.SetTexCoord then
				row.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
			end
			row.bg:SetColorTexture(0.20, 0.16, 0.06, 0.95)
			row.title:SetTextColor(1, 0.88, 0.35, 1)
			row.desc:SetTextColor(0.90, 0.84, 0.60, 1)
		else
			row.icon:SetTexture("Interface\\GossipFrame\\IncompleteQuestIcon")
			if row.icon.SetTexCoord then
				row.icon:SetTexCoord(0, 1, 0, 1)
			end
			if odd then
				row.bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
			else
				row.bg:SetColorTexture(0.17, 0.13, 0.09, 0.88)
			end
			row.title:SetTextColor(0.95, 0.95, 0.92, 1)
			row.desc:SetTextColor(0.72, 0.70, 0.65, 1)
		end
	end
	row.bg:Show()
end

function ns.EnsureFeatItemRow(i)
	local child = ui.achChild
	local row = ui.achRows[i]
	if row then
		return row
	end
	row = CreateFrame("Button", nil, child)
	row:SetHeight(ACH_ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp")
	row:EnableMouse(true)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", SECTION_INSET, 0)

	row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.title:SetPoint("TOPLEFT", SECTION_INSET + 28, -5)
	row.title:SetPoint("TOPRIGHT", -SECTION_INSET, -5)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)
	if row.title.SetMaxLines then
		row.title:SetMaxLines(1)
	end

	row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.desc:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -1)
	row.desc:SetPoint("RIGHT", -SECTION_INSET, 0)
	row.desc:SetJustifyH("LEFT")
	row.desc:SetWordWrap(false)
	if row.desc.SetMaxLines then
		row.desc:SetMaxLines(1)
	end

	row:SetScript("OnClick", function(self)
		if not self.featId then
			return
		end
		if IsShiftKeyDown() then
			ns.ToggleFeatTrack(self.featId)
			if ns.UpdateAchievements then
				ns.UpdateAchievements()
			end
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON", 856)
		end
	end)
	row:SetScript("OnEnter", function(self)
		if not self.featId then
			return
		end
		local ach = ns.FindAchievement and ns.FindAchievement(self.featId)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(ach and ach.name or self.featId, 1, 0.82, 0)
		if ach and ach.desc then
			GameTooltip:AddLine(ach.desc, 0.9, 0.9, 0.9, true)
		end
		local done = ns.DB().achievements[self.featId] ~= nil
		if done then
			GameTooltip:AddLine("Completed", 0.4, 0.9, 0.4)
		elseif ns.IsFeatTracked(self.featId) then
			GameTooltip:AddLine("Shift-click to stop tracking", 0.65, 0.65, 0.65)
		else
			GameTooltip:AddLine("Shift-click to track on the objective tracker", 0.65, 0.65, 0.65)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	ui.achRows[i] = row
	return row
end

-- Feat cat chrome: thin gold double-line (UI-Tooltip-Border) — same family as
-- SpellBook profession / First Aid panels. Forever's InsetFrameTemplate NineSlice
-- is a thick grey metal bevel and is the wrong asset.
local FEAT_CAT_BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	edgeSize = 14,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function ApplyFeatCatBackdrop(frame, borderR, borderG, borderB, borderA, fillR, fillG, fillB, fillA)
	if not (frame and frame.SetBackdrop) then
		return
	end
	-- Prefer a live profession panel's backdrop when available (exact same assets).
	local donor
	for _, name in ipairs({
		"PrimaryProfession1",
		"PrimaryProfession2",
		"SecondaryProfession1",
		"SecondaryProfession2",
		"SecondaryProfession3",
	}) do
		local f = _G[name]
		if f and f.backdropInfo and f.backdropInfo.edgeFile then
			donor = f
			break
		end
	end
	if donor and donor.backdropInfo then
		frame:SetBackdrop(donor.backdropInfo)
		if donor.GetBackdropColor and frame.SetBackdropColor then
			local r, g, b, a = donor:GetBackdropColor()
			frame:SetBackdropColor(fillR or r or 0.1, fillG or g or 0.12, fillB or b or 0.1, fillA or a or 0.96)
		else
			frame:SetBackdropColor(fillR or 0.10, fillG or 0.12, fillB or 0.10, fillA or 0.96)
		end
		if donor.GetBackdropBorderColor and frame.SetBackdropBorderColor then
			local r, g, b, a = donor:GetBackdropBorderColor()
			frame:SetBackdropBorderColor(borderR or r or 0.7, borderG or g or 0.6, borderB or b or 0.35, borderA or a or 1)
		else
			frame:SetBackdropBorderColor(borderR or 0.72, borderG or 0.62, borderB or 0.35, borderA or 1)
		end
	else
		frame:SetBackdrop(FEAT_CAT_BACKDROP)
		frame:SetBackdropColor(fillR or 0.10, fillG or 0.12, fillB or 0.10, fillA or 0.96)
		frame:SetBackdropBorderColor(borderR or 0.72, borderG or 0.62, borderB or 0.35, borderA or 1)
	end
end

function ns.EnsureFeatCategoryRow(i)
	local child = ui.achChild
	local row = ui.featCatRows[i]
	if row then
		return row
	end
	-- Category tiles: tooltip-border gold box (First Aid style), not Inset NineSlice.
	row = CreateFrame("Button", nil, child, BackdropTemplateMixin and "BackdropTemplate" or nil)
	row:SetHeight(FEAT_CAT_CARD_HEIGHT)
	row:RegisterForClicks("LeftButtonUp")
	ApplyFeatCatBackdrop(row)

	row.bg = row -- fill driven via SetBackdropColor
	row.box = row

	row.hl = row:CreateTexture(nil, "HIGHLIGHT")
	row.hl:SetPoint("TOPLEFT", 5, -5)
	row.hl:SetPoint("BOTTOMRIGHT", -5, 5)
	row.hl:SetColorTexture(1, 0.9, 0.45, 0.10)

	-- Habit-style XP bar at the bottom: tooltip chrome + gold StatusBar + on-bar text.
	row.barWrap = CreateFrame("Frame", nil, row)
	row.barWrap:SetHeight(FEAT_CAT_BAR_H)
	row.barWrap:SetPoint("BOTTOMLEFT", FEAT_CAT_INSET + 2, FEAT_CAT_INSET + 2)
	row.barWrap:SetPoint("BOTTOMRIGHT", -(FEAT_CAT_INSET + 2), FEAT_CAT_INSET + 2)
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
	-- Parent to the border frame so the tooltip edge chrome cannot cover it.
	row.progress = barBorder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.progress:SetPoint("CENTER", row.bar, "CENTER", 0, 0)
	row.progress:SetTextColor(1, 1, 1, 1)
	do
		local fontPath, fontSize = row.progress:GetFont()
		if fontPath then
			row.progress:SetFont(fontPath, fontSize or 11, "OUTLINE")
		end
	end
	if row.progress.SetShadowOffset then
		row.progress:SetShadowOffset(0, 0)
		row.progress:SetShadowColor(0, 0, 0, 0)
	end

	-- Icon (achievement-themed art; thin gold rim).
	row.iconBorder = CreateFrame("Frame", nil, row)
	row.iconBorder:SetSize(FEAT_CAT_ICON, FEAT_CAT_ICON)
	row.iconBorder:SetPoint("TOP", row.bg, "TOP", 0, -FEAT_CAT_INSET - 4)
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
	row.title:SetPoint("LEFT", row.bg, "LEFT", FEAT_CAT_INSET + 2, 0)
	row.title:SetPoint("RIGHT", row.bg, "RIGHT", -(FEAT_CAT_INSET + 2), 0)
	row.title:SetJustifyH("CENTER")
	row.title:SetTextColor(1, 0.86, 0.25, 1)
	if row.title.SetMaxLines then
		row.title:SetMaxLines(1)
	end
	row.title:SetWordWrap(false)

	-- Description: room to wrap; hover tooltip always shows the full line.
	row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.desc:SetPoint("TOP", row.title, "BOTTOM", 0, -5)
	row.desc:SetPoint("LEFT", row.bg, "LEFT", FEAT_CAT_INSET + 4, 0)
	row.desc:SetPoint("RIGHT", row.bg, "RIGHT", -(FEAT_CAT_INSET + 4), 0)
	row.desc:SetPoint("BOTTOM", row.barWrap, "TOP", 0, 6)
	row.desc:SetJustifyH("CENTER")
	row.desc:SetJustifyV("TOP")
	row.desc:SetTextColor(0.82, 0.84, 0.78, 1)
	row.desc:SetWordWrap(true)
	if row.desc.SetNonSpaceWrap then
		row.desc:SetNonSpaceWrap(false)
	end

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
		ui.featBack:ClearAllPoints()
		ui.featBack:SetPoint("BOTTOMRIGHT", -8, 8)
	end

	-- Detail: progress bar + frog above the section header; categories: centred count + frog.
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

		if ui.featDetailBar then
			local maxV = (total and total > 0) and total or 1
			ui.featDetailBar:SetMinMaxValues(0, maxV)
			ui.featDetailBar:SetValue(math.min(earned or 0, maxV))
			if earned >= total and total > 0 then
				ui.featDetailBar:SetStatusBarColor(1, 0.88, 0.2, 1)
			else
				ui.featDetailBar:SetStatusBarColor(1, 0.82, 0, 1)
			end
		end
		if ui.featDetailBarText then
			ui.featDetailBarText:SetText(string.format("%d / %d", earned or 0, total or 0))
		end
		if ui.featDetailBarWrap then
			ui.featDetailBarWrap._earned = earned or 0
			ui.featDetailBarWrap._total = total or 0
		end
		if ui.LayoutFeatSummaryCluster then
			ui.LayoutFeatSummaryCluster()
		end

		if ui.achSummaryCluster and ui.achSummaryIcon then
			ui.achSummaryCluster:ClearAllPoints()
			ui.achSummaryCluster:SetPoint("TOP", 0, SECTION_TOP)
			ui.achSummaryCluster:Show()
			ui.achSummaryIcon:Show()
		end

		if ui.featDetailHeader then
			ui.featDetailHeader:Show()
			local label = ui.featDetailHeader.label
				or ui.featDetailHeader.Text
				or (ui.featDetailHeader.GetFontString and ui.featDetailHeader:GetFontString())
			if ui.featDetailHeader.SetText then
				ui.featDetailHeader:SetText(catName)
			end
			if label and label.SetText then
				label:SetText(catName)
			end
			local clusterH = (ui.achSummaryCluster and ui.achSummaryCluster:GetHeight()) or 28
			ui.featDetailHeader:ClearAllPoints()
			ui.featDetailHeader:SetPoint("TOPLEFT", SECTION_INSET, SECTION_TOP - clusterH + SECTION_BELOW)
			ui.featDetailHeader:SetPoint("TOPRIGHT", -SECTION_INSET, SECTION_TOP - clusterH + SECTION_BELOW)
		end

		if ui.LayoutFeatScroll then
			ui.LayoutFeatScroll(true)
		end

		local scroll = ui.achScroll
		local contentW = (scroll and scroll:GetWidth()) or child:GetWidth() or 0
		if contentW > 80 then
			child:SetWidth(contentW)
		end

		for i, ach in ipairs(feats) do
			local row = ns.EnsureFeatItemRow(i)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -(i - 1) * ACH_ROW_HEIGHT)
			row:SetPoint("TOPRIGHT", 0, -(i - 1) * ACH_ROW_HEIGHT)
			row:Show()
			ns.StyleFeatItemRow(row, ach, ns.DB().achievements[ach.id] ~= nil, i)
		end
		for i = #feats + 1, #ui.achRows do
			ui.achRows[i]:Hide()
		end

		child:SetHeight(math.max(#feats, 1) * ACH_ROW_HEIGHT + 8)
		if scroll and scroll.UpdateScrollChildRect then
			scroll:UpdateScrollChildRect()
		end
	else
		if ui.featDetailHeader then
			ui.featDetailHeader:Hide()
		end
		if ui.achSummaryCluster and ui.achSummaryIcon then
			ui.achSummaryCluster:ClearAllPoints()
			ui.achSummaryCluster:SetPoint("TOP", 0, SECTION_TOP)
			ui.achSummaryCluster:Show()
			ui.achSummaryIcon:Show()
		end
		if ui.LayoutFeatScroll then
			ui.LayoutFeatScroll(false)
		end

		ns.HideFeatRows(ui.achRows)

		local scroll = ui.achScroll
		local contentW = (scroll and scroll:GetWidth()) or child:GetWidth() or 0
		if contentW < 80 then
			contentW = 300
		else
			-- Leave a small right margin (~10px) so cards aren't flush to the bar.
			contentW = contentW - 10
			child:SetWidth(contentW)
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
			if row.SetBackdropBorderColor then
				row:SetBackdropBorderColor(r, g, b, a or 1)
			end
		end

		local function SetCardFill(row, r, g, b, a)
			if row.SetBackdropColor then
				row:SetBackdropColor(r, g, b, a or 1)
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
				SetCardFill(row, 0.18, 0.16, 0.08, 0.97)
				row.bar:SetStatusBarColor(1, 0.88, 0.2, 1)
				SetCardEdgeColor(row, 1, 0.82, 0, 1)
				SetIconEdgeColor(row, 1, 0.86, 0.25, 1)
			elseif earned > 0 then
				row.title:SetTextColor(1, 0.86, 0.35, 1)
				SetCardFill(row, 0.11, 0.13, 0.10, 0.97)
				row.bar:SetStatusBarColor(1, 0.82, 0, 1)
				SetCardEdgeColor(row, 0.85, 0.72, 0.32, 0.95)
				SetIconEdgeColor(row, 0.95, 0.8, 0.3, 0.95)
			else
				row.title:SetTextColor(1, 0.82, 0.3, 1)
				SetCardFill(row, 0.09, 0.11, 0.09, 0.96)
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
		if ui.featDetailBar then
			local maxV = (#ACHIEVEMENTS > 0) and #ACHIEVEMENTS or 1
			ui.featDetailBar:SetMinMaxValues(0, maxV)
			ui.featDetailBar:SetValue(math.min(totalEarned or 0, maxV))
			if totalEarned >= #ACHIEVEMENTS and #ACHIEVEMENTS > 0 then
				ui.featDetailBar:SetStatusBarColor(1, 0.88, 0.2, 1)
			else
				ui.featDetailBar:SetStatusBarColor(1, 0.82, 0, 1)
			end
		end
		if ui.featDetailBarText then
			ui.featDetailBarText:SetText(string.format("%d / %d", totalEarned or 0, #ACHIEVEMENTS))
		end
		if ui.featDetailBarWrap then
			ui.featDetailBarWrap._earned = totalEarned or 0
			ui.featDetailBarWrap._total = #ACHIEVEMENTS
		end
		if ui.LayoutFeatSummaryCluster then
			ui.LayoutFeatSummaryCluster()
		end
	end
end

function ns.BuildPanel()
	if S.panel then
		return S.panel
	end

	S.panel = CreateFrame("Frame", "AJHFrame", UIParent, "ButtonFrameTemplate")
	S.panel:SetSize(384, 424)
	S.panel:SetPoint("CENTER")
	S.panel:SetFrameStrata("MEDIUM")
	S.panel:SetToplevel(true)
	S.panel:SetMovable(true)
	S.panel:EnableMouse(true)
	S.panel:RegisterForDrag("LeftButton")
	S.panel:SetScript("OnDragStart", S.panel.StartMoving)
	S.panel:SetScript("OnDragStop", S.panel.StopMovingOrSizing)
	S.panel:Hide()

	tinsert(UISpecialFrames, "AJHFrame")

	if ButtonFrameTemplate_HideButtonBar then
		ButtonFrameTemplate_HideButtonBar(S.panel)
	end
	ns.ApplyModernPanelChrome(S.panel)
	if S.panel.SetTitle then
		S.panel:SetTitle("Archindula's Jump Habit")
	elseif S.panel.TitleContainer and S.panel.TitleContainer.TitleText then
		S.panel.TitleContainer.TitleText:SetText("Archindula's Jump Habit")
	elseif S.panel.TitleText then
		S.panel.TitleText:SetText("Archindula's Jump Habit")
	end
	-- Frog portrait (same path as the release — works on Forever).
	if S.panel.SetPortraitToTexture then
		S.panel:SetPortraitToTexture(FROG_ICON)
	elseif S.panel.SetPortraitToAsset then
		S.panel:SetPortraitToAsset(FROG_ICON)
	else
		local portrait = S.panel.PortraitContainer and S.panel.PortraitContainer.portrait or S.panel.portrait
		if portrait then
			portrait:SetTexture(FROG_ICON)
		end
	end
	if S.panel.PortraitContainer then
		S.panel.PortraitContainer:Show()
	end
	if S.panel.portrait then
		S.panel.portrait:Show()
	end
	if S.panel.TitleContainer then
		S.panel.TitleContainer:EnableMouse(true)
		S.panel.TitleContainer:RegisterForDrag("LeftButton")
		S.panel.TitleContainer:SetScript("OnDragStart", function()
			S.panel:StartMoving()
		end)
		S.panel.TitleContainer:SetScript("OnDragStop", function()
			S.panel:StopMovingOrSizing()
		end)
	end

	local content = CreateFrame("Frame", nil, S.panel)
	if S.panel.Inset then
		S.panel.Inset:ClearAllPoints()
		-- Pull inset up under the title and down over the button-bar strip.
		S.panel.Inset:SetPoint("TOPLEFT", 8, -28)
		S.panel.Inset:SetPoint("BOTTOMRIGHT", -8, 6)
		content:SetParent(S.panel.Inset)
		content:SetAllPoints()
	else
		content:SetPoint("TOPLEFT", 12, -32)
		content:SetPoint("BOTTOMRIGHT", -12, 8)
	end

	-- Settings cog on the panel chrome (left of the stock close button).
	local gear = CreateFrame("Button", "AJHSettingsButton", S.panel)
	gear:SetSize(18, 18)
	local nsLevel = S.panel.NineSlice and S.panel.NineSlice.GetFrameLevel and S.panel.NineSlice:GetFrameLevel() or 0
	local titleLevel = S.panel.TitleContainer and S.panel.TitleContainer.GetFrameLevel and S.panel.TitleContainer:GetFrameLevel() or 0
	gear:SetFrameLevel(math.max(S.panel:GetFrameLevel(), nsLevel, titleLevel) + 20)
	if S.panel.CloseButton then
		gear:SetPoint("RIGHT", S.panel.CloseButton, "LEFT", -6, 0)
	else
		gear:SetPoint("TOPRIGHT", S.panel, "TOPRIGHT", -28, -4)
	end
	local gearIcon = gear:CreateTexture(nil, "ARTWORK")
	gearIcon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
	gearIcon:SetSize(16, 16)
	gearIcon:SetPoint("CENTER")
	gearIcon:SetVertexColor(0.9, 0.9, 0.9)
	gear.icon = gearIcon
	gear:EnableMouse(true)
	gear:Show()
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

	-- Ensure stock close stays above chrome / gear (release left this button alone).
	if S.panel.CloseButton then
		local cb = S.panel.CloseButton
		cb:SetFrameLevel(gear:GetFrameLevel() + 5)
		cb:EnableMouse(true)
		cb:Show()
	end

	local tabDefs = {
		{ id = "habit", label = "Habit" },
		{ id = "stats", label = "Stats" },
		{ id = "achieves", label = "Feats" },
		{ id = "guild", label = "Guild" },
	}
	ui.tabIndex = {}
	ui.tabButtons = {}
	for i, def in ipairs(tabDefs) do
		local tab = CreateFrame("Button", "AJHFrameTab" .. i, S.panel, "PanelTabButtonTemplate")
		tab:SetID(i)
		tab:SetText(def.label or "")
		tab.tabId = def.id
		if i == 1 then
			tab:SetPoint("TOPLEFT", S.panel, "BOTTOMLEFT", 11, 2)
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
	PanelTemplates_SetNumTabs(S.panel, #tabDefs)
	PanelTemplates_SetTab(S.panel, 1)

	-- Habit page
	local habit = CreateFrame("Frame", nil, content)
	habit:SetAllPoints()
	ui.pages.habit = habit

	local habitMain = CreateFrame("Frame", nil, habit)
	habitMain:SetAllPoints()
	ui.habitMain = habitMain
	ns.ApplyContentFill(habitMain)

	local levelLabel = habitMain:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	levelLabel:SetPoint("TOP", habitMain, "TOP", 0, -10)
	levelLabel:SetText("LEVEL")
	levelLabel:SetTextColor(1, 0.82, 0)

	ui.level = habitMain:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	ui.level:SetPoint("TOP", levelLabel, "BOTTOM", 0, -2)
	-- Large gold level number.
	local levelFont = (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
	ui.level:SetFont(levelFont, 36, "OUTLINE")
	ui.level:SetTextColor(1, 0.82, 0)
	if ui.level.SetShadowOffset then
		ui.level:SetShadowOffset(2, -2)
		ui.level:SetShadowColor(0, 0, 0, 0.85)
	end

	-- Habit XP bar (dialog): 1.2.0 design — tooltip border + gold fill + silver tip.
	local BAR_PAD = 22
	local barWrap = CreateFrame("Frame", nil, habitMain)
	barWrap:ClearAllPoints()
	barWrap:SetPoint("TOP", ui.level, "BOTTOM", 0, -10)
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

	local summaryHeader = ns.CreateSectionHeader(habitMain, "Summary")
	summaryHeader:SetPoint("LEFT", habitMain, "LEFT", SECTION_INSET, 0)
	summaryHeader:SetPoint("RIGHT", habitMain, "RIGHT", -SECTION_INSET, 0)
	summaryHeader:SetPoint("TOP", ui.xpDetail, "BOTTOM", 0, -10)

	local jumpRow = ns.CreateModernStatRow(habitMain, summaryHeader, SECTION_BELOW, "Total jumps", 1)
	ui.jumpLabel, ui.jumpValue = jumpRow.label, jumpRow.value

	local xpRow = ns.CreateModernStatRow(habitMain, jumpRow, 0, "Experience", 2)
	ui.xpLabel, ui.xpValue = xpRow.label, xpRow.value

	local nextRow = ns.CreateModernStatRow(habitMain, xpRow, 0, "XP to next level", 3)
	ui.nextLabel, ui.nextValue = nextRow.label, nextRow.value

	local rateRow = ns.CreateModernStatRow(habitMain, nextRow, 0, "XP per jump", 4)
	ui.rateLabel, ui.rateValue = rateRow.label, rateRow.value
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

	-- Levels button lives on the page chrome (not inside the scroll child).
	local levelsBtn = CreateFrame("Button", nil, statsPage, "UIPanelButtonTemplate")
	levelsBtn:SetSize(72, 20)
	levelsBtn:SetPoint("BOTTOMRIGHT", -8, 8)
	levelsBtn:SetText("Levels")
	levelsBtn:SetScript("OnClick", function()
		ns.ShowStatsView("levels")
		if S.panel then
			S.panel:Update()
		end
	end)
	ui.levelsButton = levelsBtn

	local statsWrap, statsScroll, statsMain = ns.CreateScrollArea(statsPage, { overlayBar = false })
	statsWrap:ClearAllPoints()
	statsWrap:SetPoint("TOPLEFT", 0, 0)
	statsWrap:SetPoint("BOTTOMRIGHT", 0, 32)
	ui.statsWrap = statsWrap
	ui.statsMain = statsMain
	ui.statsScroll = statsScroll
	ns.ApplyContentFill(statsMain)

	local sessionHeader = ns.CreateSectionHeader(statsMain, "This Session")
	sessionHeader:SetPoint("TOPLEFT", statsMain, "TOPLEFT", SECTION_INSET, SECTION_TOP)
	sessionHeader:SetPoint("TOPRIGHT", statsMain, "TOPRIGHT", -SECTION_INSET, SECTION_TOP)

	local stripe = 0
	local function StatsModernRow(anchor, yOff, labelText)
		stripe = stripe + 1
		local row = ns.CreateModernStatRow(statsMain, anchor, yOff, labelText, stripe)
		return row.label, row.value, row
	end

	local r
	ui.statSessionJumpsLabel, ui.statSessionJumps, r = StatsModernRow(sessionHeader, SECTION_BELOW, "Session jumps")
	ui.statSessionHighLabel, ui.statSessionHigh, r = StatsModernRow(r, 0, "Best session")
	ui.statSessionTimeLabel, ui.statSessionTime, r = StatsModernRow(r, 0, "Session time")
	ui.statSessionActivityLabel, ui.statSessionActivity, r = StatsModernRow(r, 0, "Session activity")
	ui.statSessionRateLabel, ui.statSessionRate, r = StatsModernRow(r, 0, "Session rate")
	ui.statRecentRateLabel, ui.statRecentRate, r = StatsModernRow(r, 0, "Recent rate (5m)")

	local lifeHeader = ns.CreateSectionHeader(statsMain, "Lifetime")
	lifeHeader:SetPoint("LEFT", statsMain, "LEFT", SECTION_INSET, 0)
	lifeHeader:SetPoint("RIGHT", statsMain, "RIGHT", -SECTION_INSET, 0)
	lifeHeader:SetPoint("TOP", r, "BOTTOM", 0, -8)

	stripe = 0
	ui.statLifeJumpsLabel, ui.statLifeJumps, r = StatsModernRow(lifeHeader, SECTION_BELOW, "Lifetime jumps")
	ui.statLifeLevelLabel, ui.statLifeLevel, r = StatsModernRow(r, 0, "Lifetime level")
	ui.statLifeActivityLabel, ui.statLifeActivity, r = StatsModernRow(r, 0, "Lifetime activity")
	ui.statFeatsLabel, ui.statFeats, r = StatsModernRow(r, 0, "Feats unlocked")
	ui.statLastJumpLabel, ui.statLastJump, r = StatsModernRow(r, 0, "Time since last jump")

	local function LayoutStatsScroll()
		local scroll = ui.statsScroll
		local child = ui.statsMain
		if not scroll or not child or not r then
			return
		end
		local w = scroll:GetWidth() or 0
		if w > 0 then
			child:SetWidth(w)
		end
		-- Approximate content height from session header through last row.
		local top = sessionHeader:GetTop()
		local bottom = r:GetBottom()
		local parentTop = child:GetTop()
		if top and bottom and parentTop then
			child:SetHeight(math.max(1, (parentTop - bottom) + 16))
		else
			child:SetHeight(360)
		end
		if scroll.UpdateScrollChildRect then
			scroll:UpdateScrollChildRect()
		end
	end
	ui.LayoutStatsScroll = LayoutStatsScroll
	statsMain:HookScript("OnShow", LayoutStatsScroll)
	statsScroll:HookScript("OnSizeChanged", LayoutStatsScroll)

	local levels = CreateFrame("Frame", nil, statsPage)
	levels:SetAllPoints()
	levels:Hide()
	ui.statsLevels = levels
	ns.ApplyContentFill(levels)

	local levelsBack = CreateFrame("Button", nil, levels, "UIPanelButtonTemplate")
	levelsBack:SetSize(60, 20)
	levelsBack:SetPoint("BOTTOMRIGHT", -8, 8)
	levelsBack:SetText("Back")
	levelsBack:SetScript("OnClick", function()
		ns.ShowStatsView("main")
		if S.panel then
			S.panel:Update()
		end
	end)
	ui.levelsBack = levelsBack

	-- Same scroll chrome as Stats: section header lives inside the child.
	local levelsWrap, levelScroll, levelChild = ns.CreateScrollArea(levels, { overlayBar = false })
	levelsWrap:ClearAllPoints()
	levelsWrap:SetPoint("TOPLEFT", 0, 0)
	levelsWrap:SetPoint("BOTTOMRIGHT", 0, 32)
	ui.levelWrap = levelsWrap
	ui.levelScroll = levelScroll
	ui.levelChild = levelChild
	ns.ApplyContentFill(levelChild)
	ns.BuildLevelRows(levelChild)

	local function LayoutLevelsScroll()
		if not (levelScroll and levelChild) then
			return
		end
		local w = levelScroll:GetWidth() or 0
		if w > 0 then
			levelChild:SetWidth(w)
		end
		if ui.levelsSectionHeader then
			ui.levelsSectionHeader:ClearAllPoints()
			ui.levelsSectionHeader:SetPoint("TOPLEFT", SECTION_INSET, SECTION_TOP)
			ui.levelsSectionHeader:SetPoint("TOPRIGHT", -SECTION_INSET, SECTION_TOP)
		end
		if ui.levelColHeader then
			LayoutLevelColumns(ui.levelColHeader)
		end
		for _, row in pairs(ui.levelRows) do
			LayoutLevelColumns(row)
		end
	end
	ui.LayoutLevelsScroll = LayoutLevelsScroll
	levels:HookScript("OnShow", LayoutLevelsScroll)
	levelScroll:HookScript("OnSizeChanged", LayoutLevelsScroll)

	ns.ShowStatsView("main")

	-- Achievements page
	local achieves = CreateFrame("Frame", nil, content)
	achieves:SetAllPoints()
	achieves:Hide()
	ui.pages.achieves = achieves
	ns.ApplyContentFill(achieves)

	ui.featBack = CreateFrame("Button", nil, achieves, "UIPanelButtonTemplate")
	ui.featBack:SetSize(56, 20)
	ui.featBack:SetPoint("BOTTOMRIGHT", -8, 8)
	ui.featBack:SetText("Back")
	ui.featBack:Hide()
	ui.featBack:SetScript("OnClick", function()
		ui.featView = "categories"
		ns.PlayUISound("IG_CHARACTER_INFO_TAB", 841)
		ns.UpdateAchievements()
	end)

	-- Category detail: section header below a progress bar + frog cluster.
	ui.featDetailHeader = ns.CreateSectionHeader(achieves, "Feats")
	ui.featDetailHeader:Hide()

	local FROG_SIZE = 28
	local DETAIL_BAR_W = 240
	local DETAIL_BAR_H = FEAT_CAT_BAR_H
	ui.achSummaryCluster = CreateFrame("Frame", nil, achieves)
	ui.achSummaryCluster:SetHeight(FROG_SIZE)
	ui.achSummaryCluster:SetFrameLevel(achieves:GetFrameLevel() + 5)
	ui.achSummaryCluster:SetPoint("TOP", 0, SECTION_TOP)

	ui.achSummaryIcon = CreateFrame("Frame", nil, ui.achSummaryCluster)
	ui.achSummaryIcon:SetSize(FROG_SIZE, FROG_SIZE)
	ui.achSummaryIcon:SetPoint("RIGHT", ui.achSummaryCluster, "RIGHT", 0, 0)
	local frog = ui.achSummaryIcon:CreateTexture(nil, "ARTWORK")
	frog:SetAllPoints()
	frog:SetTexture("Interface\\AddOns\\AJH\\AJH-gold-frog")
	if frog.SetTexCoord then
		frog:SetTexCoord(0.06, 0.94, 0.06, 0.94)
	end
	if frog.SetBlendMode then
		frog:SetBlendMode("BLEND")
	end
	ui.achSummaryIcon.tex = frog

	-- Progress bar + frog (overview total and category detail share this chrome).
	ui.achSummary = ui.achSummaryCluster:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.achSummary:Hide()
	ui.achSummary:SetTextColor(1, 0.82, 0)

	ui.featDetailBarWrap = CreateFrame("Frame", nil, ui.achSummaryCluster)
	ui.featDetailBarWrap:SetSize(DETAIL_BAR_W, DETAIL_BAR_H)
	ui.featDetailBarWrap:SetPoint("RIGHT", ui.achSummaryIcon, "LEFT", -6, 0)
	ui.featDetailBarWrap:SetFrameLevel(ui.achSummaryCluster:GetFrameLevel() + 1)
	ui.featDetailBarWrap:Hide()

	local detailBarBorder = CreateFrame("Frame", nil, ui.featDetailBarWrap, BackdropTemplateMixin and "BackdropTemplate" or nil)
	detailBarBorder:SetPoint("TOPLEFT", 0, 0)
	detailBarBorder:SetPoint("BOTTOMRIGHT", 0, 0)
	detailBarBorder:SetFrameLevel(ui.featDetailBarWrap:GetFrameLevel() + 3)
	if detailBarBorder.SetBackdrop then
		detailBarBorder:SetBackdrop({
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		detailBarBorder:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
	end

	ui.featDetailBar = CreateFrame("StatusBar", nil, ui.featDetailBarWrap)
	ui.featDetailBar:SetPoint("TOPLEFT", ui.featDetailBarWrap, "TOPLEFT", 3, -3)
	ui.featDetailBar:SetPoint("BOTTOMRIGHT", ui.featDetailBarWrap, "BOTTOMRIGHT", -3, 3)
	ui.featDetailBar:SetMinMaxValues(0, 1)
	ui.featDetailBar:SetValue(0)
	ui.featDetailBar:SetFrameLevel(ui.featDetailBarWrap:GetFrameLevel() + 1)
	ui.featDetailBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	ui.featDetailBar:SetStatusBarColor(1.0, 0.82, 0.0, 1)
	do
		local fillTex = ui.featDetailBar:GetStatusBarTexture()
		if fillTex then
			fillTex:SetHorizTile(false)
			fillTex:SetVertTile(false)
		end
	end
	local detailTrack = ui.featDetailBar:CreateTexture(nil, "BACKGROUND")
	detailTrack:SetAllPoints()
	detailTrack:SetColorTexture(0.08, 0.07, 0.04, 1)

	ui.featDetailBarText = detailBarBorder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.featDetailBarText:SetPoint("CENTER", ui.featDetailBar, "CENTER", 0, 0)
	ui.featDetailBarText:SetTextColor(1, 1, 1, 1)
	do
		local fontPath, fontSize = ui.featDetailBarText:GetFont()
		if fontPath then
			ui.featDetailBarText:SetFont(fontPath, fontSize or 11, "OUTLINE")
		end
	end
	if ui.featDetailBarText.SetShadowOffset then
		ui.featDetailBarText:SetShadowOffset(0, 0)
		ui.featDetailBarText:SetShadowColor(0, 0, 0, 0)
	end

	ui.featDetailBarWrap:SetScript("OnEnter", function(self)
		local earned = self._earned or 0
		local total = self._total or 0
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(string.format("%d / %d complete", earned, total), 1, 0.82, 0)
		GameTooltip:Show()
	end)
	ui.featDetailBarWrap:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	ui.featDetailBarWrap:EnableMouse(true)

	ui.LayoutFeatSummaryCluster = function()
		local cluster = ui.achSummaryCluster
		local text = ui.achSummary
		local icon = ui.achSummaryIcon
		local barWrap = ui.featDetailBarWrap
		if not (cluster and icon and barWrap) then
			return
		end
		-- Same bar + frog on both category overview and detail (count lives in the bar).
		if text then
			text:Hide()
		end
		icon:ClearAllPoints()
		icon:SetPoint("RIGHT", cluster, "RIGHT", 0, 0)
		barWrap:Show()
		barWrap:ClearAllPoints()
		barWrap:SetPoint("RIGHT", icon, "LEFT", -6, 0)
		cluster:SetHeight(math.max(FROG_SIZE, DETAIL_BAR_H))
		cluster:SetWidth(DETAIL_BAR_W + 6 + FROG_SIZE)
	end

	local achWrap, achScroll, achChild = ns.CreateScrollArea(achieves, { overlayBar = false })
	achWrap:SetPoint("TOPLEFT", 4, -40)
	achWrap:SetPoint("BOTTOMRIGHT", -4, 4)
	ui.achWrap = achWrap
	ui.achScroll = achScroll
	ui.achChild = achChild

	ui.LayoutFeatScroll = function(inCategory)
		if not ui.achWrap then
			return
		end
		local bottom = 4
		if inCategory then
			bottom = DEV_TOOLS and 56 or 32
		elseif DEV_TOOLS then
			bottom = 32
		end
		local top = -40
		if inCategory and ui.featDetailHeader then
			local clusterH = (ui.achSummaryCluster and ui.achSummaryCluster:GetHeight()) or 28
			local headerH = ui.featDetailHeader:GetHeight() or 28
			-- Cluster at SECTION_TOP, header below it, then scroll.
			top = SECTION_TOP - clusterH + SECTION_BELOW - headerH + SECTION_BELOW
		end
		ui.achWrap:ClearAllPoints()
		ui.achWrap:SetPoint("TOPLEFT", SECTION_INSET, top)
		ui.achWrap:SetPoint("TOPRIGHT", -SECTION_INSET, top)
		ui.achWrap:SetPoint("BOTTOMLEFT", SECTION_INSET, bottom)
		ui.achWrap:SetPoint("BOTTOMRIGHT", -SECTION_INSET, bottom)
	end
	ui.LayoutFeatScroll(false)

	if achScroll then
		achScroll:HookScript("OnSizeChanged", function()
			if ui.featView == "categories" or not ui.featView then
				ns.UpdateAchievements()
			end
		end)
	end

	if DEV_TOOLS then
		local resetAch = CreateFrame("Button", nil, achieves, "UIPanelButtonTemplate")
		resetAch:SetPoint("BOTTOMLEFT", 12, 6)
		resetAch:SetPoint("RIGHT", ui.featBack, "LEFT", -8, 0)
		resetAch:SetHeight(22)
		resetAch:SetText("Reset feats (testing)")
		resetAch:SetScript("OnClick", function()
			ns.ResetAchievements()
		end)
	end

	-- Guild page (Leaderboard — same chrome language as Stats / Habit)
	local guild = CreateFrame("Frame", nil, content)
	guild:SetAllPoints()
	guild:Hide()
	ui.pages.guild = guild
	ns.ApplyContentFill(guild)

	local boardHeader = ns.CreateSectionHeader(guild, "Leaderboard")
	boardHeader:SetPoint("TOPLEFT", SECTION_INSET, SECTION_TOP)
	boardHeader:SetPoint("TOPRIGHT", -SECTION_INSET, SECTION_TOP)
	ui.guildSectionHeader = boardHeader

	ui.guildHint = guild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.guildHint:SetPoint("TOPLEFT", boardHeader, "BOTTOMLEFT", 2, -4)
	ui.guildHint:SetPoint("TOPRIGHT", boardHeader, "BOTTOMRIGHT", -2, -4)
	ui.guildHint:SetJustifyH("CENTER")
	ui.guildHint:SetTextColor(0.75, 0.72, 0.65, 1)
	ui.guildHint:Hide()

	local refresh = CreateFrame("Button", nil, guild, "UIPanelButtonTemplate")
	refresh:SetPoint("BOTTOMLEFT", 12, 6)
	refresh:SetPoint("BOTTOMRIGHT", -12, 6)
	refresh:SetHeight(22)
	refresh:SetText("Refresh guild scores")
	refresh:SetScript("OnClick", function()
		ns.RequestGuildScores()
		ns.UpdateLeaderboard()
	end)
	ui.guildRefresh = refresh

	local boardWrap, boardScroll, boardChild = ns.CreateScrollArea(guild, { overlayBar = false })
	boardWrap:ClearAllPoints()
	boardWrap:SetPoint("TOPLEFT", boardHeader, "BOTTOMLEFT", 0, SECTION_BELOW)
	boardWrap:SetPoint("TOPRIGHT", boardHeader, "BOTTOMRIGHT", 0, SECTION_BELOW)
	boardWrap:SetPoint("BOTTOMLEFT", refresh, "TOPLEFT", 0, 6)
	boardWrap:SetPoint("BOTTOMRIGHT", refresh, "TOPRIGHT", 0, 6)
	ui.boardWrap = boardWrap
	ui.boardScroll = boardScroll
	ui.boardChild = boardChild
	ns.ApplyContentFill(boardChild)

	-- Column header row (same columns as data rows).
	local colHeader = CreateFrame("Frame", nil, boardChild)
	colHeader:SetHeight(COL_HEADER_H)
	colHeader:SetPoint("TOPLEFT", 0, 0)
	colHeader:SetPoint("TOPRIGHT", 0, 0)
	colHeader.bg = colHeader:CreateTexture(nil, "BACKGROUND")
	colHeader.bg:SetAllPoints()
	colHeader.bg:SetColorTexture(0.12, 0.10, 0.07, 0.95)
	colHeader.rank = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.rank:SetText("#")
	colHeader.rank:SetTextColor(1, 0.82, 0)
	colHeader.name = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.name:SetText("Name")
	colHeader.name:SetTextColor(1, 0.82, 0)
	colHeader.level = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.level:SetText("Lvl")
	colHeader.level:SetTextColor(1, 0.82, 0)
	colHeader.jumps = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.jumps:SetText("Jumps")
	colHeader.jumps:SetTextColor(1, 0.82, 0)
	colHeader.achs = colHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colHeader.achs:SetText("Feats")
	colHeader.achs:SetTextColor(1, 0.82, 0)
	LayoutBoardColumns(colHeader)
	ui.boardColHeader = colHeader

	-- Keep scroll top under header/hint.
	local function LayoutGuildScroll()
		if not boardWrap or not boardHeader then
			return
		end
		boardWrap:ClearAllPoints()
		local topAnchor = boardHeader
		local topOff = SECTION_BELOW
		if ui.guildHint and ui.guildHint:IsShown() then
			topAnchor = ui.guildHint
			topOff = SECTION_BELOW
		end
		boardWrap:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, topOff)
		boardWrap:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, topOff)
		boardWrap:SetPoint("BOTTOMLEFT", refresh, "TOPLEFT", 0, 6)
		boardWrap:SetPoint("BOTTOMRIGHT", refresh, "TOPRIGHT", 0, 6)
		if boardScroll then
			local w = boardScroll:GetWidth() or 0
			if w > 0 and boardChild then
				boardChild:SetWidth(w)
			end
		end
		LayoutBoardColumns(colHeader)
	end
	ui.LayoutGuildScroll = LayoutGuildScroll
	guild:HookScript("OnShow", function()
		LayoutGuildScroll()
		ns.UpdateLeaderboard()
	end)
	if boardScroll then
		boardScroll:HookScript("OnSizeChanged", LayoutGuildScroll)
	end

	-- Settings page — section chrome like Habit / Stats / Guild.
	local settings = CreateFrame("Frame", nil, content)
	settings:SetAllPoints()
	settings:Hide()
	ui.pages.settings = settings
	ns.ApplyContentFill(settings)

	local generalHeader = ns.CreateSectionHeader(settings, "General")
	generalHeader:SetPoint("TOPLEFT", SECTION_INSET, SECTION_TOP)
	generalHeader:SetPoint("TOPRIGHT", -SECTION_INSET, SECTION_TOP)

	local function MakeSettingsCheck(anchor, yOff, labelText)
		local check = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
		local label = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", check, "RIGHT", 6, 1)
		label:SetText(labelText)
		label:SetTextColor(0.95, 0.95, 0.92)
		-- Clicking the label toggles the checkbox.
		local hit = CreateFrame("Button", nil, settings)
		hit:SetPoint("LEFT", label, "LEFT", 0, 0)
		hit:SetPoint("RIGHT", label, "RIGHT", 0, 0)
		hit:SetHeight(24)
		hit:SetScript("OnClick", function()
			check:Click()
		end)
		return check, label
	end

	local announceCheck = MakeSettingsCheck(generalHeader, SECTION_BELOW - 2, "Auto announce feats to guild")
	announceCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.DB().autoAnnounce = not not self:GetChecked()
	end)
	ui.announceCheck = announceCheck

	local xpBarCheck = MakeSettingsCheck(announceCheck, -4, "Show Jump XP bar")
	xpBarCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.SetJumpXPBarShown(not not self:GetChecked())
	end)
	ui.jumpXPBarCheck = xpBarCheck

	local minimapCheck = MakeSettingsCheck(xpBarCheck, -4, "Show minimap button")
	minimapCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.SetMinimapButtonShown(not not self:GetChecked())
	end)
	ui.minimapCheck = minimapCheck

	local toastCheck = MakeSettingsCheck(minimapCheck, -4, "Show feat unlock toasts")
	toastCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.DB().showFeatToasts = not not self:GetChecked()
	end)
	ui.toastCheck = toastCheck

	local audioHeader = ns.CreateSectionHeader(settings, "Audio")
	audioHeader:ClearAllPoints()
	audioHeader:SetPoint("LEFT", settings, "LEFT", SECTION_INSET, 0)
	audioHeader:SetPoint("RIGHT", settings, "RIGHT", -SECTION_INSET, 0)
	audioHeader:SetPoint("TOP", toastCheck, "BOTTOM", 0, -14)

	local soundCheck = MakeSettingsCheck(audioHeader, SECTION_BELOW - 2, "Enable sounds")
	soundCheck:SetScript("OnClick", function(self)
		ns.EnsureDB()
		ns.DB().soundsEnabled = not not self:GetChecked()
	end)
	ui.soundCheck = soundCheck

	local volumeLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	volumeLabel:SetPoint("TOPLEFT", soundCheck, "BOTTOMLEFT", 2, -12)
	volumeLabel:SetText("Sound volume")
	volumeLabel:SetTextColor(1, 0.82, 0)
	ui.soundVolumeLabel = volumeLabel

	local volumeValue = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	volumeValue:SetPoint("TOP", volumeLabel, "TOP", 0, 0)
	volumeValue:SetPoint("RIGHT", settings, "RIGHT", -SECTION_INSET, 0)
	volumeValue:SetJustifyH("RIGHT")
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
	volumeSlider:ClearAllPoints()
	volumeSlider:SetPoint("TOPLEFT", volumeLabel, "BOTTOMLEFT", 0, -10)
	volumeSlider:SetPoint("RIGHT", settings, "RIGHT", -SECTION_INSET, 0)
	volumeSlider:SetHeight(16)
	volumeSlider:SetMinMaxValues(0, 100)
	volumeSlider:SetValueStep(1)
	if volumeSlider.SetObeyStepOnDrag then
		volumeSlider:SetObeyStepOnDrag(true)
	end
	-- OptionsSliderTemplate draws its own title on the track — hide it (was overlapping).
	do
		local name = volumeSlider:GetName()
		local low = name and _G[name .. "Low"]
		local high = name and _G[name .. "High"]
		local text = name and _G[name .. "Text"]
		if low then
			low:SetText("0")
			low:ClearAllPoints()
			low:SetPoint("TOPLEFT", volumeSlider, "BOTTOMLEFT", 0, -2)
			low:SetTextColor(0.65, 0.65, 0.65)
		end
		if high then
			high:SetText("100")
			high:ClearAllPoints()
			high:SetPoint("TOPRIGHT", volumeSlider, "BOTTOMRIGHT", 0, -2)
			high:SetTextColor(0.65, 0.65, 0.65)
		end
		if text then
			text:SetText("")
			text:Hide()
		end
	end
	volumeSlider:SetScript("OnValueChanged", function(self, value)
		ns.EnsureDB()
		value = math.floor(value + 0.5)
		ns.DB().soundVolume = value
		if ui.soundVolumeValue then
			ui.soundVolumeValue:SetText(tostring(value))
		end
	end)
	ui.soundVolumeSlider = volumeSlider

	S.panel:SetScript("OnShow", function()
		ns.PlayUISound("IG_CHARACTER_INFO_OPEN", 839)
		S.panel:Update()
		ns.SyncStatsTicker()
	end)
	S.panel:SetScript("OnHide", function()
		ns.PlayUISound("IG_CHARACTER_INFO_CLOSE", 840)
		ns.StopStatsTicker()
	end)

	function S.panel:Update()
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

		if S.activeTab == "stats" and ui.statsView == "main" and ui.statSessionJumps then
			local now = GetTime()
			local elapsed = math.max(1, ns.CurrentSessionElapsed())
			local perMin = S.sessionJumps * 60 / elapsed
			local perHr = S.sessionJumps * 3600 / elapsed
			local recent = ns.CountJumpsInWindow(300)
			local recentPerMin = recent / 5
			local best = ns.DB().sessionJumpHigh or 0
			if S.sessionJumps > best then
				best = S.sessionJumps
			end
			local featEarned = ns.CountOwnAchievements()
			local featTotal = #ACHIEVEMENTS
			local lifePlay = ns.LifetimePlayTime()
			local sessionJumpSec = S.sessionJumps * JUMP_ACTIVITY_SEC
			local lifeJumpSec = ns.LifetimeJumpActivityTime()

			if best > 0 then
				local pctOfBest = math.floor((S.sessionJumps / best) * 100 + 0.5)
				ui.statSessionJumps:SetText(string.format("%s (%d%%)", ns.FormatNumber(S.sessionJumps), pctOfBest))
				ui.statSessionHigh:SetText(ns.FormatNumber(best))
			else
				ui.statSessionJumps:SetText(ns.FormatNumber(S.sessionJumps))
				ui.statSessionHigh:SetText("?")
			end
			ui.statSessionTime:SetText(ns.FormatDuration(elapsed))
			ui.statSessionActivity:SetText(ns.FormatJumpIdlePct(sessionJumpSec, elapsed))
			ui.statSessionRate:SetText(string.format("%.1f/min - %.0f/hr", perMin, perHr))
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
			if S.lastAcceptedJumpTime > 0 then
				ui.statLastJump:SetText(ns.FormatDuration(now - S.lastAcceptedJumpTime))
			else
				ui.statLastJump:SetText("?")
			end
		end

		if S.activeTab == "settings" and ui.soundCheck then
			ui.soundCheck:SetChecked(ns.DB().soundsEnabled ~= false)
			if ui.announceCheck then
				ui.announceCheck:SetChecked(not not ns.DB().autoAnnounce)
			end
			if ui.minimapCheck then
				ui.minimapCheck:SetChecked(ns.DB().showMinimapButton ~= false)
			end
			if ui.toastCheck then
				ui.toastCheck:SetChecked(ns.DB().showFeatToasts ~= false)
			end
			ns.UpdateJumpXPBarToggleLabel()
			local vol = ns.ToNumberOr(ns.DB().soundVolume, 100) or 100
			ui.soundVolumeSlider:SetValue(vol)
			ui.soundVolumeValue:SetText(tostring(math.floor(vol + 0.5)))
		end

		if S.activeTab == "guild" then
			ns.UpdateLeaderboard()
		elseif S.activeTab == "achieves" then
			ns.UpdateAchievements()
		end

		ns.UpdateJumpXPBar()
	end

	ns.SetTab("habit", true)
	return S.panel
end

local FEAT_TRACKER_LINE_H = 32
local FEAT_TRACKER_HEADER_H = 25
local FEAT_TRACKER_GAP = 10
local FEAT_TRACKER_BELOW_HEADER = 10

local function GetObjectiveTrackerHost()
	return ObjectiveTrackerFrame or ObjectiveTrackerContainerFrame or WatchFrame
end

local function IsObjectiveTrackerHostCollapsed()
	local host = GetObjectiveTrackerHost()
	if not host then
		return false
	end
	if type(host.IsCollapsed) == "function" then
		local ok, collapsed = pcall(host.IsCollapsed, host)
		if ok then
			return not not collapsed
		end
	end
	if host.isCollapsed ~= nil then
		return not not host.isCollapsed
	end
	if host.collapsed ~= nil then
		return not not host.collapsed
	end
	return false
end

local function HookObjectiveTrackerCollapse()
	local host = GetObjectiveTrackerHost()
	if host and not host._ajhFeatCollapseHooked then
		host._ajhFeatCollapseHooked = true
		if type(host.SetCollapsed) == "function" then
			hooksecurefunc(host, "SetCollapsed", function()
				if ns.UpdateFeatTracker then
					ns.UpdateFeatTracker()
				end
			end)
		end
		if type(host.ToggleCollapsed) == "function" then
			hooksecurefunc(host, "ToggleCollapsed", function()
				if ns.UpdateFeatTracker then
					ns.UpdateFeatTracker()
				end
			end)
		end
	end
	if not ns._ajhFeatCollapseGlobalsHooked then
		ns._ajhFeatCollapseGlobalsHooked = true
		if type(ObjectiveTracker_Collapse) == "function" then
			hooksecurefunc("ObjectiveTracker_Collapse", function()
				if ns.UpdateFeatTracker then
					ns.UpdateFeatTracker()
				end
			end)
		end
		if type(ObjectiveTracker_Expand) == "function" then
			hooksecurefunc("ObjectiveTracker_Expand", function()
				if ns.UpdateFeatTracker then
					ns.UpdateFeatTracker()
				end
			end)
		end
	end
end

local FEAT_TRACKER_HEADER_TEMPLATES = {
	"ObjectiveTrackerModuleHeaderTemplate",
	"ObjectiveTrackerContainerHeaderTemplate",
	"ObjectiveTrackerHeaderTemplate",
}

local function FindQuestTrackerHeaderDonor()
	for _, name in ipairs({
		"QuestObjectiveTracker",
		"CampaignQuestObjectiveTracker",
		"AchievementObjectiveTracker",
	}) do
		local module = _G[name]
		if module and module.Header then
			return module.Header
		end
	end
	local host = GetObjectiveTrackerHost()
	if host and host.modules then
		for _, module in pairs(host.modules) do
			if module and module.Header then
				return module.Header
			end
		end
	end
	return nil
end

local function CopyTextureLook(dst, src)
	if not (dst and src) then
		return false
	end
	local atlas = src.GetAtlas and src:GetAtlas()
	if atlas and atlas ~= "" and dst.SetAtlas then
		dst:SetAtlas(atlas, true)
		return true
	end
	local tex = src.GetTexture and src:GetTexture()
	if tex and dst.SetTexture then
		dst:SetTexture(tex)
		if src.GetTexCoord then
			local l, r, t, b = src:GetTexCoord()
			if l then
				dst:SetTexCoord(l, r, t, b)
			end
		end
		if src.GetVertexColor then
			local r, g, b, a = src:GetVertexColor()
			if r then
				dst:SetVertexColor(r, g, b, a or 1)
			end
		end
		return true
	end
	return false
end

local function SetFeatTrackerHeaderText(header, text)
	if not header then
		return
	end
	if header.Text and header.Text.SetText then
		header.Text:SetText(text)
	elseif header.SetText then
		header:SetText(text)
	elseif header.text and header.text.SetText then
		header.text:SetText(text)
	end
end

local function TrySetAtlas(texture, atlas)
	if not (texture and atlas and texture.SetAtlas) then
		return false
	end
	return pcall(texture.SetAtlas, texture, atlas, true)
end

local function ApplyMinimizeButtonIcon(btn, collapsed)
	if not btn then
		return
	end
	local nt = btn.GetNormalTexture and btn:GetNormalTexture()
	local pt = btn.GetPushedTexture and btn:GetPushedTexture()
	if not nt then
		return
	end

	-- Forever Quests uses Yellow chrome; retail secondary is the fallback.
	local expand = {
		"UI-QuestTrackerButton-Yellow-Expand",
		"ui-questtrackerbutton-yellow-expand",
		"ui-questtrackerbutton-secondary-expand",
	}
	local expandPressed = {
		"UI-QuestTrackerButton-Yellow-Expand-Pressed",
		"ui-questtrackerbutton-yellow-expand-pressed",
		"ui-questtrackerbutton-secondary-expand-pressed",
	}
	local collapse = {
		"UI-QuestTrackerButton-Yellow-Collapse",
		"ui-questtrackerbutton-yellow-collapse",
		"ui-questtrackerbutton-secondary-collapse",
	}
	local collapsePressed = {
		"UI-QuestTrackerButton-Yellow-Collapse-Pressed",
		"ui-questtrackerbutton-yellow-collapse-pressed",
		"ui-questtrackerbutton-secondary-collapse-pressed",
	}

	local normals = collapsed and expand or collapse
	local pushers = collapsed and expandPressed or collapsePressed
	for _, atlas in ipairs(normals) do
		if TrySetAtlas(nt, atlas) then
			break
		end
	end
	if pt then
		for _, atlas in ipairs(pushers) do
			if TrySetAtlas(pt, atlas) then
				break
			end
		end
	end
end

local function SyncFeatTrackerMinimizePosition(header)
	local btn = header and (header.MinimizeButton or header.CollapseButton)
	local donor = FindQuestTrackerHeaderDonor()
	local donorBtn = donor and (donor.MinimizeButton or donor.CollapseButton)
	if not (btn and donorBtn) then
		return
	end
	btn:ClearAllPoints()
	local point, _, relativePoint, x, y = donorBtn:GetPoint(1)
	btn:SetPoint(point or "RIGHT", header, relativePoint or "RIGHT", x or 0, y or 0)
	local w, h = donorBtn:GetSize()
	if w and w > 0 and h and h > 0 then
		btn:SetSize(w, h)
	end
end

local function FixFeatTrackerMinimizeHighlight(header)
	-- Pin hover glow on the glyph; do not move the button here.
	local btn = header and (header.MinimizeButton or header.CollapseButton)
	if not btn then
		return
	end

	local donor = FindQuestTrackerHeaderDonor()
	local donorBtn = donor and (donor.MinimizeButton or donor.CollapseButton)
	local hlSrc = donorBtn and donorBtn.GetHighlightTexture and donorBtn:GetHighlightTexture()
	if hlSrc then
		local atlas = hlSrc.GetAtlas and hlSrc:GetAtlas()
		if atlas and atlas ~= "" and btn.SetHighlightAtlas then
			btn:SetHighlightAtlas(atlas, "ADD")
		elseif hlSrc.GetTexture and hlSrc:GetTexture() then
			local blend = (hlSrc.GetBlendMode and hlSrc:GetBlendMode()) or "ADD"
			btn:SetHighlightTexture(hlSrc:GetTexture(), blend)
		end
	end

	local hl = btn:GetHighlightTexture()
	if not hl then
		return
	end
	local size = 18
	local nt = btn.GetNormalTexture and btn:GetNormalTexture()
	if nt then
		local nw, nh = nt:GetSize()
		if nw and nw > 0 then
			size = math.max(nw, nh or nw) + 6
		end
	end
	hl:ClearAllPoints()
	hl:SetSize(size, size)
	hl:SetPoint("CENTER", btn, "CENTER", 0, 0)
end

local function CreateFeatTrackerHeader(parent)
	-- Prefer Blizzard's real tracker header template (same bar + minimize as Quests).
	for _, tmpl in ipairs(FEAT_TRACKER_HEADER_TEMPLATES) do
		local ok, header = pcall(CreateFrame, "Frame", nil, parent, tmpl)
		if not ok or not header then
			ok, header = pcall(CreateFrame, "Button", nil, parent, tmpl)
		end
		if ok and header then
			header:SetPoint("TOPLEFT", 0, 0)
			header:SetPoint("TOPRIGHT", 0, 0)
			local h = header:GetHeight()
			if not h or h < 10 then
				header:SetHeight(FEAT_TRACKER_HEADER_H)
			end
			SetFeatTrackerHeaderText(header, "Jump Feats")
			header._ajhUsesTemplate = true
			-- Disable Blizzard module toggle (parent isn't a tracker module).
			if header.OnToggle then
				header.OnToggle = function() end
			end
			SyncFeatTrackerMinimizePosition(header)
			ApplyMinimizeButtonIcon(header.MinimizeButton or header.CollapseButton, false)
			FixFeatTrackerMinimizeHighlight(header)
			return header
		end
	end

	-- Fallback: rebuild Quests-style bar from a live donor header.
	local header = CreateFrame("Frame", nil, parent)
	header:SetPoint("TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", 0, 0)
	header:SetHeight(FEAT_TRACKER_HEADER_H)

	local donor = FindQuestTrackerHeaderDonor()
	local donorH = donor and donor:GetHeight()
	if donorH and donorH > 10 then
		header:SetHeight(donorH)
	end

	header.Background = header:CreateTexture(nil, "BACKGROUND")
	header.Background:SetAllPoints()
	local copied = donor and donor.Background and CopyTextureLook(header.Background, donor.Background)
	if not copied then
		-- Approximate Forever Quests header: dark bar + thin gold edges.
		header.Background:SetColorTexture(0.06, 0.06, 0.06, 0.92)
		local top = header:CreateTexture(nil, "BORDER")
		top:SetHeight(1)
		top:SetPoint("TOPLEFT", 0, 0)
		top:SetPoint("TOPRIGHT", 0, 0)
		top:SetColorTexture(0.55, 0.42, 0.18, 0.95)
		local bottom = header:CreateTexture(nil, "BORDER")
		bottom:SetHeight(1)
		bottom:SetPoint("BOTTOMLEFT", 0, 0)
		bottom:SetPoint("BOTTOMRIGHT", 0, 0)
		bottom:SetColorTexture(0.55, 0.42, 0.18, 0.95)
	end

	header.Text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header.Text:SetPoint("LEFT", 4, 0)
	header.Text:SetJustifyH("LEFT")
	header.Text:SetText("Jump Feats")
	header.Text:SetTextColor(1, 0.82, 0)
	if donor and donor.Text then
		local font, size, flags = donor.Text:GetFont()
		if font then
			header.Text:SetFont(font, size or 12, flags)
		end
		local r, g, b = donor.Text:GetTextColor()
		if r then
			header.Text:SetTextColor(r, g, b)
		end
	end

	header.MinimizeButton = CreateFrame("Button", nil, header)
	header.MinimizeButton:SetSize(15, 14)
	header.MinimizeButton:SetPoint("RIGHT", header, "RIGHT", 0, 0)
	local donorBtn = donor and (donor.MinimizeButton or donor.CollapseButton)
	if donorBtn then
		local ntSrc = donorBtn.GetNormalTexture and donorBtn:GetNormalTexture()
		local ptSrc = donorBtn.GetPushedTexture and donorBtn:GetPushedTexture()
		if ntSrc and ntSrc.GetTexture then
			header.MinimizeButton:SetNormalTexture(ntSrc:GetTexture())
			local nt = header.MinimizeButton:GetNormalTexture()
			if nt and ntSrc.GetTexCoord then
				local l, r, t, b = ntSrc:GetTexCoord()
				nt:SetTexCoord(l, r, t, b)
				nt:ClearAllPoints()
				nt:SetAllPoints()
			end
		end
		if ptSrc and ptSrc.GetTexture then
			header.MinimizeButton:SetPushedTexture(ptSrc:GetTexture())
			local pt = header.MinimizeButton:GetPushedTexture()
			if pt and ptSrc.GetTexCoord then
				local l, r, t, b = ptSrc:GetTexCoord()
				pt:SetTexCoord(l, r, t, b)
				pt:ClearAllPoints()
				pt:SetAllPoints()
			end
		end
		local hlSrc = donorBtn.GetHighlightTexture and donorBtn:GetHighlightTexture()
		if hlSrc and hlSrc.GetTexture and hlSrc:GetTexture() then
			local blend = (hlSrc.GetBlendMode and hlSrc:GetBlendMode()) or "ADD"
			header.MinimizeButton:SetHighlightTexture(hlSrc:GetTexture(), blend)
		end
	else
		-- Yellow minus (expanded) / plus (collapsed) fallback.
		local minus = header.MinimizeButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		minus:SetPoint("CENTER", 0, 0)
		minus:SetText("-")
		minus:SetTextColor(1, 0.82, 0)
		header.MinimizeButton.label = minus
	end

	FixFeatTrackerMinimizeHighlight(header)
	return header
end

local function ApplyFeatTrackerCollapsed(frame, collapsed)
	frame.collapsed = not not collapsed
	local header = frame.header
	local btn = header and (header.MinimizeButton or header.CollapseButton)

	-- Header mixin owns the +/- atlas swap (not the button).
	if header and header.SetCollapsed then
		header:SetCollapsed(frame.collapsed)
	end
	-- Forever may use Yellow atlases; force the correct expand/collapse glyph.
	ApplyMinimizeButtonIcon(btn, frame.collapsed)
	if header then
		SyncFeatTrackerMinimizePosition(header)
		FixFeatTrackerMinimizeHighlight(header)
	elseif btn and btn.label then
		btn.label:SetText(frame.collapsed and "+" or "-")
	end

	for _, line in ipairs(frame.lines or {}) do
		if frame.collapsed then
			line:Hide()
		elseif line.featId then
			line:Show()
		end
	end
	local n = 0
	if not frame.collapsed then
		for _, line in ipairs(frame.lines or {}) do
			if line.featId then
				n = n + 1
			end
		end
	end
	local headerH = (header and header:GetHeight()) or FEAT_TRACKER_HEADER_H
	frame:SetHeight(headerH + (frame.collapsed and 0 or (FEAT_TRACKER_BELOW_HEADER + n * FEAT_TRACKER_LINE_H)))
end

local function ConsiderTrackerChild(best, bestBottom, frame, skip)
	if not frame or frame == skip or not frame.GetBottom then
		return best, bestBottom
	end
	if frame.IsShown and not frame:IsShown() then
		return best, bestBottom
	end
	local h = frame.GetHeight and frame:GetHeight() or 0
	if h < 12 then
		return best, bestBottom
	end
	local bottom = frame:GetBottom()
	if not bottom then
		return best, bestBottom
	end
	if not bestBottom or bottom < bestBottom then
		return frame, bottom
	end
	return best, bestBottom
end

function ns.FindFeatTrackerAnchor()
	local host = GetObjectiveTrackerHost()
	if not host then
		return nil, nil
	end
	local skip = ui.featTracker
	local best, bestBottom = nil, nil

	-- Only named objective modules — not the tall tracker container/scroll child
	-- (that bottoms out near the bags and caused the floating gap).
	for _, name in ipairs({
		"QuestObjectiveTracker",
		"CampaignQuestObjectiveTracker",
		"AchievementObjectiveTracker",
		"AdventureObjectiveTracker",
		"BonusObjectiveTracker",
		"WorldQuestObjectiveTracker",
		"ScenarioObjectiveTracker",
		"MonthlyActivitiesObjectiveTracker",
		"UIWidgetObjectiveTracker",
		"ProfessionRecipeTracker",
	}) do
		best, bestBottom = ConsiderTrackerChild(best, bestBottom, _G[name], skip)
	end

	if type(host.modules) == "table" then
		for _, module in pairs(host.modules) do
			if module and (module.Header or module.ContentsFrame or module.BlockTemplate) then
				best, bestBottom = ConsiderTrackerChild(best, bestBottom, module, skip)
			end
		end
	end
	if type(host.GetModules) == "function" then
		local ok, modules = pcall(host.GetModules, host)
		if ok and type(modules) == "table" then
			for _, module in pairs(modules) do
				if module and (module.Header or module.ContentsFrame or module.BlockTemplate) then
					best, bestBottom = ConsiderTrackerChild(best, bestBottom, module, skip)
				end
			end
		end
	end

	-- Last resort: Quests header text region inside the host.
	if not best then
		local header = host.Header
		if header then
			best = header
		end
	end

	return host, best
end

function ns.AnchorFeatTracker()
	local frame = ui.featTracker
	if not frame then
		return
	end

	local host, content = ns.FindFeatTrackerAnchor()
	frame:ClearAllPoints()

	if host then
		frame:SetParent(host)
		local strata = host.GetFrameStrata and host:GetFrameStrata()
		if strata then
			frame:SetFrameStrata(strata)
		end
		frame:SetFrameLevel((host.GetFrameLevel and host:GetFrameLevel() or 0) + 20)
		local w = host:GetWidth() or 235
		if w > 80 then
			frame:SetWidth(w)
		end

		local anchor = content
		if not anchor and host.Header then
			anchor = host.Header
		end
		if anchor then
			frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -FEAT_TRACKER_GAP)
			frame:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -FEAT_TRACKER_GAP)
		else
			frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -36)
			frame:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -36)
		end
	elseif MinimapCluster then
		frame:SetParent(UIParent)
		frame:SetWidth(235)
		frame:SetPoint("TOPRIGHT", MinimapCluster, "BOTTOMRIGHT", -8, -16)
	else
		frame:SetParent(UIParent)
		frame:SetWidth(235)
		frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -220)
	end
end

function ns.EnsureFeatTracker()
	if ui.featTracker then
		ns.UpdateFeatTracker()
		return ui.featTracker
	end

	local frame = CreateFrame("Frame", "AJHFeatTracker", UIParent)
	frame:SetWidth(235)
	frame:SetHeight(FEAT_TRACKER_HEADER_H)
	frame:SetClampedToScreen(true)
	frame:Hide()
	ui.featTracker = frame
	frame.collapsed = false

	local header = CreateFeatTrackerHeader(frame)
	frame.header = header
	local headerH = header:GetHeight() or FEAT_TRACKER_HEADER_H

	local function ToggleCollapse()
		ApplyFeatTrackerCollapsed(frame, not frame.collapsed)
		ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON", 856)
	end
	local minBtn = header.MinimizeButton or header.CollapseButton
	if minBtn then
		minBtn:SetScript("OnClick", ToggleCollapse)
		SyncFeatTrackerMinimizePosition(header)
		ApplyMinimizeButtonIcon(minBtn, false)
		FixFeatTrackerMinimizeHighlight(header)
	end
	if header.SetHighlightTexture then
		header:SetHighlightTexture(nil)
	end
	if header.SetHighlightAtlas then
		pcall(header.SetHighlightAtlas, header, nil)
	end

	frame.lines = {}
	for i = 1, ns.MAX_TRACKED_FEATS or 5 do
		local line = CreateFrame("Button", nil, frame)
		line:SetHeight(FEAT_TRACKER_LINE_H)
		line:SetPoint("TOPLEFT", 0, -(headerH + FEAT_TRACKER_BELOW_HEADER + (i - 1) * FEAT_TRACKER_LINE_H))
		line:SetPoint("TOPRIGHT", 0, -(headerH + FEAT_TRACKER_BELOW_HEADER + (i - 1) * FEAT_TRACKER_LINE_H))
		line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		line:Hide()

		line.icon = line:CreateTexture(nil, "ARTWORK")
		line.icon:SetSize(16, 16)
		line.icon:SetPoint("TOPLEFT", 0, -1)
		line.icon:SetTexture("Interface\\AddOns\\AJH\\AJH-gold-frog")
		if line.icon.SetTexCoord then
			line.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
		end
		if line.icon.SetBlendMode then
			line.icon:SetBlendMode("BLEND")
		end

		-- Quest-title style (yellow), then dashed objective under it.
		line.title = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		line.title:SetPoint("TOPLEFT", 18, 0)
		line.title:SetPoint("TOPRIGHT", 0, 0)
		line.title:SetJustifyH("LEFT")
		line.title:SetTextColor(1, 0.82, 0)
		line.title:SetWordWrap(false)
		if line.title.SetMaxLines then
			line.title:SetMaxLines(1)
		end

		line.obj = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		line.obj:SetPoint("TOPLEFT", line.title, "BOTTOMLEFT", 0, -1)
		line.obj:SetPoint("RIGHT", 0, 0)
		line.obj:SetJustifyH("LEFT")
		line.obj:SetTextColor(0.8, 0.8, 0.8)
		line.obj:SetWordWrap(false)
		if line.obj.SetMaxLines then
			line.obj:SetMaxLines(1)
		end

		line:SetScript("OnClick", function(self, button)
			if not self.featId then
				return
			end
			if button == "RightButton" or IsShiftKeyDown() then
				ns.ToggleFeatTrack(self.featId)
				if S.panel and S.panel:IsShown() and S.activeTab == "achieves" and ns.UpdateAchievements then
					ns.UpdateAchievements()
				end
			elseif ns.TogglePanel then
				ns.EnsureUIBuilt()
				if S.panel and not S.panel:IsShown() then
					ns.TogglePanel()
				end
				if ns.SetTab then
					ns.SetTab("achieves")
				end
			end
		end)
		line:SetScript("OnEnter", function(self)
			if not self.featId then
				return
			end
			local ach = ns.FindAchievement(self.featId)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText(ach and ach.name or self.featId, 1, 0.82, 0)
			if ach and ach.desc then
				GameTooltip:AddLine(ach.desc, 0.9, 0.9, 0.9, true)
			end
			GameTooltip:AddLine("Click to open Feats", 0.65, 0.65, 0.65)
			GameTooltip:AddLine("Shift-click or right-click to untrack", 0.65, 0.65, 0.65)
			GameTooltip:Show()
		end)
		line:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)

		frame.lines[i] = line
	end

	local elapsed = 0
	frame:SetScript("OnUpdate", function(self, dt)
		if not self:IsShown() then
			return
		end
		elapsed = elapsed + dt
		if elapsed < 0.4 then
			return
		end
		elapsed = 0
		ns.AnchorFeatTracker()
	end)

	local reanchor = CreateFrame("Frame")
	reanchor:RegisterEvent("PLAYER_ENTERING_WORLD")
	reanchor:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
	reanchor:RegisterEvent("QUEST_LOG_UPDATE")
	reanchor:SetScript("OnEvent", function()
		ns.AnchorFeatTracker()
		ns.UpdateFeatTracker()
	end)

	local host = GetObjectiveTrackerHost()
	if host then
		if host.HookScript then
			host:HookScript("OnShow", function()
				ns.UpdateFeatTracker()
			end)
			host:HookScript("OnSizeChanged", function()
				ns.AnchorFeatTracker()
				ns.UpdateFeatTracker()
			end)
		end
		if type(host.Update) == "function" then
			hooksecurefunc(host, "Update", function()
				ns.UpdateFeatTracker()
			end)
		end
	end
	HookObjectiveTrackerCollapse()

	ns.UpdateFeatTracker()
	return frame
end

function ns.UpdateFeatTracker()
	if not ui.featTracker then
		return
	end
	HookObjectiveTrackerCollapse()
	local frame = ui.featTracker
	local list = ns.GetTrackedFeatList and ns.GetTrackedFeatList() or {}
	local n = #list
	if n == 0 or IsObjectiveTrackerHostCollapsed() then
		frame:Hide()
		return
	end

	SetFeatTrackerHeaderText(frame.header, "Jump Feats")

	for i, line in ipairs(frame.lines) do
		local ach = list[i]
		if ach then
			line.featId = ach.id
			line.title:SetText(ach.name)
			line.obj:SetText("- " .. (ach.desc or ""))
			if not frame.collapsed then
				line:Show()
			else
				line:Hide()
			end
		else
			line.featId = nil
			line:Hide()
		end
	end

	ApplyFeatTrackerCollapsed(frame, frame.collapsed)
	ns.AnchorFeatTracker()
	frame:Show()
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


minimapDragging = false
function ns.UpdateMinimapButtonPosition()
	if not minimapButton then
		return
	end
	-- Prefer live DB (saved or ephemeral session). Do not invent AJHSaved here.
	local db = ns.DB()
	local pos = 210
	if db and type(db.minimapPos) == "number" then
		pos = db.minimapPos
	end
	local angle = math.rad(pos)
	local radius = (Minimap:GetWidth() / 2) + 5
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function ns.SetMinimapButtonShown(shown)
	ns.EnsureDB()
	local db = ns.DB()
	if not db then
		return
	end
	db.showMinimapButton = not not shown
	if not minimapButton then
		ns.BuildMinimapButton()
		return
	end
	if db.showMinimapButton then
		minimapButton:Show()
		ns.UpdateMinimapButtonPosition()
	else
		minimapButton:Hide()
	end
end

function ns.BuildMinimapButton()
	if minimapButton then
		ns.SetMinimapButtonShown(ns.DB() and ns.DB().showMinimapButton ~= false)
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

	local function applyMinimapAngle(frame, angleDeg)
		local radius = (Minimap:GetWidth() / 2) + 5
		local rad = math.rad(angleDeg)
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
	end

	btn:SetScript("OnDragStart", function(self)
		minimapDragging = true
		GameTooltip:Hide()
		local db = ns.DB()
		self._ajhDragAngle = (db and type(db.minimapPos) == "number" and db.minimapPos) or 210
		self:SetScript("OnUpdate", function(btnFrame)
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale
			local angle = math.deg(math.atan2(cy - my, cx - mx))
			btnFrame._ajhDragAngle = angle
			applyMinimapAngle(btnFrame, angle)
		end)
	end)

	btn:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		local angle = self._ajhDragAngle
		self._ajhDragAngle = nil
		if type(angle) == "number" then
			local db = ns.EnsureDB()
			if db then
				db.minimapPos = angle
			end
			-- Apply the drag angle directly so a stale/default read cannot snap it back.
			applyMinimapAngle(self, angle)
		else
			ns.UpdateMinimapButtonPosition()
		end
		C_Timer.After(0, function()
			minimapDragging = false
		end)
	end)

	minimapButton = btn
	ns.UpdateMinimapButtonPosition()
	if ns.DB() and ns.DB().showMinimapButton == false then
		btn:Hide()
	else
		btn:Show()
	end
	return btn
end
