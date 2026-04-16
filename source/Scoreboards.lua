-- Scoreboards.lua — Leaderboard abstraction for Neutralize on Playdate
-- Local JSON storage in non-Catalog mode; Panic Catalog API in Catalog mode.
-- Both paths populate scoreCache so drawLeaderSection stays synchronous.
--
-- Board IDs (assigned by Panic in the Catalog developer portal):
--   "efficiency"    — score²/max(min,1) efficiency rating (integer)
--   "highest_score" — best single-round score (higher = better)
--
-- !! Replace BOARD_IDS strings below with the IDs Panic assigns. !!

Scoreboards = {}
Scoreboards.__index = Scoreboards

-- ─── Runtime feature detection ──────────────────────────────

local isCatalog = (playdate and playdate.scoreboards ~= nil)

-- ─── Constants ──────────────────────────────────────────────

local MAX_LOCAL_ENTRIES = 100  -- keep top 100 per board
local BOARD_IDS = {
    efficiency    = "efficiency",
    highest_score = "highest_score",
}
local INITIALS_KEY = "lastInitials"

-- ─── In-memory score cache (populated by prefetch) ──────────
-- scoreCache[boardID] = array of { rank, value, playerName, date }
local scoreCache = {}

-- ─── Local storage helpers ─────────────────────────────────

local function localKey(boardID)
    return "scores_" .. boardID
end

local function loadLocalBoard(boardID)
    local data = playdate.datastore.read(localKey(boardID))
    if data and data.entries then
        return data.entries
    end
    return {}
end

local function saveLocalBoard(boardID, entries)
    playdate.datastore.write({ entries = entries }, localKey(boardID))
end

-- Returns a short date string "M/DD" from current wall-clock time
local function todayString()
    local t = playdate.getGMTTime()
    if t then
        return t.month .. "/" .. string.format("%02d", t.day)
    end
    return "—"
end

-- Insert an entry into local board, maintaining sorted order (higher is better)
local function insertLocal(boardID, entry)
    local entries = loadLocalBoard(boardID)

    local inserted = false
    for i, existing in ipairs(entries) do
        if entry.value > existing.value then
            table.insert(entries, i, entry)
            inserted = true
            break
        end
    end

    if not inserted then
        table.insert(entries, entry)
    end

    -- Trim to max
    while #entries > MAX_LOCAL_ENTRIES do
        table.remove(entries)
    end

    saveLocalBoard(boardID, entries)
end

-- ─── Public API ─────────────────────────────────────────────

function Scoreboards.isCatalogMode()
    return isCatalog
end

-- Persist and retrieve the last-used initials string (3 chars)
function Scoreboards.getLastInitials()
    local data = playdate.datastore.read(INITIALS_KEY)
    if data and data.initials and #data.initials == 3 then
        return data.initials
    end
    return "AAA"
end

-- Returns true if the player has explicitly set initials at least once
function Scoreboards.hasSetInitials()
    local data = playdate.datastore.read(INITIALS_KEY)
    return data ~= nil and data.initials ~= nil and #data.initials == 3
end

function Scoreboards.saveLastInitials(initials)
    playdate.datastore.write({ initials = initials }, INITIALS_KEY)
end

-- Submit efficiency score (score² / max(minutes, 1))
-- @param score      number
-- @param timeSecs   number
-- @param initials   string (3 chars)
function Scoreboards.submitEfficiency(score, timeSecs, initials)
    if timeSecs <= 0 or score <= 0 then return end
    initials = initials or Scoreboards.getLastInitials()

    local minutes    = math.max(timeSecs / 60, 1.0)  -- 1-minute floor
    local efficiency = math.floor((score * score) / minutes)
    local entry = {
        value      = efficiency,
        playerName = initials,
        date       = todayString(),
        timestamp  = playdate.getSecondsSinceEpoch(),
        metadata   = { score = score, timeSecs = timeSecs },
    }

    if isCatalog then
        playdate.scoreboards.addScore(BOARD_IDS.efficiency, efficiency, function(status, result)
            if status.code ~= "OK" then
                print("[Scoreboards] addScore efficiency error: " .. (status.message or "unknown"))
            end
        end)
    else
        insertLocal(BOARD_IDS.efficiency, entry)
    end
end

