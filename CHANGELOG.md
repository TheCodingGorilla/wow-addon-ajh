# Changelog

## 1.3.3

- Twenty more Archindula pride lines for feat toasts / Habit flavor
- Fix: location and situational feats (e.g. Jump in Brill) only unlock on an accepted jump — login / zone /reload no longer grants them

## 1.3.1

- Fix CurseForge package: ship `Bindings.xml` again (Forever auto-loads it by filename; omitting it caused `Couldn't open .../Bindings.xml`). Still not listed in the TOC.

## 1.3.0

**Feats expansion, Habit polish, and Forever-safe account saves**

### Persistence
- Single account SavedVariable: `AJHSaved` (no per-character wipe loop on Forever)
- Never invents an empty `AJHSaved` when the client fails to load it — that was wiping WTF on `/reload`
- Temporary in-memory session if saves miss; merges if SavedVariables appear late
- Login note when Forever's cold-start /reload load miss can show 0 progress

### Feats
- Category cards (2x2): City, Town, **Hostile Territory**, dungeon, raid, plus Habit Milestones, Style, Travel, Social, Collections, Oddities
- Dozens of new location hubs (Sepulcher, Grom'gol, Stonard, and more) and 37+ non-location feats
- Day-streak tracking, announce counters, richer jump context (combat / mount / swim / taxi / etc.)
- Flat gold diamond summary icon; Habit-style progress bars; tooltips for descriptions

### Habit & Stats
- **Stats** tab (Levels nested under Stats)
- Habit dialog XP bar: gold fill, tooltip border, silver tip (clamped)
- Announce dialog for Say / Party / Guild; Jump XP bar toggle in Settings
- Settings gear in the panel content corner

### Jump XP bar (HUD)
- Movable Edit Mode bar restored to **1.2.0** chrome (`UI-HUD-ExperienceBar-*` with classic fallback)
- Fill tinted Habit-dialog yellow; on-bar level / % text

### Other
- Toast fade is alpha-only (no stutter)
- Keybind to open/close the panel
- CurseForge logo / icons: transparent corners outside the rounded frame

Update and `/reload` or log in.

## 1.2.1

**Fix — progress wipe on login /reload**

- Live jumps could sit on unbound `AJHDB` while the companion store snapshotted an empty `AJHAccount`, so Forever saved zeros
- Bind live progress into `AJHAccount` before every mirror write; never write an empty/weaker `AJHStoreDB`
- Logout restores from companion store before deciding whether the session is blank
- `/ajh debug` now reports `store.jumps` and `store.accountMax`

## 1.2.0

**Settings, Statistics, and guild sync**

- **Settings** gear tab (icon-only, last): enable sounds, sound volume (0 mutes), auto announce feats to guild
- **Statistics** nested under Habit (Back returns to Habit main): session jumps/time/rate, recent rate, best session, jumping vs idle %, lifetime jumps/level/activity, feats %, time since last jump
- Statistics refresh live while open; best session and activity times persist per character
- Guild sync sends feat **count** (`Y:jumps:achs:xp`) ΓÇö fixes integer overflow with many location feats; legacy mask capped to 31 bits
- Still ships with companion **AJH Store** ΓÇö enable both addons after updating

## 1.1.7

**Feats UI + Forever progress survival**

- Feats tab organized by category: **City Jumper**, **Town Jumper**, dungeon/raid location feats (Classic only)
- Companion addon **AJH Store** (`AJHStore`) mirrors progress to `AJHStoreDB` so Forever load misses do not wipe jumps on the next logout
- Also mirrors into `SpaceToAcceptDB.AJH` when SpaceToAccept is present (extra safety net)
- Raise-only merge across account / floor / character copies; blank sessions no longer invent zero account tables
- Bind/UI wait until SavedVariables are ready; debug spam is local-dev only (`AJH_Dev`)
- Still does **not** ship HighWater files

**Install note:** enable both **Archindula's Jump Habit** and **AJH Store** in the AddOns list (same zip).

Update, enable AJH Store if prompted, then `/reload` or log in.

## 1.1.6

**Hotfix ΓÇö Jump XP bar layout + CurseForge-safe progress**

- Fixed Jump XP bar size/position resetting on `/reload`
- Hide Jump XP Bar button works again
- Edit Mode no longer commits default drafts over your customized layout
- Disk `.bak` hydrate works on Forever (isolated Lua env) so wiped layouts can be raised back
- **Stopped shipping `AJH_HighWater.lua` in the zip/TOC.** Blank HighWater in every CF update was overwriting players' raised files. Durable watermarks are SavedVariables only (`AJHAccount` / `AJHFloor`); optional runtime cache is `AJH_HighWater.local.lua` (never packaged)
- Width % is measured against the real status/XP bar only

Update and `/reload` or log in.

## 1.1.5

**Hotfix ΓÇö CurseForge update wipe + XP bar layout**

- CurseForge updates replace the AddOns folder (including `AJH_HighWater.lua`), which could leave a blank session that then saved `AJHAccount = nil` over good progress
- On blank loads, AJH now re-reads account SavedVariables / `.bak` from disk before binding or logout-save
- Jump XP bar position/size prefer `userPlaced` / customized layouts when merging saves (no longer lose TOP/50% to defaults)
- Bar layout is kept in the raise-only floor watermarks with jumps/XP/achievements

## 1.1.4

**Hotfix ΓÇö survive Forever SavedVariables load misses**

- **Why wipes happen:** Forever sometimes fails to load SavedVariables into memory even when the WTF files are fine. The addon then runs at 0 jumps, and logout/reload writes that empty memory back over the good files.
- Progress bind waits until `PLAYER_LOGIN` (when name/guid are ready), so an early empty alias cannot overwrite a richer one
- Always keep the richest copy across name, guid, character file, and account file
- Raise-only watermarks (`AJHFloor`, account `__floor`, and `AJH_HighWater` in the addon folder when the client allows writing it) now keep jumps, XP, **and achievements**
- Blank sessions no longer seed zero watermarks over higher totals
- Diagnostics via `/ajh diag` (off by default)
- Update and `/reload` or log in

## 1.1.3

**Hotfix ΓÇö progress now stored where Forever actually loads it**

- **Root cause:** on Forever, per-character SavedVariables often never populate in memory on login even when the character file on disk is correct. Empty sessions then overwrite the good file on logout.
- Progress is now stored in **account** SavedVariables (`AJHAccount`, keyed by character), which this client loads and saves reliably
- Older per-character data is raise-merged into the account store when present
- Update and log in ΓÇö no commands needed

## 1.1.2

**Hotfix ΓÇö progress persistence (update and log in, no commands)**

- Removed the ongoing account backup/restore loop that could overwrite good progress with zeros
- Progress lives in your character save only
- On first login after updating, AJH silently pulls any higher totals still left in the old 1.1.x account file into your character save, then retires that file
- If your jumps were wiped but your guild board still has your score, AJH raises jumps to match automatically
- Never replaces an existing character save table with a blank one
- No slash commands required for recovery

## 1.1.1

**Hotfix ΓÇö progress wipe on login**

- Fixed Jump Habit progress being reset between sessions
- Empty or partial logins can no longer overwrite a higher saved total
- On login, AJH automatically restores the best matching account backup for your character

Just update and log in. If your jumps were wiped by 1.1.0, logging in on 1.1.1 should bring it back automatically.

## 1.1.0

- Added a movable on-screen Jump XP bar, with Edit Mode support to place it, resize it, and save or revert your layout
- Added a keybind to open and close Archindula's Jump Habit
- Rebuilt the main panel to feel more like a native Forever window, with clearer tabs and framing
- Refreshed the Habit progress bar so it reads more like a real skill bar, with a clearer blue fill and gold leading edge
- Cleaned up Habit tab layout around level and progress
- Polished the main panel so both sides of the frame look balanced
- Fixed progress percent showing as complete before you actually level

