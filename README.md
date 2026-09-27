# Archindula's Jump Habit (AJH)

World of Warcraft: Forever addon that counts your jumps and levels them with the classic RuneScape XP curve (max level 99).

## Install

Copy the `AJH` folder into:

`World of Warcraft\_classic_beta_\Interface\AddOns\`

Then restart the client or `/reload`.

## Leveling

- Each jump grants **1 XP**
- Levels use the RuneScape formula (13,034,431 XP for level 99)
- Camp Benefit buff grants **2x XP** while active
- Level-ups print a chat message and show a toast

## Panel tabs

- **Habit** — level, XP bar, jump count, announce
- **Stats** — session/lifetime rates; **Levels** for the 1–99 XP table
- **Feats** — location and habit feats (shift-click to track on Objective Tracker)
- **Guild** — shared leaderboard via guild addon messages (members need AJH installed and online)
- **Settings** — announce, Jump XP bar, minimap button, feat toasts, sounds + volume

## Commands

- `/ajh` or `/jumphabit` — open the Jump Habit panel
- `/ajh say` / `/ajh party` / `/ajh guild` — announce level and jumps
- `/ajh sync` — refresh guild leaderboard
- `/ajh clear` — reset jumps and XP
- `/ajh help` — list commands