-- Submit a score to the high-score board
-- @param score    number
-- @param initials string (3 chars)
function Scoreboards.submitHighestScore(score, initials)
    if score <= 0 then return end
    initials = initials or Scoreboards.getLastInitials()

    local entry = {
        value      = score,
        playerName = initials,
        date       = todayString(),
        timestamp  = playdate.getSecondsSinceEpoch(),
        metadata   = { score = score },
    }

    if isCatalog then
        playdate.scoreboards.addScore(BOARD_IDS.highest_score, score, function(status, result)
            if status.code ~= "OK" then
                print("[Scoreboards] addScore highest_score error: " .. (status.message or "unknown"))
            end
        end)
    else
        insertLocal(BOARD_IDS.highest_score, entry)
    end
end

-- Populate the in-memory cache for boardID, then call callback(entries).
-- In Catalog mode: async network fetch → normalise → cache.
-- In local mode:   sync datastore read → cache.
-- Call this at startup and after submitting a score.
-- @param boardID  string
-- @param callback function(entries) — called with the top entries (may be empty)
function Scoreboards.prefetch(boardID, callback)
    if isCatalog then
        playdate.scoreboards.getScores(boardID, function(status, result)
            local entries = {}
            if status.code == "OK" and result then
                for i, s in ipairs(result) do
                    entries[i] = {
                        rank       = s.rank or i,
                        value      = s.value or 0,
                        playerName = s.player or "???",
                        date       = "—",  -- Catalog API doesn't return a date
                    }
                end
            else
                print("[Scoreboards] prefetch " .. boardID .. " error: " .. (status and status.message or "unknown"))
            end
            scoreCache[boardID] = entries
            if callback then callback(entries) end
        end)
    else
        local raw     = loadLocalBoard(boardID)
        local entries = {}
        for i, e in ipairs(raw) do
            entries[i] = {
                rank       = i,
                value      = e.value,
                playerName = e.playerName or "???",
                date       = e.date or "—",
            }
        end
        scoreCache[boardID] = entries
        if callback then callback(entries) end
    end
end

-- Retrieve top N scores from in-memory cache (synchronous — call prefetch first).
-- @param boardID string
-- @param limit   number (default 5)
function Scoreboards.getTopScores(boardID, limit)
    limit = limit or 5
    local cached = scoreCache[boardID]
    if not cached then return {} end
    local result = {}
    for i = 1, math.min(limit, #cached) do
        result[i] = cached[i]
    end
    return result
end

-- Async retrieval (used externally if needed; prefer prefetch+getTopScores for UI)
-- @param boardID  string
-- @param limit    number (default 10)
-- @param callback function(status, result)
function Scoreboards.getScores(boardID, limit, callback)
    limit = limit or 10

    if isCatalog then
        playdate.scoreboards.getScores(boardID, function(status, result)
            if callback then callback(status, result) end
        end)
    else
        local entries = loadLocalBoard(boardID)
        local result  = {}
        for i = 1, math.min(limit, #entries) do
            local e = entries[i]
            e.rank  = i
            table.insert(result, e)
        end
        if callback then callback({ code = "OK" }, result) end
    end
end

-- Retrieve personal best from a board
-- @param boardID  string
-- @param callback function(status, result)
function Scoreboards.getPersonalBest(boardID, callback)
    if isCatalog then
        playdate.scoreboards.getPersonalBest(boardID, function(status, result)
            if callback then callback(status, result) end
        end)
    else
        local entries = loadLocalBoard(boardID)
        if callback then
            if entries[1] then
                entries[1].rank = 1
                callback({ code = "OK" }, entries[1])
            else
                callback({ code = "OK" }, nil)
            end
        end
    end
end

-- Format efficiency value (score²/max(min,1)) → raw integer string
function Scoreboards.formatEfficiency(efficiencyVal)
    return tostring(efficiencyVal or 0)
end

-- Format a time value (seconds) as MM:SS.T
function Scoreboards.formatTime(timeSecs)
    if not timeSecs or timeSecs <= 0 then return "—" end
    local m     = math.floor(timeSecs / 60)
    local s     = math.floor(timeSecs % 60)
    local tenth = math.floor((timeSecs * 10) % 10)
    return string.format("%d:%02d.%d", m, s, tenth)
end

-- Clear all local boards (debug only)
function Scoreboards.clearAll()
    for _, boardID in pairs(BOARD_IDS) do
        saveLocalBoard(boardID, {})
        scoreCache[boardID] = nil
    end
end
