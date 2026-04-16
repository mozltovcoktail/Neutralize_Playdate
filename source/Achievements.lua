-- Achievements.lua — Achievement system for Neutralize on Playdate
-- 18 achievements ported from web version.
-- Streak achievements omitted — Playdate has no daily play / calendar system.

Achievements = {}
Achievements.__index = Achievements

-- ─── Definitions ─────────────────────────────────────────────
-- Fields:
--   id          string   unique key (matches web)
--   name        string   short display title
--   desc        string   one-line description
--   cat         string   "progress" | "milestones" | "mastery"
--   check       fn(ctx)  returns true when condition met
--   target      number?  denominator for progress bar (progress-type only)
--   getProgress fn(ctx)? returns current numerator (progress-type only)
--
-- ctx fields supplied by main.lua:
--   totalNeutralized, totalMerges, gamesPlayed  — cumulative lifetime stats
--   score                                        — current game score
--   levelJustBeaten  (0 = no level beaten this check)
--   levelTimeSecs    — seconds taken on the just-beaten level
--   shufflesUsedThisLevel  — rerolls consumed since this level started
--   shufflesUsedThisGame   — rerolls consumed since game started (8 - currentRerolls)
--   boardWasNearlyFull     — true if ≥33 cells were occupied at any point this level

local DEFS = {
    -- ── Progress ──────────────────────────────────────────────
    {
        id = "first_neutralization", name = "Catalyst",
        desc = "Perform your first neutralization",
        cat = "progress",  target = 1,
        getProgress = function(ctx) return ctx.totalNeutralized end,
        check       = function(ctx) return ctx.totalNeutralized >= 1 end,
    },
    {
        id = "first_merge", name = "Fusion",
        desc = "Perform your first merge",
        cat = "progress",  target = 1,
        getProgress = function(ctx) return ctx.totalMerges end,
        check       = function(ctx) return ctx.totalMerges >= 1 end,
    },
    {
        id = "neutralize_50", name = "Half-Life",
        desc = "Neutralize 50 tiles",
        cat = "progress",  target = 50,
        getProgress = function(ctx) return ctx.totalNeutralized end,
        check       = function(ctx) return ctx.totalNeutralized >= 50 end,
    },
    {
        id = "neutralize_500", name = "Critical Mass",
        desc = "Neutralize 500 tiles",
        cat = "progress",  target = 500,
        getProgress = function(ctx) return ctx.totalNeutralized end,
        check       = function(ctx) return ctx.totalNeutralized >= 500 end,
    },
    {
        id = "neutralize_2000", name = "Supercritical",
        desc = "Neutralize 2,000 tiles",
        cat = "progress",  target = 2000,
        getProgress = function(ctx) return ctx.totalNeutralized end,
        check       = function(ctx) return ctx.totalNeutralized >= 2000 end,
    },
    {
        id = "neutralize_5000", name = "Heat Death",
        desc = "Neutralize 5,000 tiles",
        cat = "progress",  target = 5000,
        getProgress = function(ctx) return ctx.totalNeutralized end,
        check       = function(ctx) return ctx.totalNeutralized >= 5000 end,
    },
    {
        id = "games_10", name = "Recurring",
        desc = "Play 10 games",
        cat = "progress",  target = 10,
        getProgress = function(ctx) return ctx.gamesPlayed end,
        check       = function(ctx) return ctx.gamesPlayed >= 10 end,
    },
    {
        id = "games_50", name = "Persistent",
        desc = "Play 50 games",
        cat = "progress",  target = 50,
        getProgress = function(ctx) return ctx.gamesPlayed end,
        check       = function(ctx) return ctx.gamesPlayed >= 50 end,
    },
    {
        id = "games_100", name = "Asymptotic",
        desc = "Play 100 games",
        cat = "progress",  target = 100,
        getProgress = function(ctx) return ctx.gamesPlayed end,
        check       = function(ctx) return ctx.gamesPlayed >= 100 end,
    },

    -- ── Milestones ────────────────────────────────────────────
    {
        id = "score_100", name = "Third Order",
        desc = "Reach a score of 100",
        cat = "milestones",
        check = function(ctx) return ctx.score >= 100 end,
    },
    {
        id = "beat_level_1", name = "First Proof",
        desc = "Complete Level 1",
        cat = "milestones",
        check = function(ctx) return ctx.levelJustBeaten == 1 end,
    },
    {
        id = "beat_level_2", name = "Higher Order",
        desc = "Complete Level 2",
        cat = "milestones",
        check = function(ctx) return ctx.levelJustBeaten == 2 end,
    },
    {
        id = "beat_level_3", name = "Phase Shift",
        desc = "Complete Level 3",
        cat = "milestones",
        check = function(ctx) return ctx.levelJustBeaten == 3 end,
    },
    {
        id = "beat_level_4", name = "Full Neutrality",
        desc = "Complete all four levels",
        cat = "milestones",
        check = function(ctx) return ctx.levelJustBeaten == 4 end,
    },

    -- ── Mastery ───────────────────────────────────────────────
    {
        id = "no_shuffle_win", name = "Deterministic",
        desc = "Clear a level without shuffling",
        cat = "mastery",
        check = function(ctx)
            return ctx.levelJustBeaten > 0 and ctx.shufflesUsedThisLevel == 0
        end,
    },
    {
        id = "speed_demon", name = "Decay Rate",
        desc = "Beat any level in under 60 seconds",
        cat = "mastery",
        check = function(ctx)
            return ctx.levelJustBeaten > 0 and ctx.levelTimeSecs < 60
        end,
    },
    {
        id = "shuffle_master", name = "Entropy",
        desc = "Use all 8 shuffles and still win a level",
        cat = "mastery",
        check = function(ctx)
            return ctx.levelJustBeaten > 0 and ctx.shufflesUsedThisGame >= 8
        end,
    },
    {
        id = "comeback", name = "Equilibrium",
        desc = "Win a level after the board was 90%+ full",
        cat = "mastery",
        check = function(ctx)
            return ctx.levelJustBeaten > 0 and ctx.boardWasNearlyFull
        end,
    },
    {
        id   = "heck_yeah", name = "Heck Yeah",
        desc = "Maximize celebration & joy",
        cat  = "mastery",
        check = function(ctx)
            return (ctx.celebBonusEarned or 0) >= 100
        end,
    },
}

