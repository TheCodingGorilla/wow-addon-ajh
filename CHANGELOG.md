# Changelog

## 1.1.2

**Hotfix — progress wipe on login**

- Fixed Jump Habit progress being reset between sessions
- Account backups no longer get overwritten by an empty login
- On login, AJH restores the best matching backup for your character (including older realm-name variants)
- Added `/ajh recover` to pull progress back from the account backup
- Added `/ajh setprogress <jumps> [xp]` if you still need to restore known totals manually
- Added `/ajh status` to show character and backup totals

If you logged in on 1.1.0/1.1.1 and your jumps showed as 0: update to **1.1.2**, `/reload`, then run `/ajh recover`. If that finds nothing, use `/ajh setprogress <your jumps> <your xp>`.

## 1.1.1

- Persistence hardening (superseded by 1.1.2)

## 1.1.0

- Added a movable on-screen Jump XP bar, with Edit Mode support to place it, resize it, and save or revert your layout
- Added a keybind to open and close Archindula's Jump Habit
- Rebuilt the main panel to feel more like a native Forever window, with clearer tabs and framing
- Refreshed the Habit progress bar so it reads more like a real skill bar, with a clearer blue fill and gold leading edge
- Cleaned up Habit tab layout around level and progress
- Polished the main panel so both sides of the frame look balanced
- Fixed progress percent showing as complete before you actually level
