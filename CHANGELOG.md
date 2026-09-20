# Changelog

## 1.1.2

**Hotfix — progress persistence (update and log in, no commands)**

- Removed the ongoing account backup/restore loop that could overwrite good progress with zeros
- Progress lives in your character save only
- On first login after updating, AJH silently pulls any higher totals still left in the old 1.1.x account file into your character save, then retires that file
- If your jumps were wiped but your guild board still has your score, AJH raises jumps to match automatically
- Never replaces an existing character save table with a blank one
- No slash commands required for recovery

## 1.1.1

**Hotfix — progress wipe on login**

- Fixed Jump Habit progress being reset between sessions
- Empty or partial logins can no longer overwrite a higher saved total
- On login, AJH automatically restores the best matching account backup for your character

Just update and log in. If progress was wiped by 1.1.0, logging in on 1.1.1 should bring it back automatically.

## 1.1.0

- Added a movable on-screen Jump XP bar, with Edit Mode support to place it, resize it, and save or revert your layout
- Added a keybind to open and close Archindula's Jump Habit
- Rebuilt the main panel to feel more like a native Forever window, with clearer tabs and framing
- Refreshed the Habit progress bar so it reads more like a real skill bar, with a clearer blue fill and gold leading edge
- Cleaned up Habit tab layout around level and progress
- Polished the main panel so both sides of the frame look balanced
- Fixed progress percent showing as complete before you actually level