Achievements.TOTAL = #DEFS

-- ─── State ───────────────────────────────────────────────────

local unlocked = {}  -- { [id] = true }

-- ─── API ─────────────────────────────────────────────────────

-- Load persisted unlock table from stats (call after loadStats).
function Achievements.load(savedTable)
    unlocked = savedTable or {}
end

-- Return the raw unlocked table for saving into stats.
function Achievements.getUnlockedTable()
    return unlocked
end

function Achievements.isUnlocked(id)
    return unlocked[id] == true
end

function Achievements.getUnlockedCount()
    local n = 0
    for _ in pairs(unlocked) do n = n + 1 end
    return n
end

-- Check all achievements against ctx. Returns list of newly unlocked defs.
-- Caller is responsible for persisting stats.achievements afterward.
function Achievements.check(ctx)
    local newly = {}
    for _, def in ipairs(DEFS) do
        if not unlocked[def.id] then
            local ok, result = pcall(def.check, ctx)
            if ok and result then
                unlocked[def.id] = true
                table.insert(newly, def)
            end
        end
    end
    return newly
end

-- Returns all defs enriched with isUnlocked, progressText.
-- ctx is optional; if provided, progress-type locked achievements show "X/N".
function Achievements.getAll(ctx)
    local result = {}
    for _, def in ipairs(DEFS) do
        local entry = {
            id        = def.id,
            name      = def.name,
            desc      = def.desc,
            cat       = def.cat,
            isUnlocked = unlocked[def.id] == true,
        }
        -- Progress annotation for locked progress-type achievements (skip target=1 one-offs)
        if not entry.isUnlocked and def.target and def.target > 1 and def.getProgress and ctx then
            local current = math.min(def.getProgress(ctx), def.target)
            entry.progressText = current .. "/" .. def.target
        end
        table.insert(result, entry)
    end
    return result
end

-- Reset all unlocks (called by Reset Stats).
function Achievements.reset()
    unlocked = {}
end
