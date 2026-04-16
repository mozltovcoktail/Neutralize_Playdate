-- Challenges.lua — Challenge system for Neutralize on Playdate
-- 5 static challenge types, each with personal best tracking and leaderboard

Challenges = {}
Challenges.__index = Challenges

-- ─── Challenge Type Definitions ─────────────────────────────

local CHALLENGE_TYPES = {
    {
        id   = "speed_run",
        name = "Speed Run",
        desc = "Beat Level 1 as fast as possible",
        metric      = "time",
        metricLabel = "Time",
        level       = 1,
        noShuffle          = false,
        mustUseAllShuffles = false,
    },
    {
        id   = "efficiency",
        name = "Efficiency",
        desc = "Beat Level 1 in fewest moves",
        metric      = "moves",
        metricLabel = "Moves",
        level       = 1,
        noShuffle          = false,
        mustUseAllShuffles = false,
    },
    {
        id   = "deterministic",
        name = "Deterministic",
        desc = "Beat Level 1 with NO shuffles allowed",
        metric      = "time",
        metricLabel = "Time",
        level       = 1,
        noShuffle          = true,
        mustUseAllShuffles = false,
    },
    {
        id   = "entropy",
        name = "Entropy",
        desc = "Beat Level 1, must use ALL 8 shuffles before clearing",
        metric      = "time",
        metricLabel = "Time",
        level       = 1,
        noShuffle          = false,
        mustUseAllShuffles = true,
    },
    {
        id   = "marathon",
        name = "Marathon",
        desc = "Beat all 4 levels",
        metric      = "time",
        metricLabel = "Time",
        level       = 4,   -- must complete through level 4
        noShuffle          = false,
        mustUseAllShuffles = false,
    },
}

-- ─── Internal state ─────────────────────────────────────────

local state = {
    personalBests = {},   -- { [challengeTypeId] = bestValue }
    attemptCounts = {},   -- { [challengeTypeId] = count }
}

local DATA_KEY = "challenges"

-- ─── Public API ─────────────────────────────────────────────

--- Returns all challenge types.
function Challenges.getTypes()
    return CHALLENGE_TYPES
end

--- Returns a specific challenge type by ID.
function Challenges.getType(id)
    for _, ct in ipairs(CHALLENGE_TYPES) do
        if ct.id == id then
            return ct
        end
    end
    return nil
end

--- Returns the challenge type at index (1-5).
function Challenges.getTypeByIndex(idx)
    return CHALLENGE_TYPES[idx]
end

--- Returns the persisted challenge state table (read-only copy).
function Challenges.getState()
    return {
        personalBests = state.personalBests,
        attemptCounts = state.attemptCounts,
    }
end

--- Records a completed attempt with the given value.
--- Updates personal best if improved, then saves.
function Challenges.recordAttempt(typeId, value)
    state.attemptCounts[typeId] = (state.attemptCounts[typeId] or 0) + 1

    -- Update personal best (lower is always better)
    local current = state.personalBests[typeId]
    if current == nil or value < current then
        state.personalBests[typeId] = value
    end

    Challenges.save()
end

--- Returns true if value would beat the current personal best for this challenge type.
function Challenges.isNewBest(typeId, value)
    local current = state.personalBests[typeId]
    if current == nil then return true end
    return value < current
end

--- Formats a result value for display.
--- Time values become "M:SS", move counts become "N moves".
function Challenges.formatResult(value, challengeType)
    if challengeType == nil then
        return ""
    elseif type(challengeType) == "string" then
        -- Look up by id
        challengeType = Challenges.getType(challengeType)
        if not challengeType then return "" end
    end

    if challengeType.metric == "moves" then
        return tostring(math.floor(value)) .. " moves"
    end

    -- Default: time formatting  M:SS
    local totalSecs = math.floor(value)
    local mins = math.floor(totalSecs / 60)
    local secs = totalSecs % 60
    return string.format("%d:%02d", mins, secs)
end

--- Load persisted challenge state from playdate.datastore.
function Challenges.load()
    local saved = playdate.datastore.read(DATA_KEY)
    if saved then
        state.personalBests = saved.personalBests or {}
        state.attemptCounts = saved.attemptCounts or {}
    end
end

--- Save challenge state to playdate.datastore.
function Challenges.save()
    playdate.datastore.write(state, DATA_KEY)
end
