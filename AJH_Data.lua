local ADDON_NAME, ns = ...

-- Compact location rows: id, name, faction?, extra match aliases..., optional mapIDs table.
local function loc(id, name, faction, ...)
	local extra = { ... }
	local mapIDs
	if type(extra[#extra]) == "table" then
		mapIDs = table.remove(extra)
	end
	local match = { strlower(name) }
	for i = 1, #extra do
		local m = extra[i]
		if type(m) == "string" and m ~= match[1] then
			match[#match + 1] = strlower(m)
		end
	end
	return { id = id, name = name, faction = faction, match = match, mapIDs = mapIDs }
end

local function dung(id, name, ...)
	return loc(id, name, nil, ...)
end

ns.CITY_LOCATIONS = {
	loc("orgrimmar", "Orgrimmar", "Horde"),
	loc("thunder_bluff", "Thunder Bluff", "Horde"),
	loc("undercity", "Undercity", "Horde", { 90 }),
	loc("stormwind", "Stormwind City", "Alliance", "stormwind"),
	loc("ironforge", "Ironforge", "Alliance"),
	loc("darnassus", "Darnassus", "Alliance"),
}

ns.TOWN_LOCATIONS = {
	loc("brill", "Brill", "Horde"),
	loc("sepulcher", "The Sepulcher", "Horde", "sepulcher"),
	loc("razor_hill", "Razor Hill", "Horde"),
	loc("senjin", "Sen'jin Village", "Horde"),
	loc("bloodhoof", "Bloodhoof Village", "Horde"),
	loc("crossroads", "The Crossroads", "Horde", "crossroads"),
	loc("camp_taurajo", "Camp Taurajo", "Horde"),
	loc("freewind", "Freewind Post", "Horde"),
	loc("sun_rock", "Sun Rock Retreat", "Horde"),
	loc("splintertree", "Splintertree Post", "Horde"),
	loc("zorgtars", "Zoram'gar Outpost", "Horde"),
	loc("tarren_mill", "Tarren Mill", "Horde"),
	loc("hammerfall", "Hammerfall", "Horde"),
	loc("revantusk", "Revantusk Village", "Horde"),
	loc("shadowprey", "Shadowprey Village", "Horde"),
	loc("camp_mojache", "Camp Mojache", "Horde"),
	loc("brackenwall", "Brackenwall Village", "Horde"),
	loc("gromgol", "Grom'gol Base Camp", "Horde", "grom'gol"),
	loc("stonard", "Stonard", "Horde"),
	loc("kargath", "Kargath", "Horde"),
	loc("valormok", "Valormok", "Horde"),
	loc("bloodvenom", "Bloodvenom Post", "Horde"),
	loc("goldshire", "Goldshire", "Alliance"),
	loc("kharanos", "Kharanos", "Alliance"),
	loc("dolanaar", "Dolanaar", "Alliance"),
	loc("sentinel_hill", "Sentinel Hill", "Alliance"),
	loc("lakeshire", "Lakeshire", "Alliance"),
	loc("darkshire", "Darkshire", "Alliance"),
	loc("menethil", "Menethil Harbor", "Alliance"),
	loc("thelsamar", "Thelsamar", "Alliance"),
	loc("refuge_pointe", "Refuge Pointe", "Alliance"),
	loc("southshore", "Southshore", "Alliance"),
	loc("aerie_peak", "Aerie Peak", "Alliance"),
	loc("chillwind", "Chillwind Camp", "Alliance"),
	loc("astranaar", "Astranaar", "Alliance"),
	loc("auberdine", "Auberdine", "Alliance"),
	loc("stonetalon_peak", "Stonetalon Peak", "Alliance"),
	loc("nijels_point", "Nijel's Point", "Alliance"),
	loc("feathermoon", "Feathermoon Stronghold", "Alliance"),
	loc("thalanaar", "Thalanaar", "Alliance"),
	loc("theramore", "Theramore Isle", "Alliance", "theramore"),
	loc("nethergarde", "Nethergarde Keep", "Alliance"),
	loc("morgans_vigil", "Morgan's Vigil", "Alliance"),
	loc("talrendis", "Talrendis Point", "Alliance"),
	loc("talonbranch", "Talonbranch Glade", "Alliance"),
	loc("booty_bay", "Booty Bay", "Neutral"),
	loc("gadgetzan", "Gadgetzan", "Neutral"),
	loc("everlook", "Everlook", "Neutral"),
	loc("ratchet", "Ratchet", "Neutral"),
	loc("light_hope", "Light's Hope Chapel", "Neutral"),
	loc("cenarion_hold", "Cenarion Hold", "Neutral"),
	loc("thorium_point", "Thorium Point", "Neutral"),
	loc("marshals", "Marshal's Refuge", "Neutral"),
	loc("flame_crest", "Flame Crest", "Neutral"),
}

ns.DUNGEON_LOCATIONS = {
	dung("rfc", "Ragefire Chasm"),
	dung("wc", "Wailing Caverns"),
	dung("deadmines", "The Deadmines", "deadmines"),
	dung("sfk", "Shadowfang Keep"),
	dung("stockade", "The Stockade", "stormwind stockade"),
	dung("bfd", "Blackfathom Deeps"),
	dung("gnomeregan", "Gnomeregan"),
	dung("rfk", "Razorfen Kraul"),
	dung("sm_gy", "Scarlet Monastery Graveyard"),
	dung("sm_lib", "Scarlet Monastery Library"),
	dung("sm_arm", "Scarlet Monastery Armory"),
	dung("sm_cath", "Scarlet Monastery Cathedral"),
	dung("sm", "Scarlet Monastery"),
	dung("rfd", "Razorfen Downs"),
	dung("uldaman", "Uldaman"),
	dung("zf", "Zul'Farrak"),
	dung("maraudon", "Maraudon"),
	dung("st", "The Temple of Atal'Hakkar", "sunken temple"),
	dung("brd", "Blackrock Depths"),
	dung("lbrs", "Lower Blackrock Spire", "blackrock spire"),
	dung("ubrs", "Upper Blackrock Spire"),
	dung("dire_maul", "Dire Maul"),
	dung("stratholme", "Stratholme"),
	dung("scholomance", "Scholomance"),
}

ns.RAID_LOCATIONS = {
	dung("mc", "Molten Core"),
	dung("onyxia", "Onyxia's Lair"),
	dung("bwl", "Blackwing Lair"),
	dung("zg", "Zul'Gurub"),
	dung("aq20", "Ruins of Ahn'Qiraj"),
	dung("aq40", "Temple of Ahn'Qiraj", "ahn'qiraj"),
	dung("naxx", "Naxxramas"),
}

ns.FEAT_CATEGORIES = {
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

ns.PRIDE_LINES = {
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
