-- main.lua — Complete Neutralize for Playdate
import "CoreLibs/graphics"
import "CoreLibs/ui"
import "GameEngine"
import "SoundManager"
import "AnimManager"
import "Achievements"
import "VFXConfig"
import "Scoreboards"

local gfx <const> = playdate.graphics

-- ── Feature flags ─────────────────────────────────────────────────────────────
-- Set to true to re-enable initials entry UI and per-player score tagging.
local FEATURE_INITIALS <const> = false

-- Fonts
local _sysFont       = gfx.getSystemFont()
local fontSmall      = _sysFont
local fontRegular    = _sysFont
local fontBold       = gfx.getSystemFont(gfx.font.kVariantBold) or _sysFont
local fontMedium     = _sysFont
local fontTitle      = gfx.font.new("fonts/Rubik-ExtraBold-64")
local fontPauseTitle = gfx.font.new("fonts/Rubik-Bold-24")
local fontPauseItem  = _sysFont

--------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------
local TILE_SIZE = 36
local TILE_RADIUS = 4
local MARGIN = 4
local GRID_SIZE = 6
local BOARD_X = 80
local BOARD_Y = 0
local SHUFFLE_THRESHOLD = 360 -- 1 full rotation
local GAMEOVER_CRANK = 360    -- 1 full rotation to clear
local CELEBRATE_CRANK = 720   -- 2 full rotations to celebrate
local DEBUG_MODE = false      -- set true for dev shortcuts (A/B fill board)

--------------------------------------------------------------
-- HELPER: Format seconds into M:SS string
--------------------------------------------------------------
local function formatTime(secs)
    secs = math.max(0, math.floor(secs))
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%d:%02d", m, s)
    end
end

--------------------------------------------------------------
-- GAME SCENES
--------------------------------------------------------------
local SCENE_TITLE            = "title"
local SCENE_PLAY             = "play"
local SCENE_TUTORIAL         = "tutorial"
local SCENE_GAMEOVER         = "gameover"
local SCENE_LEVELCLEAR       = "levelclear"
local SCENE_MENU             = "menu"
-- removed SCENE_ACHIEVEMENTS

local scene = SCENE_TITLE
local menuStatsY = 240
local titleStatsY = 240
local crankRatchetAccum = 0   -- degrees accumulated for ratchet tick sound
local menuSelector = 1
local menuJustOpened = false
local pauseSnapshot = nil  -- frozen board captured the moment we paused
local pauseFadeTimer = 0   -- frames since pause opened, for fade-in
local introTimer = 0
local levelClearScale = 0  -- 0→1 pop-in animation for level clear dialog
local shuffleReminderVisible = false  -- true = show shuffle tip popup over new game

--------------------------------------------------------------
-- PERSISTENT STATS (playdate.datastore)
--------------------------------------------------------------
local stats = {
    highScore = 0,
    bestEfficiency = 0,
    highestLevel = 1,
    gamesPlayed = 0,
    gamesWithoutShuffle = 0,
    totalNeutralized = 0,
    totalMerges = 0,
    totalMoves = 0,
    scoreHistory = {},
    tutorialSeen = false,
    audioMode = "All",       -- "All" | "SFX only" | "Music only" | "Off"
    achievements = {},       -- { [id] = true } for each unlocked achievement
}

local function loadStats()
    local data = playdate.datastore.read("stats")
    if data then
        for k, v in pairs(data) do stats[k] = v end
    end
    Achievements.load(stats.achievements)
end

local function saveStats()
    playdate.datastore.write(stats, "stats")
end

local function loadGame()
    local data = playdate.datastore.read("game")
    return data
end

local function saveGame(engine)
    local data = engine.state:toTable()
    data.elapsedSecs = getActiveTimeSecs()   -- persist elapsed play time for efficiency
    playdate.datastore.write(data, "game")
end

local function clearSavedGame()
    playdate.datastore.delete("game")
end

--------------------------------------------------------------
-- ENGINE + STATE
--------------------------------------------------------------
local engine = nil
local crankAccumulator = 0
local shuffleAccumulator = 0
local chargeDisplayVal  = 1   -- tile value shown on the rising charge tile
local chargeFlipAccum   = 0   -- crank degrees since last charge tile flip
local isNewHighScore = false
local pendingShuffleNewVal = nil  -- holds new tile value during shuffle animation
local sessionStartTime = 0  -- when current game started (seconds since epoch)
local sessionActiveTime = 0
local isTimerPaused = false

-- Pause-aware level/total timers
local levelElapsedAcc = 0   -- accumulated active seconds for current level
local totalElapsedAcc = 0   -- accumulated active seconds for entire run
local timerLastTick   = 0   -- epoch time of last timer tick

local function pauseTimer()
    if not isTimerPaused then
        sessionActiveTime = playdate.getSecondsSinceEpoch() - sessionStartTime
        -- Freeze level/total accumulators
        local now = playdate.getSecondsSinceEpoch()
        if timerLastTick > 0 then
            local delta = now - timerLastTick
            levelElapsedAcc = levelElapsedAcc + delta
            totalElapsedAcc = totalElapsedAcc + delta
        end
        timerLastTick = 0
        isTimerPaused = true
    end
end

local function resumeTimer()
    if isTimerPaused then
        sessionStartTime = playdate.getSecondsSinceEpoch() - sessionActiveTime
        timerLastTick = playdate.getSecondsSinceEpoch()
        isTimerPaused = false
    end
end

local function resetLevelTimer()
    levelElapsedAcc = 0
    timerLastTick = playdate.getSecondsSinceEpoch()
    isTimerPaused = false
end

local function resetAllTimers()
    levelElapsedAcc = 0
    totalElapsedAcc = 0
    timerLastTick = playdate.getSecondsSinceEpoch()
    isTimerPaused = false
end

local function tickTimers()
    if not isTimerPaused and timerLastTick > 0 then
        local now = playdate.getSecondsSinceEpoch()
        local delta = now - timerLastTick
        timerLastTick = now
        levelElapsedAcc = levelElapsedAcc + delta
        totalElapsedAcc = totalElapsedAcc + delta
    end
end

local function getActiveTimeSecs()
    if isTimerPaused then
        return sessionActiveTime
    else
        return playdate.getSecondsSinceEpoch() - sessionStartTime
    end
end

-- Achievement tracking (per-level, reset on new game / level advance)
local rerollsAtLevelStart = 8    -- currentRerolls snapshot at level start; used to compute shufflesUsedThisLevel
local boardNearlyFull     = false -- true if ≥33 cells occupied at any point this level

-- Achievement toast queue  { {name=string, timer=number} }
local toastQueue     = {}
local TOAST_DURATION = 90   -- frames (3 s at 30fps)

-- Achievements screen scroll state (standalone screen, separate from drawer)
local achScrollOffset  = 0
local achSelectedIdx   = 1
local ACH_VISIBLE_ROWS = 11

math.randomseed(playdate.getSecondsSinceEpoch())
loadStats()
-- Silently re-check lifetime stats to unlock any achievements missed due to crashes or save gaps.
-- Only uses cumulative stats (levelJustBeaten=0 so event-only achievements won't fire).
do
    local catchUp = {
        totalNeutralized      = stats.totalNeutralized   or 0,
        totalMerges           = stats.totalMerges        or 0,
        gamesPlayed           = stats.gamesPlayed        or 0,
        score                 = stats.highScore          or 0,
        levelJustBeaten       = 0,
        levelTimeSecs         = 999,
        shufflesUsedThisLevel = 0,
        shufflesUsedThisGame  = 0,
        boardWasNearlyFull    = false,
    }
    if #Achievements.check(catchUp) > 0 then
        stats.achievements = Achievements.getUnlockedTable()
        playdate.datastore.write(stats, "stats")
    end
end
SoundManager.init()

-- Pre-populate score cache so the drawer has data on first open
Scoreboards.prefetch("efficiency")
Scoreboards.prefetch("highest_score")

-- Apply saved audio mode on startup
local function applyAudioMode(mode)
    SoundManager.setSfxEnabled(mode == "All" or mode == "SFX only")
    SoundManager.setMusicEnabled(mode == "All" or mode == "Music only")
end
applyAudioMode(stats.audioMode or "All")

--------------------------------------------------------------
-- SPLASH SCREEN STATE
--------------------------------------------------------------
local splashTimer = 0
local splashInitialized = false
local splashPromptImage = nil   -- cached prompt row with white outline
local PROMPT_SW  = 2            -- stroke width
local PROMPT_BUF = PROMPT_SW + 2
local SPLASH_DURATION = 120 -- frames (4 seconds at 30fps, more time for floating tiles)
local lastScore = 0  -- for score pop detection
local nextLabelImage = nil  -- unused, kept for reference; replaced with direct draw
local displayScore = 0          -- smooth odometer score (chases s.score)
local scoreLabelTimer = 0       -- frames to show "YES!" label instead of "SCORE"
local sweepStartedForLevelClear = false  -- level-clear sweep gate
local gameOverRevealTimer = -1  -- typed-on game over (-1 = not started)
local gameOverEfficiency = 0    -- efficiency frozen at game-over time
local isNewBestEfficiency = false  -- set at game-over if efficiency is a new best
local crankFrenzyAccum = 0      -- builds up when cranking fast on celebration screen
local frenzyShakeTimer = 0      -- frames of full-screen shake remaining
local comboSustainTimer = 0     -- frames of simultaneous fast-crank + hard-shake
local meltTriggered = false     -- one-shot per celebration session
local celebBonusTimer = 0       -- counts frames inside whirlpool hold for bonus ticks
local celebBonusEarned = 0      -- total bonus points earned this celebration

--------------------------------------------------------------
-- INITIALS ENTRY STATE  [FEATURE_INITIALS]
-- Disabled: set FEATURE_INITIALS = true at the top to restore.
--------------------------------------------------------------
-- if FEATURE_INITIALS:
--   local ALPHA = {}
--   for i = 1, 26 do ALPHA[i] = string.char(64 + i) end
--   ALPHA[27] = " "
--   local ALPHA_LEN = #ALPHA
--   local initialsPhase   = false
--   local initialsIdx     = {1, 1, 1}
--   local initialsCursor  = 1
--   local initialsBlink   = 0
--   local function initialsString()
--       return ALPHA[initialsIdx[1]] .. ALPHA[initialsIdx[2]] .. ALPHA[initialsIdx[3]]
--   end
--   local function loadLastInitials()
--       local s = Scoreboards.getLastInitials()
--       for i = 1, 3 do
--           local ch = string.sub(s, i, i)
--           initialsIdx[i] = 1
--           for j, v in ipairs(ALPHA) do
--               if v == ch then initialsIdx[i] = j; break end
--           end
--       end
--   end
-- end FEATURE_INITIALS

-- Pending score data (always needed for score submission, even without initials UI)
local pendingScore    = 0
local pendingTimeSecs = 0

--------------------------------------------------------------
-- TITLE SCREEN STATE
--------------------------------------------------------------
local titleIdleTimer = 0

--------------------------------------------------------------
-- DRAWER STATE (Unified scrollable document)
--------------------------------------------------------------
local DRAWER_CLOSED_Y   = 231   -- resting position: pull-tab + sliver always visible
local DRAWER_OPEN_Y     = 30    -- fully open: near top of screen, scrollbar handles overflow
local drawerY           = DRAWER_CLOSED_Y
local drawerScrollPx    = 0     -- pixel scroll offset into content document
local drawerScrollAccum = 0     -- accumulator for retract-trigger at top of scroll
local drawerRetracting  = false
-- Layout constants (must match drawUnifiedDrawer)
local DRAWER_STATS_H    = 124   -- height of stats card + header + spacing
local DRAWER_ACH_HDR_H  = 24    -- height of the ACHIEVEMENTS header row
local DRAWER_ACH_ROW_H  = 42    -- height of each achievement row
local DRAWER_SCROLL_SPEED      = 1.5   -- px scrolled per degree of crank
local DRAWER_RETRACT_THRESH    = 60    -- degrees of back-crank to dismiss drawer
local drawerVelocity           = 0     -- momentum for spring bounce
local crankVisualAngle         = 0     -- smoothed crank angle for drawer knob visual
local DRAWER_FRICTION          = 0.82  -- velocity decay per frame
local DRAWER_BOUNCE_SPRING     = 0.3   -- spring force when overshooting open position
local drawerContentH           = 400   -- cached total content height (updated each draw)
-- Peek animation: drawer peeks up periodically on title screen
local drawerPeekTimer    = 0      -- frames since last peek
local drawerPeekPhase    = 0      -- 0=idle, 1=rising, 2=hold, 3=lowering
local drawerPeekOffset   = 0      -- current peek offset (negative = up)
local DRAWER_PEEK_INTERVAL = 600  -- frames between peeks (~20 seconds at 30fps)
local DRAWER_PEEK_RISE     = 30   -- how far the drawer peeks up (px)
local DRAWER_PEEK_HOLD     = 45   -- frames to hold at peak

--------------------------------------------------------------
-- PAUSE MENU DEBUG SUBMENU
--------------------------------------------------------------
local menuDebugOpen      = false
local menuDebugSel       = 1
local menuConfirmRestart = false
local DEBUG_OPTS = {
    "Fill board",
    "Force personal best",
    "Go: Game Over screen",
    "Go: Title screen",
    "← Back",
}

--------------------------------------------------------------
-- TUTORIAL STATE
--------------------------------------------------------------
local tutorialPanel = 1
local TUTORIAL_PANELS = 5

----------------------------------------------------------------
-- SYSTEM MENU
--------------------------------------------------------------
local menu = playdate.getSystemMenu()
menu:addMenuItem("How to Play", function()
    tutorialPanel = 1
    scene = SCENE_TUTORIAL
end)
menu:addOptionsMenuItem("Audio", {"All", "SFX only", "Music only", "Off"},
    stats.audioMode or "All",
    function(value)
        applyAudioMode(value)
        stats.audioMode = value
        saveStats()
    end
)
menu:addMenuItem("Reset Stats", function()
    Achievements.reset()
    stats = {
        highScore = 0, bestEfficiency = 0, highestLevel = 1,
        gamesPlayed = 0, totalNeutralized = 0, totalMerges = 0, totalMoves = 0,
        scoreHistory = {},
        tutorialSeen = stats.tutorialSeen,
        audioMode    = stats.audioMode or "All",
        achievements = {},
    }
    saveStats()
end)

--------------------------------------------------------------
-- START A NEW GAME
--------------------------------------------------------------
local function startNewGame()
    engine = GameEngine.new()
    sessionStartTime = playdate.getSecondsSinceEpoch()
    sessionActiveTime = 0
    resetAllTimers()
    crankAccumulator = 0
    shuffleAccumulator = 0
    chargeDisplayVal  = 1
    chargeFlipAccum   = 0
    isNewHighScore = false
    lastScore = 0
    displayScore = 0
    scoreLabelTimer = 0
    sweepStartedForLevelClear = false
    gameOverRevealTimer = -1

    pendingShuffleNewVal = nil
    rerollsAtLevelStart = 8
    boardNearlyFull = false
    AnimManager.clear()
    AnimManager.addTileIntro(GRID_SIZE)
    SoundManager.play("restart")
    scene = SCENE_PLAY
    -- Show shuffle reminder if player hasn't cranked in 2+ consecutive games
    shuffleReminderVisible = false
    if stats.tutorialSeen and (stats.gamesWithoutShuffle or 0) >= 2 then
        shuffleReminderVisible = true
        stats.gamesWithoutShuffle = 0
        saveStats()
    end
    SoundManager.playBGM()
end

local titleImg = nil

-- Cached image for score-pop animation (avoids per-frame allocation)
local scorePopImg = gfx.image.new(80, 20, gfx.kColorClear)

-- Accessibility flags (refreshed each frame)
local reduceFlashing = false
local deviceFlipped  = false


-- VFX state
local vfxFrame = 0                -- global frame counter for animations
local floatingScores = {}         -- { {x, y, timer, text} }
local neutralizeShakeTimer = 0    -- separate from board wiggle shake
local neutralizeShakeIntensity = 0
local mergePopTiles = {}          -- key "r,c" → {timer, maxScale}
local MAX_TILES = 36              -- 6×6 grid

-- Floater obstacle helper — hoisted out of the per-floater loop so it isn't
-- redefined 12× per frame. Takes the floater table explicitly.
local function checkFloaterObstacle(f, left, right, top, bottom, objCX, objCY)
    if f.x > left - f.size and f.x < right and f.y > top - f.size and f.y < bottom then
        local xCenter = f.x + f.size / 2
        local yCenter = f.y + f.size / 2
        if math.abs(xCenter - objCX) > math.abs(yCenter - objCY) then
            f.dx = -f.dx
            f.x  = f.x + f.dx * 2
        else
            f.dy = -f.dy
            f.y  = f.y + f.dy * 2
        end
    end
end

local function resumeOrNewGame()
    local saved = loadGame()
    if saved and saved.isGameOver ~= true then
        engine = GameEngine.new()
        engine.state:fromTable(saved)
        lastScore = engine.state.score
        -- Restore timer: treat saved game time as already elapsed
        sessionStartTime = playdate.getSecondsSinceEpoch() - (saved.elapsedSecs or 0)
        sessionActiveTime = saved.elapsedSecs or 0
        isTimerPaused = false
        timerLastTick = playdate.getSecondsSinceEpoch()
        scene = SCENE_PLAY
        SoundManager.playBGM()
    else
        startNewGame()
    end
end

--------------------------------------------------------------
-- HELPER: Draw a large "+" cross symbol at center of a rect
-- cx, cy = center pixel; arm = half-length of each arm; t = thickness
--------------------------------------------------------------
local function drawPlus(cx, cy, arm, t)
    local half = math.floor(t / 2)
    -- Vertical bar
    gfx.fillRect(cx - half, cy - arm, t, arm * 2)
    -- Horizontal bar
    gfx.fillRect(cx - arm, cy - half, arm * 2, t)
end

--------------------------------------------------------------
-- HELPER: Draw a large "−" bar symbol at center of a rect
--------------------------------------------------------------
local function drawMinus(cx, cy, arm, t)
    local half = math.floor(t / 2)
    gfx.fillRect(cx - arm, cy - half, arm * 2, t)
end

--------------------------------------------------------------
-- HELPER: Draw a native Playdate button icon using system font Unicode glyphs.
-- Ⓐ (U+24B6) and Ⓑ (U+24B7) are rendered by the Playdate system font as
-- the same circled-letter icons the OS uses in its own menus.
-- cx, cy: center of the glyph.
--------------------------------------------------------------
local GLYPH_A = "Ⓐ"   -- U+24B6
local GLYPH_B = "Ⓑ"   -- U+24B7

-- Cache glyph dimensions once (measured against system font)
local _glyphW, _glyphH

local function getGlyphSize()
    if not _glyphW then
        local prev = gfx.getFont()
        gfx.setFont(gfx.getSystemFont())
        _glyphW, _glyphH = gfx.getTextSize(GLYPH_A)
        gfx.setFont(prev)
    end
    return _glyphW, _glyphH
end

--- Draw a button icon centered at (cx, cy).
local function drawButtonIcon(letter, cx, cy)
    local glyph = (letter == "A") and GLYPH_A or GLYPH_B
    local gw, gh = getGlyphSize()
    local prev = gfx.getFont()
    gfx.setFont(gfx.getSystemFont())
    gfx.setColor(gfx.kColorBlack)
    gfx.drawText(glyph, cx - math.floor(gw / 2), cy - math.floor(gh / 2))
    gfx.setFont(prev)
end

--- Draw a row of button-icon+label segments centered at (cx, textTopY).
--- segments: array of { button="A"|"B", label="text" } or { label="text" } for plain text.
--- Icons are vertically centered on the glyph's own height, aligned with text top.
local function drawButtonHints(cx, textTopY, segments, font)
    font = font or fontSmall
    local gw, gh = getGlyphSize()
    local iconCY = textTopY + math.floor(gh / 2)   -- glyph top = text top
    local IGAP = 3    -- px between icon and its label
    local SEP  = 12   -- px between segments

    -- First pass: measure total width
    local measured = {}
    local totalW = 0
    for i, seg in ipairs(segments) do
        if i > 1 then totalW = totalW + SEP end
        if seg.button then
            gfx.setFont(font)
            local lw = gfx.getTextSize(seg.label)
            local w  = gw + IGAP + lw
            table.insert(measured, { button = seg.button, label = seg.label, iw = gw, lw = lw, w = w })
            totalW = totalW + w
        else
            gfx.setFont(font)
            local lw = gfx.getTextSize(seg.label)
            table.insert(measured, { label = seg.label, lw = lw, w = lw })
            totalW = totalW + lw
        end
    end

    -- Second pass: draw
    local x = cx - math.floor(totalW / 2)
    for i, seg in ipairs(measured) do
        if i > 1 then x = x + SEP end
        if seg.button then
            drawButtonIcon(seg.button, x + math.floor(seg.iw / 2), iconCY)
            x = x + seg.iw + IGAP
            gfx.setFont(font)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawText(seg.label, x, textTopY)
            x = x + seg.lw
        else
            gfx.setFont(font)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawText(seg.label, x, textTopY)
            x = x + seg.lw
        end
    end
end

--------------------------------------------------------------
-- HELPER: Draw a tile value at pixel position
-- Uses large custom-drawn + and - symbols for readability.
-- Magnitude is shown by repeating marks (±1 = one, ±2 = two, etc)
-- Optional `size` param for rendering at different scales.
--------------------------------------------------------------
local function drawTile(v, px, py, size, isFlashing)
    size = size or TILE_SIZE
    local r = math.max(2, math.floor(TILE_RADIUS * (size / TILE_SIZE)))
    local cx = px + size / 2
    local cy = py + size / 2
    local sc = size / TILE_SIZE
    local vfx = VFXConfig.enabled and not reduceFlashing

    -- Symbol scale multiplier based on magnitude
    local symScale = 1.0
    if VFXConfig.enabled and VFXConfig.symbolScale.enabled and type(v) == "number" then
        local mag = math.abs(v)
        symScale = VFXConfig.symbolScale.scales[mag] or 1.0
    end
    local ssc = sc * symScale  -- combined scale for symbols

    if v == 0 then
        -- Solid white background first to avoid transparency
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRoundRect(px, py, size, size, r)

        gfx.setColor(gfx.kColorBlack)
        if not reduceFlashing then
            gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
        end
        gfx.fillRoundRect(px, py, size, size, r)
        gfx.setColor(gfx.kColorBlack)

        -- Dither border (embossed edge) on neutral tiles
        if vfx and VFXConfig.tileDitherBorder.enabled and VFXConfig.tileDitherBorder.applyToNeutral then
            local bw = VFXConfig.tileDitherBorder.width
            gfx.setColor(gfx.kColorWhite)
            gfx.setDitherPattern(1.0 - VFXConfig.tileDitherBorder.density, VFXConfig.getDitherType(VFXConfig.tileDitherBorder.ditherType))
            gfx.drawRoundRect(px + 1, py + 1, size - 2, size - 2, math.max(1, r - 1))
            if bw > 1 then
                gfx.drawRoundRect(px + 2, py + 2, size - 4, size - 4, math.max(1, r - 2))
            end
            gfx.setColor(gfx.kColorBlack)
        end

        -- Circle symbol
        gfx.setColor(gfx.kColorWhite)
        local cRad = math.max(2, math.floor(size * (7.0 / 24.0)))
        gfx.setLineWidth(math.max(2, math.floor(3 * sc)))
        gfx.drawCircleAtPoint(cx, cy, cRad)
        gfx.setLineWidth(2)

        -- Black outline
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(math.max(2, math.floor(3 * sc)))
        gfx.drawRoundRect(px, py, size, size, r)
        gfx.setLineWidth(2)

    elseif type(v) == "number" and v > 0 then
        -- Positive tile: white bg with black + symbol(s)
        if isFlashing then
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRoundRect(px, py, size, size, r)
            gfx.setColor(gfx.kColorWhite)
        else
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRoundRect(px, py, size, size, r)

            -- Dither border (embossed edge) on positive tiles
            if vfx and VFXConfig.tileDitherBorder.enabled and VFXConfig.tileDitherBorder.applyToPositive then
                local bw = VFXConfig.tileDitherBorder.width
                gfx.setDitherPattern(VFXConfig.tileDitherBorder.density, VFXConfig.getDitherType(VFXConfig.tileDitherBorder.ditherType))
                gfx.drawRoundRect(px + 1, py + 1, size - 2, size - 2, math.max(1, r - 1))
                if bw > 1 then
                    gfx.drawRoundRect(px + 2, py + 2, size - 4, size - 4, math.max(1, r - 2))
                end
            end

            gfx.setColor(gfx.kColorBlack)
            local lw = math.max(2, math.floor(3 * sc))
            gfx.setLineWidth(lw)
            gfx.drawRoundRect(px, py, size, size, r)
            gfx.setLineWidth(2)
        end
        local mag = math.abs(v)
        local arm = math.floor(10 * ssc)
        local t = math.max(2, math.floor(4 * ssc))
        local sArm = math.floor(7 * ssc)
        local sT = math.max(2, math.floor(3 * ssc))
        local off = math.floor(7 * ssc)
        local offL = math.floor(8 * ssc)
        if mag == 1 then
            drawPlus(cx, cy, arm, t)
        elseif mag == 2 then
            drawPlus(cx - off, cy, sArm, sT)
            drawPlus(cx + off, cy, sArm, sT)
        elseif mag == 3 then
            -- Diagonal dice-3 layout: bottom-left → center → top-right
            drawPlus(cx - offL, cy + off, math.floor(5 * ssc), sT)
            drawPlus(cx, cy, math.floor(5 * ssc), sT)
            drawPlus(cx + offL, cy - off, math.floor(5 * ssc), sT)
        else
            drawPlus(cx - off, cy - off, math.floor(4 * ssc), sT)
            drawPlus(cx + off, cy - off, math.floor(4 * ssc), sT)
            drawPlus(cx - off, cy + off, math.floor(4 * ssc), sT)
            drawPlus(cx + off, cy + off, math.floor(4 * ssc), sT)
        end

    elseif type(v) == "number" and v < 0 then
        -- Negative tile: black bg with white - symbol(s)
        if isFlashing then
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRoundRect(px, py, size, size, r)

            gfx.setColor(gfx.kColorBlack)
            local lw = math.max(2, math.floor(3 * sc))
            gfx.setLineWidth(lw)
            gfx.drawRoundRect(px, py, size, size, r)
            gfx.setLineWidth(2)
        else
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRoundRect(px, py, size, size, r)

            -- Dither border (embossed edge) on negative tiles
            if vfx and VFXConfig.tileDitherBorder.enabled and VFXConfig.tileDitherBorder.applyToNegative then
                local bw = VFXConfig.tileDitherBorder.width
                gfx.setColor(gfx.kColorWhite)
                gfx.setDitherPattern(1.0 - VFXConfig.tileDitherBorder.density, VFXConfig.getDitherType(VFXConfig.tileDitherBorder.ditherType))
                gfx.drawRoundRect(px + 1, py + 1, size - 2, size - 2, math.max(1, r - 1))
                if bw > 1 then
                    gfx.drawRoundRect(px + 2, py + 2, size - 4, size - 4, math.max(1, r - 2))
                end
            end

            gfx.setColor(gfx.kColorWhite)
        end
        local mag = math.abs(v)
        local arm = math.floor(10 * ssc)
        local t = math.max(1, math.floor(4 * ssc))
        local sArm = math.floor(7 * ssc)
        local sT = math.max(1, math.floor(3 * ssc))
        local off = math.floor(7 * ssc)
        local offL = math.floor(8 * ssc)
        if mag == 1 then
            drawMinus(cx, cy, arm, t)
        elseif mag == 2 then
            drawMinus(cx - off, cy, sArm, sT)
            drawMinus(cx + off, cy, sArm, sT)
        elseif mag == 3 then
            -- Diagonal dice-3 layout: bottom-left → center → top-right
            drawMinus(cx - offL, cy + off, math.floor(5 * ssc), sT)
            drawMinus(cx, cy, math.floor(5 * ssc), sT)
            drawMinus(cx + offL, cy - off, math.floor(5 * ssc), sT)
        else
            drawMinus(cx - off, cy - off, math.floor(4 * ssc), sT)
            drawMinus(cx + off, cy - off, math.floor(4 * ssc), sT)
            drawMinus(cx - off, cy + off, math.floor(4 * ssc), sT)
            drawMinus(cx + off, cy + off, math.floor(4 * ssc), sT)
        end
        gfx.setColor(gfx.kColorBlack)
    end
end

--------------------------------------------------------------
-- HELPER: Efficiency (score² / max(minutes, 1))
--------------------------------------------------------------
local function getEfficiency()
    if not engine then return 0 end
    local elapsed = getActiveTimeSecs()
    if elapsed <= 0 then return 0 end
    local minutes = math.max(elapsed / 60, 1.0)  -- 1-minute floor prevents gaming
    local score = engine.state.score
    if score <= 0 then return 0 end
    return math.floor((score * score) / minutes)
end

--------------------------------------------------------------
-- HELPER: Draw Unified Drawer (Stats / Achievements)
--------------------------------------------------------------
local function drawUnifiedDrawer()

    local drawerX, drawerW = 30, 340
    local sysFont = fontSmall  -- Roobert-11-Medium; NOT getSystemFont() (that returns Asheville)

    -- ── Tab (drawn first so drawer body covers its bottom — folder tab style) ──
    local pullW, pullH = 56, 14
    local pullX = 200 - pullW / 2
    local pullY = drawerY - pullH
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(pullX, pullY, pullW, pullH + 6, 7)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)
    gfx.drawRoundRect(pullX, pullY, pullW, pullH + 6, 7)

    -- Crank hub centered on top edge of tab so circle intersects it
    local cx     = 200
    local cy     = pullY
    local targetAngle = math.rad(playdate.getCrankPosition())
    local angleDiff = targetAngle - crankVisualAngle
    while angleDiff > math.pi do angleDiff = angleDiff - 2 * math.pi end
    while angleDiff < -math.pi do angleDiff = angleDiff + 2 * math.pi end
    crankVisualAngle = crankVisualAngle + angleDiff * 0.4
    local cAngle = crankVisualAngle
    local armLen = 14
    local hx     = cx + math.cos(cAngle) * armLen
    local hy     = cy + math.sin(cAngle) * armLen
    gfx.setLineWidth(1)
    gfx.drawLine(cx, cy, hx, hy)

    -- ── Drawer body (drawn after tab so it covers tab's lower edge) ──
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(drawerX, drawerY, drawerW, 240 - drawerY + 10, 8)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(drawerX, drawerY, drawerW, 240 - drawerY + 10, 8)

    local visibleH = 240 - drawerY
    if visibleH <= 0 then return end
    gfx.setClipRect(drawerX, drawerY, drawerW, visibleH)

    -- Content origin scrolls upward as drawerScrollPx increases
    local pad  = drawerX + 14
    local rpad = drawerX + drawerW - 18  -- leave room for scrollbar
    local y    = drawerY + 10 - math.floor(drawerScrollPx)

    -- ── Section divider helper ────────────────────────────────────
    local firstSection = true
    local function drawSectionHeader(title)
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        if not firstSection then
            gfx.drawLine(drawerX + 8, y, drawerX + drawerW - 8, y)
            y = y + 6
        end
        firstSection = false
        gfx.setFont(sysFont)
        gfx.drawTextAligned("*" .. title .. "*", 200, y, kTextAlignment.center)
        y = y + 16
    end

    -- ── Stats section ─────────────────────────────────────────────
    drawSectionHeader("Stats")

    -- Dot leader helper: draws "LABEL ····· VALUE" with dots filling the gap
    local function drawStatRow(label, value, rowY)
        gfx.setFont(sysFont)
        local labelW = gfx.getTextSize(label)
        local valStr = "*" .. value .. "*"
        local valueW = gfx.getTextSize(valStr)
        gfx.drawText(label, pad + 4, rowY)
        gfx.drawTextAligned(valStr, rpad - 8, rowY, kTextAlignment.right)
        local dotStart = pad + 4 + labelW + 4
        local dotEnd = rpad - 8 - valueW - 4
        local dotX = dotStart
        while dotX < dotEnd do
            gfx.fillRect(dotX, rowY + 5, 1, 1)
            dotX = dotX + 4
        end
    end

    local cardX, cardW = drawerX + 8, drawerW - 16
    local cardY = y
    local sp = 16
    local cardH = sp * 4 + 20

    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(cardX, cardY, cardW, cardH, 4)

    y = cardY + 10
    drawStatRow("High Score",   "" .. (stats.highScore or 0),      y); y = y + sp
    drawStatRow("Best Level",   "" .. (stats.highestLevel or 1),   y); y = y + sp
    drawStatRow("Games Played", "" .. (stats.gamesPlayed or 0),    y); y = y + sp
    drawStatRow("Efficiency",   "" .. (stats.bestEfficiency or 0), y)
    y = cardY + cardH + 10

    -- ── Achievements section ──────────────────────────────────────
    local unlocked = Achievements.getUnlockedCount()
    drawSectionHeader("Achievements  " .. unlocked .. "/" .. Achievements.TOTAL)

    -- ── Achievement rows ─────────────────────────────────────────
    local achCtx = {
        totalNeutralized   = stats.totalNeutralized   or 0,
        totalMerges        = stats.totalMerges        or 0,
        gamesPlayed        = stats.gamesPlayed        or 0,
        score              = stats.highScore          or 0,
        levelJustBeaten    = 0,
        levelTimeSecs      = 999,
        shufflesUsedThisLevel = 0,
        shufflesUsedThisGame  = 0,
        boardWasNearlyFull    = false,
    }
    local allAch = Achievements.getAll(achCtx)

    local textAreaW = drawerW - 28
    local iconW, iconGap = 8, 5
    local nameX   = pad + iconW + iconGap
    local detailW = textAreaW - iconW - iconGap

    local sparkleT = playdate.getCurrentTimeMilliseconds()

    for i, ach in ipairs(allAch) do
        local rowTop = y

        -- Icon: animated sparkle (unlocked) or hollow diamond (locked)
        local sx = pad + 4
        local sy = rowTop + 10  -- vertically centered on name text
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        if ach.isUnlocked then
            local phase = math.floor(sparkleT / 180 + i * 3) % 4
            local showCardinal  = (phase ~= 3)
            local showDiagonal  = (phase == 0 or phase == 2)
            if showCardinal then
                gfx.drawLine(sx, sy - 4, sx, sy + 4)
                gfx.drawLine(sx - 4, sy, sx + 4, sy)
            end
            if showDiagonal then
                gfx.drawLine(sx - 2, sy - 2, sx + 2, sy + 2)
                gfx.drawLine(sx + 2, sy - 2, sx - 2, sy + 2)
            end
            gfx.fillCircleAtPoint(sx, sy, 1)
        else
            gfx.drawLine(sx,     sy - 4, sx + 4, sy)
            gfx.drawLine(sx + 4, sy,     sx,     sy + 4)
            gfx.drawLine(sx,     sy + 4, sx - 4, sy)
            gfx.drawLine(sx - 4, sy,     sx,     sy - 4)
        end

        gfx.setImageDrawMode(gfx.kDrawModeCopy)

        -- Line 1: name (always bold)
        gfx.setFont(sysFont)
        gfx.drawText("*" .. ach.name .. "*", nameX, rowTop + 4)

        -- Line 2: description (normal weight) + progress bar right-aligned
        gfx.setFont(sysFont)
        gfx.drawText(ach.desc, nameX, rowTop + 20)

        if not ach.isUnlocked and ach.progressText then
            local nums = {}
            for n in ach.progressText:gmatch("%d+") do
                table.insert(nums, tonumber(n))
            end
            local cur, tgt = nums[1] or 0, nums[2] or 1
            local pct = math.min(1, cur / tgt)
            -- x/y fraction right-aligned on line 1, same as name
            gfx.drawTextAligned(ach.progressText, rpad, rowTop + 4, kTextAlignment.right)
            -- progress bar on line 3, right-aligned below fraction
            local barW = 50
            local barX = rpad - barW
            local barY = rowTop + 32
            local barH = 3
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRect(barX, barY, barW, barH)
            if pct > 0 then
                gfx.fillRect(barX + 1, barY + 1, math.max(1, math.floor((barW - 2) * pct)), barH - 1)
            end
        end

        local rowBottom = rowTop + 42  -- two lines + bar + padding

        -- Row separator
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        gfx.drawLine(pad, rowBottom, pad + textAreaW, rowBottom)

        y = rowBottom + 2
    end

    -- ── Hall of Fame (Catalog only) ───────────────────────────────
    if Scoreboards.isCatalogMode() then
        -- Renders one board within the Hall of Fame section (no extra divider)
        local function drawHofBoard(label, boardID, formatFn)
            gfx.setFont(sysFont)
            gfx.drawTextAligned(label, 200, y, kTextAlignment.center)
            y = y + 14
            local entries = Scoreboards.getTopScores(boardID, 5)
            if #entries == 0 then
                gfx.drawTextAligned("no scores yet", 200, y, kTextAlignment.center)
                y = y + 14
            else
                for _, e in ipairs(entries) do
                    local name    = e.playerName or "???"
                    local valStr  = formatFn(e.value)
                    local rankStr = e.rank .. "."
                    gfx.drawText(rankStr .. " *" .. name .. "*", pad + 4, y)
                    gfx.drawTextAligned(valStr, rpad, y, kTextAlignment.right)
                    y = y + 14
                end
            end
            y = y + 6
        end

        drawSectionHeader("Hall of Fame")
        drawHofBoard("Efficiency",    "efficiency",    function(v) return Scoreboards.formatEfficiency(v) end)
        drawHofBoard("Highest Score", "highest_score", function(v) return tostring(v) end)
    end

    -- ── Scrollbar ────────────────────────────────────────────────
    -- totalH measured from actual rendered content (dynamic rows)
    local contentTop = drawerY + 10 - math.floor(drawerScrollPx)
    local totalH = y - contentTop + 10
    drawerContentH = totalH  -- cache for scroll limits in updateDrawerState
    local maxScroll = math.max(0, totalH - visibleH)
    local sbH = visibleH - 20
    if maxScroll > 0 and sbH > 0 then
        local sbX    = drawerX + drawerW - 8
        local sbY    = drawerY + 16
        local thumbH = math.max(10, math.floor(sbH * visibleH / totalH))
        local pct    = math.min(1, drawerScrollPx / maxScroll)
        local thumbY = sbY + math.floor((sbH - thumbH) * pct)
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        gfx.drawLine(sbX + 2, sbY, sbX + 2, sbY + sbH)
        gfx.fillRoundRect(sbX, thumbY, 5, thumbH, 2)
    end

    gfx.clearClipRect()

    -- ── Crank circles drawn last — on top of everything ──
    gfx.setLineWidth(1)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(cx, cy, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(cx, cy, 6)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(hx, hy, 4)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(hx, hy, 4)
    gfx.setLineWidth(2)
end

--------------------------------------------------------------
-- UPDATE (called 30fps by Playdate OS)
--------------------------------------------------------------
--------------------------------------------------------------
-- HELPER: Process Drawer Input and State
--------------------------------------------------------------
local function updateDrawerState(crankChange)
    if not playdate.isCrankDocked() then
        if drawerY > DRAWER_OPEN_Y or (drawerY <= DRAWER_OPEN_Y and math.abs(drawerVelocity) > 0.5) then
            -- Drawer not fully open yet: crank raises/lowers it
            if drawerRetracting then
                drawerY = drawerY + math.max(8, math.abs(crankChange) * 0.5)
                drawerVelocity = 0
                if drawerY >= DRAWER_CLOSED_Y then
                    drawerY = DRAWER_CLOSED_Y
                    drawerScrollPx = 0
                    drawerRetracting = false
                end
            else
                -- Apply crank input as velocity impulse
                if math.abs(crankChange) > 1 then
                    drawerVelocity = -crankChange * 0.5
                end
                -- Apply momentum
                drawerY = drawerY + drawerVelocity
                drawerVelocity = drawerVelocity * DRAWER_FRICTION
                -- Spring bounce: push back when overshooting open position
                if drawerY < DRAWER_OPEN_Y then
                    drawerVelocity = drawerVelocity + (DRAWER_OPEN_Y - drawerY) * DRAWER_BOUNCE_SPRING
                end
                if drawerY >= DRAWER_CLOSED_Y then drawerY = DRAWER_CLOSED_Y; drawerVelocity = 0 end
                -- Snap when settled
                if drawerY <= DRAWER_OPEN_Y + 1 and math.abs(drawerVelocity) < 0.5 then
                    drawerY = DRAWER_OPEN_Y
                    drawerVelocity = 0
                end
            end
        else
            -- Fully open: crank scrolls the content document
            if drawerRetracting then
                -- B was pressed while fully open — nudge up so momentum branch takes over
                drawerY = DRAWER_OPEN_Y + 1
            else
                local visibleH  = 240 - DRAWER_OPEN_Y
                local totalH    = drawerContentH
                local maxScroll = math.max(0, totalH - visibleH)

                if crankChange > 0 then
                    -- Clockwise (same direction as opening) → scroll content downward
                    drawerScrollPx    = math.min(maxScroll, drawerScrollPx + crankChange * DRAWER_SCROLL_SPEED)
                    drawerScrollAccum = 0
                elseif crankChange < 0 then
                    -- Counter-clockwise → scroll back up; at top, accumulate to retract
                    if drawerScrollPx > 0 then
                        drawerScrollPx    = math.max(0, drawerScrollPx + crankChange * DRAWER_SCROLL_SPEED)
                        drawerScrollAccum = 0
                    else
                        drawerScrollAccum = drawerScrollAccum + crankChange
                        if drawerScrollAccum < -DRAWER_RETRACT_THRESH then
                            drawerScrollAccum = 0
                            drawerRetracting  = true
                            drawerY           = DRAWER_OPEN_Y + 1
                        end
                    end
                end
            end
        end
    else
        -- Crank docked: auto-close drawer
        drawerY = math.min(drawerY + 6, DRAWER_CLOSED_Y)
        if drawerY >= DRAWER_CLOSED_Y then
            drawerScrollPx = 0
        end
        drawerRetracting = false
        drawerVelocity = 0
    end
end

function playdate.update()
    gfx.clear()
    reduceFlashing = playdate.getReduceFlashing()
    deviceFlipped  = playdate.getFlipped()
    vfxFrame = vfxFrame + 1

    -- Update VFX: floating score labels
    for i = #floatingScores, 1, -1 do
        local fs = floatingScores[i]
        fs.timer = fs.timer - 1
        -- Ease-out deceleration: fast rise then slows
        local life = 1 - (fs.timer / (fs.maxTimer or 24))
        local riseSpeed = (VFXConfig.floatingScore.riseSpeed or 1.2) * math.max(0.2, 1 - life)
        fs.y = fs.y - riseSpeed
        -- Slight arc: drift horizontally
        fs.x = fs.x + (fs.driftX or 0)
        if fs.timer <= 0 then table.remove(floatingScores, i) end
    end

    -- Update VFX: neutralize shake
    if neutralizeShakeTimer > 0 then
        neutralizeShakeTimer = neutralizeShakeTimer - 1
    end

    -- Update VFX: merge pop tiles
    for k, info in pairs(mergePopTiles) do
        info.timer = info.timer + 1
        if info.timer >= (VFXConfig.mergePop.duration or 8) then
            mergePopTiles[k] = nil
        end
    end

    -----------------------------------------
    -----------------------------------------
    -- TITLE SCREEN (Web Splash Style)
    -----------------------------------------
    if scene == SCENE_TITLE then

        if not splashInitialized then
            AnimManager.initFloaters(stats.highestLevel)
            
            -- Cache the exact thick white stroke for the title to preserve 30 FPS
            local splashTitleText = "NEUTRALIZE"
            gfx.setFont(fontTitle)
            local tw, th = gfx.getTextSize(splashTitleText)
            local strokeW = 4
            local buf = strokeW + 2
            -- Use full screen width so the image always fits regardless of font metrics
            local imgW = 400
            local cx = math.floor(imgW / 2)
            splashTitleImage = gfx.image.new(imgW, th + buf*2)
            gfx.pushContext(splashTitleImage)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                for ox = -strokeW, strokeW do
                    for oy = -strokeW, strokeW do
                        if (ox*ox + oy*oy) <= strokeW*strokeW then
                            gfx.drawTextAligned(splashTitleText, cx + ox, buf + oy, kTextAlignment.center)
                        end
                    end
                end
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
                gfx.drawTextAligned(splashTitleText, cx, buf, kTextAlignment.center)
            gfx.popContext()
            gfx.setFont(fontRegular)

            -- Cache prompt hint ("Ⓐ Play") with white outline.
            local phW, phH = 160, 26
            splashPromptImage = gfx.image.new(phW + PROMPT_BUF * 2, phH + PROMPT_BUF * 2, gfx.kColorClear)
            gfx.pushContext(splashPromptImage)
                drawButtonHints(
                    math.floor(phW / 2) + PROMPT_BUF, PROMPT_BUF,
                    { {button = "A", label = "Play"} },
                    fontBold)
            gfx.popContext()

            splashInitialized = true
        end

        AnimManager.update()

        -- Fill white background
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, 0, 400, 240)

        local crankChange = playdate.getCrankChange()

        -- Ratcheting crank sound: tick interval shrinks with speed (faster = more ticks)
        if math.abs(crankChange) > 0.5 then
            crankRatchetAccum = crankRatchetAccum + math.abs(crankChange)
            local tickInterval = math.max(8, 30 - math.abs(crankChange) * 1.5)
            if crankRatchetAccum >= tickInterval then
                crankRatchetAccum = crankRatchetAccum % tickInterval
                SoundManager.playCrankTick()
            end
        else
            crankRatchetAccum = 0
        end

        -- Hero neutral tile coordinates (needed for collision)
        -- Push hero tile up as drawer rises
        local drawerTop = drawerY - 14  -- top of pull-tab
        local heroRestY = 38
        local heroBottom = heroRestY + 50 + 8  -- tile bottom + buffer
        local heroPush = math.max(0, heroBottom - drawerTop)

        local titleIdleTimer = playdate.getCurrentTimeMilliseconds() / 1000
        local bounce = math.sin(titleIdleTimer * 2) * 4
        local cx, cy = 200, heroRestY + bounce - heroPush
        local mainSize = 50
        local px = cx - mainSize/2
        local py = cy - mainSize/2

        -- Precompute obstacle boxes for physics
        local buffer = 4
        local hLeft = px - buffer
        local hRight = px + mainSize + buffer
        local hTop = py - buffer
        local hBottom = py + mainSize + buffer
        
        local statsFloor = drawerY - 14  -- top of pull-tab (14px above drawerY)

        -- Draw floating background tiles
        gfx.setLineWidth(2)    -- Floating tiles (splash) bounce physics is handled in main.lua due to hero tile collision
        for _, f in ipairs(AnimManager.getFloaters()) do
            -- DVD Screensaver Physics
            f.x = f.x + f.dx
            f.y = f.y + f.dy

            -- Momentum spin physics
            f.spin = f.spin or 0
            if crankChange ~= 0 then
                f.spin = crankChange * 1.5
                -- Add rotational english to velocity heading while cranking
                local heading = math.atan(f.dy, f.dx)
                local speed = math.sqrt(f.dx*f.dx + f.dy*f.dy)
                heading = heading + math.rad(crankChange * 0.1)
                f.dx = math.cos(heading) * speed
                f.dy = math.sin(heading) * speed
            else
                f.spin = f.spin * 0.92
            end
            f.angle = (f.angle and f.angle + f.spin or math.random(0, 360)) % 360

            -- Wall collisions
            if f.x < 0 then f.x = 0; f.dx = -f.dx end
            if f.x + f.size > 400 then f.x = 400 - f.size; f.dx = -f.dx end
            if f.y < 0 then f.y = 0; f.dy = -f.dy end
            if f.y + f.size > 240 then f.y = 240 - f.size; f.dy = -f.dy end

            -- Dynamic Stats Floor Collision
            if f.y + f.size > statsFloor then
                f.y = statsFloor - f.size
                if f.dy > 0 then f.dy = -f.dy end
            end

            checkFloaterObstacle(f, hLeft, hRight, hTop, hBottom, cx, cy)

            local fx, fy = math.floor(f.x), math.floor(f.y)
            -- Pre-cache rotated images at 7.5° steps (48 frames) for smooth 1-bit rendering
            -- Each image is rendered at the tile's actual display size — no runtime scaling
            if not f.rotCache then
                local baseImg = gfx.image.new(f.size + 4, f.size + 4)
                gfx.pushContext(baseImg)
                drawTile(f.value, 2, 2, f.size)
                gfx.popContext()
                f.rotCache = {}
                for step = 0, 47 do
                    local angle = step * 7.5
                    if angle == 0 then
                        f.rotCache[step] = baseImg
                    else
                        f.rotCache[step] = baseImg:rotatedImage(angle)
                    end
                end
            end
            -- Snap to nearest 7.5° step
            local step = math.floor((f.angle % 360) / 7.5 + 0.5) % 48
            local rotImg = f.rotCache[step]
            -- VFX: dither halo glow around floating tiles
            if VFXConfig.enabled and VFXConfig.floaters.glow.enabled and not reduceFlashing then
                local gl = VFXConfig.floaters.glow
                gfx.setDitherPattern(gl.density, gfx.image.kDitherTypeBayer8x8)
                local pad = gl.radius
                gfx.fillRoundRect(fx - pad, fy - pad, f.size + 4 + pad * 2, f.size + 4 + pad * 2, 4 + pad)
                gfx.setColor(gfx.kColorBlack)
            end
            local rw, rh = rotImg:getSize()
            rotImg:draw(fx + (f.size + 4) / 2 - rw / 2, fy + (f.size + 4) / 2 - rh / 2)
        end

        drawTile(0, px, py, mainSize)
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        gfx.drawRoundRect(px, py, mainSize, mainSize, math.max(2, math.floor(TILE_RADIUS * (mainSize/TILE_SIZE))))
        gfx.setLineWidth(2)
        -- Cached Title image with white stroke
        local titleY = 88
        if splashTitleImage then
            local _, imgH = splashTitleImage:getSize()
            local buf = 4 + 2
            splashTitleImage:draw(0, titleY - buf)
        end

        -- Bottom Prompts: slow pulse (~2s cycle, mostly visible with brief fade)
        do
            local t = playdate.getCurrentTimeMilliseconds() / 1000
            -- Sine wave: +1 = bright, -1 = dark. Threshold -0.4 gives ~80% on, 20% off.
            local pulse = math.sin(t * math.pi * 0.7)  -- ~1.4s half-period
            if pulse > -0.4 and splashPromptImage then
                local promptY = 182
                local imgW, imgH = splashPromptImage:getSize()
                local imgX = 200 - math.floor(imgW / 2)
                local imgY = promptY - PROMPT_BUF
                -- White outline (stroke)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                for ox = -PROMPT_SW, PROMPT_SW do
                    for oy = -PROMPT_SW, PROMPT_SW do
                        if ox * ox + oy * oy <= PROMPT_SW * PROMPT_SW then
                            splashPromptImage:draw(imgX + ox, imgY + oy)
                        end
                    end
                end
                -- Black text on top
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
                splashPromptImage:draw(imgX, imgY)
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end
        end
        gfx.setColor(gfx.kColorBlack)

        -- Version Number (Top Right)
        local verString = "v" .. (playdate.metadata and playdate.metadata.version or "1.0.0")
        gfx.drawTextAligned(verString, 396, 4, kTextAlignment.right)

        -- Crank drives orbit AND stats drawer
        if not playdate.isCrankDocked() then
            AnimManager.setCrankOrbit(crankChange, cx, cy)
        else
            AnimManager.releaseCrankOrbit()
        end
        updateDrawerState(crankChange)

        -- Peek animation: drawer peeks up periodically when at rest
        if drawerY >= DRAWER_CLOSED_Y and drawerPeekPhase == 0 then
            drawerPeekTimer = drawerPeekTimer + 1
            if drawerPeekTimer >= DRAWER_PEEK_INTERVAL then
                drawerPeekPhase = 1
                drawerPeekTimer = 0
            end
        end
        if drawerPeekPhase == 1 then
            -- Rising with ease-out
            drawerPeekOffset = drawerPeekOffset - 2.5
            if drawerPeekOffset <= -DRAWER_PEEK_RISE then
                drawerPeekOffset = -DRAWER_PEEK_RISE
                drawerPeekPhase = 2
                drawerPeekTimer = 0
            end
        elseif drawerPeekPhase == 2 then
            -- Hold at top with a small bounce
            drawerPeekTimer = drawerPeekTimer + 1
            local bounceT = drawerPeekTimer / DRAWER_PEEK_HOLD
            drawerPeekOffset = -DRAWER_PEEK_RISE + math.sin(bounceT * math.pi) * 4
            if drawerPeekTimer >= DRAWER_PEEK_HOLD then
                drawerPeekPhase = 3
            end
        elseif drawerPeekPhase == 3 then
            -- Lowering back down
            drawerPeekOffset = drawerPeekOffset + 2
            if drawerPeekOffset >= 0 then
                drawerPeekOffset = 0
                drawerPeekPhase = 0
            end
        end
        -- Cancel peek if user starts cranking or opens drawer
        if drawerY < DRAWER_CLOSED_Y or (math.abs(crankChange) > 2 and drawerPeekPhase > 0) then
            drawerPeekPhase = 0
            drawerPeekOffset = 0
            drawerPeekTimer = 0
        end

        -- Apply peek offset to drawer position for drawing
        local savedDrawerY = drawerY
        drawerY = drawerY + drawerPeekOffset
        drawUnifiedDrawer()
        drawerY = savedDrawerY

        -- Input
        if not AnimManager.isTransitioning() then
            -- Intercept inputs when drawer is open
            if drawerY < DRAWER_CLOSED_Y then
                if playdate.buttonJustPressed(playdate.kButtonB) then
                    drawerRetracting = true
                    SoundManager.play("button")
                elseif playdate.buttonJustPressed(playdate.kButtonA) then
                    SoundManager.play("button")
                    AnimManager.startTileWipe(function() resumeOrNewGame() end)
                end
            else
                -- Normal Title Inputs
                if playdate.buttonJustPressed(playdate.kButtonA) then
                    SoundManager.play("button")
                    if not stats.tutorialSeen then
                        tutorialPanel = 1
                        scene = SCENE_TUTORIAL
                    else
                        AnimManager.startTileWipe(function() resumeOrNewGame() end)
                    end
                end
            end
        end

        -- Crank indicator when docked
        if playdate.isCrankDocked() then
            playdate.ui.crankIndicator:update()
        end

        AnimManager.drawTileWipe()
        AnimManager.drawIris()

    -----------------------------------------
    -- TUTORIAL (5 panels)
    -----------------------------------------
    elseif scene == SCENE_TUTORIAL then
        -- Header: title left, page indicator right — single line, no overlap
        gfx.drawText("*HOW TO PLAY*", 12, 10)
        gfx.drawTextAligned(tutorialPanel .. " / " .. TUTORIAL_PANELS, 388, 10, kTextAlignment.right)

        -- Separator line
        gfx.setLineWidth(1)
        gfx.drawLine(12, 30, 388, 30)
        gfx.setLineWidth(2)

        if tutorialPanel == 1 then
            -- Panel 1: The core mechanic — + tile + - tile = 0 tile
            gfx.setLineWidth(2)
            drawTile(1, 100, 60)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(100, 60, TILE_SIZE, TILE_SIZE, TILE_RADIUS)
            gfx.drawTextAligned("+", 146, 70, kTextAlignment.center)
            drawTile(-1, 160, 60)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(160, 60, TILE_SIZE, TILE_SIZE, TILE_RADIUS)
            gfx.drawTextAligned("=", 206, 70, kTextAlignment.center)
            drawTile(0, 220, 60)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(220, 60, TILE_SIZE, TILE_SIZE, TILE_RADIUS)

            gfx.drawTextAligned("Opposites *neutralize*.", 200, 115, kTextAlignment.center)
            gfx.drawTextAligned("Use the *D-pad* to push tiles.", 200, 140, kTextAlignment.center)

        elseif tutorialPanel == 2 then
            -- Panel 2: New tiles spawn after each move
            gfx.setLineWidth(2)
            -- Mini board outline
            local bx, by, bs = 140, 50, 120
            gfx.drawRoundRect(bx, by, bs, bs, 4)
            -- A few tiles on the board
            local mini = 26
            drawTile(1, bx + 8, by + 8, mini)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(bx + 8, by + 8, mini, mini, 3)
            drawTile(-1, bx + 56, by + 48, mini)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(bx + 56, by + 48, mini, mini, 3)
            drawTile(0, bx + 48, by + 8, mini)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(bx + 48, by + 8, mini, mini, 3)
            -- Arrow pointing in from edge with new tile
            drawTile(-1, bx - 36, by + 48, mini)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(bx - 36, by + 48, mini, mini, 3)
            gfx.drawTextAligned(">>", bx - 6, by + 54, kTextAlignment.center)

            gfx.drawTextAligned("After every move, a *new*", 200, 130, kTextAlignment.center)
            gfx.drawTextAligned("*tile* appears on the edge.", 200, 150, kTextAlignment.center)

        elseif tutorialPanel == 3 then
            -- Panel 3: 0 tiles don't move
            drawTile(0, 182, 65)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(182, 65, TILE_SIZE, TILE_SIZE, TILE_RADIUS)

            -- Drawn X marks + directional arrows showing all 4 directions blocked
            gfx.setColor(gfx.kColorBlack)
            gfx.setLineWidth(2)
            local function drawXMark(cx, cy)
                local s = 5
                gfx.drawLine(cx - s, cy - s, cx + s, cy + s)
                gfx.drawLine(cx + s, cy - s, cx - s, cy + s)
            end
            local function drawArrowHead(cx, cy, dx, dy)
                -- Small arrowhead pointing in direction (dx, dy); tip at (cx, cy)
                local s = 6
                local px, py = -dy, dx  -- perpendicular
                gfx.drawLine(cx, cy, cx - dx * s + px * s, cy - dy * s + py * s)
                gfx.drawLine(cx, cy, cx - dx * s - px * s, cy - dy * s - py * s)
            end
            local tcx, tcy = 200, 83  -- tile center
            local gap = 20            -- distance from tile edge to mark center
            -- Left
            local lx = 182 - gap
            drawXMark(lx, tcy)
            drawArrowHead(lx + 6, tcy, 1, 0)
            gfx.drawLine(lx - 14, tcy, lx - 5, tcy)
            -- Right
            local rx = 218 + gap
            drawXMark(rx, tcy)
            drawArrowHead(rx - 6, tcy, -1, 0)
            gfx.drawLine(rx + 14, tcy, rx + 5, tcy)
            -- Top
            local ty = 65 - gap
            drawXMark(tcx, ty)
            drawArrowHead(tcx, ty + 6, 0, 1)
            gfx.drawLine(tcx, ty - 14, tcx, ty - 5)
            -- Bottom
            local by = 101 + gap
            drawXMark(tcx, by)
            drawArrowHead(tcx, by - 6, 0, -1)
            gfx.drawLine(tcx, by + 14, tcx, by + 5)
            gfx.setLineWidth(2)

            gfx.drawTextAligned("*0* tiles are *locked*.", 200, 138, kTextAlignment.center)
            gfx.drawTextAligned("They never move.", 200, 158, kTextAlignment.center)

        elseif tutorialPanel == 4 then
            -- Panel 4: Fill the board with 0 tiles to clear — full 6×6 grid
            local mini = 20
            local gap  = 2
            local gridW = 6 * mini + 5 * gap   -- 130px
            local startX = math.floor((400 - gridW) / 2)  -- 135, centered
            local startY = 37
            for i = 0, 5 do
                for j = 0, 5 do
                    drawTile(0, startX + i * (mini + gap), startY + j * (mini + gap))
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawRoundRect(startX + i * (mini + gap), startY + j * (mini + gap), mini, mini, 2)
                end
            end
            gfx.drawTextAligned("*Fill the board* with *0* tiles", 200, 175, kTextAlignment.center)
            gfx.drawTextAligned("to clear each level.", 200, 195, kTextAlignment.center)

        elseif tutorialPanel == 5 then
            -- Panel 5: Crank to shuffle
            gfx.drawTextAligned("*Crank* to shuffle", 200, 65, kTextAlignment.center)
            gfx.drawTextAligned("your next tile.", 200, 90, kTextAlignment.center)
            gfx.drawTextAligned("You get *8* shuffles per game.", 200, 125, kTextAlignment.center)
            playdate.ui.crankIndicator:update()
        end

        -- Footer nav hint — single line at bottom, no overlap
        gfx.drawTextAligned("D-pad / A: Next    B: Skip", 200, 220, kTextAlignment.center)

        -- Crank navigation through panels
        if not playdate.isCrankDocked() then
            local crankChange = playdate.getCrankChange()
            if math.abs(crankChange) > 3 then
                tutorialCrankAccum = (tutorialCrankAccum or 0) + crankChange
            end
            if tutorialCrankAccum and math.abs(tutorialCrankAccum) >= 45 then
                if tutorialCrankAccum > 0 and tutorialPanel < TUTORIAL_PANELS then
                    tutorialPanel = tutorialPanel + 1
                elseif tutorialCrankAccum < 0 and tutorialPanel > 1 then
                    tutorialPanel = tutorialPanel - 1
                end
                tutorialCrankAccum = 0
            end
        end

        -- D-pad left/right navigates panels
        if playdate.buttonJustPressed(playdate.kButtonRight) or playdate.buttonJustPressed(playdate.kButtonA) then
            SoundManager.play("button")
            if tutorialPanel < TUTORIAL_PANELS then
                tutorialPanel = tutorialPanel + 1
            else
                stats.tutorialSeen = true
                saveStats()
                resumeOrNewGame()
            end
        elseif playdate.buttonJustPressed(playdate.kButtonLeft) then
            SoundManager.play("button")
            if tutorialPanel > 1 then
                tutorialPanel = tutorialPanel - 1
            end
        elseif playdate.buttonJustPressed(playdate.kButtonB) then
            SoundManager.play("button")
            stats.tutorialSeen = true
            saveStats()
            resumeOrNewGame()
        end

    -----------------------------------------
    -- GAMEPLAY
    -----------------------------------------
    elseif scene == SCENE_PLAY or scene == SCENE_MENU or scene == SCENE_ACHIEVEMENTS then
        local s = engine.state
        local wasShuffling = AnimManager.isShuffling()
        AnimManager.update()
        -- Shuffle SFX: tone on each flip, final sting on completion
        local flipVal = AnimManager.getShuffleFlipVal()
        if flipVal ~= nil then
            SoundManager.playReroll(flipVal)
        elseif wasShuffling and not AnimManager.isShuffling() and pendingShuffleNewVal ~= nil then
            SoundManager.playReroll(pendingShuffleNewVal)
        end

        local justPaused = false

        if scene == SCENE_PLAY then
            -- Odometer: displayScore chases s.score each frame
            if displayScore < s.score then
                displayScore = math.min(s.score, displayScore + math.max(1, math.ceil((s.score - displayScore) * 0.4)))
            elseif displayScore > s.score then
                displayScore = s.score
            end
            -- "YES!" label countdown
            if scoreLabelTimer > 0 then scoreLabelTimer = scoreLabelTimer - 1 end

            -- D-pad input (blocked during slide animations)
            local result = nil
            local swipeDX, swipeDY = 0, 0
            if not AnimManager.isSliding() and not AnimManager.isTransitioning() and not shuffleReminderVisible then
                if playdate.buttonJustPressed(playdate.kButtonUp) then
                swipeDX, swipeDY = 0, -1; result = engine:swipe(0, -1)
            elseif playdate.buttonJustPressed(playdate.kButtonDown) then
                swipeDX, swipeDY = 0, 1; result = engine:swipe(0, 1)
            elseif playdate.buttonJustPressed(playdate.kButtonLeft) then
                swipeDX, swipeDY = -1, 0; result = engine:swipe(-1, 0)
            elseif playdate.buttonJustPressed(playdate.kButtonRight) then
                swipeDX, swipeDY = 1, 0; result = engine:swipe(1, 0)
            end
        end

        if result then
            if result.moved then
                -- Feed animation descriptors to AnimManager
                local maxNeutMag = 0
                for _, anim in ipairs(result.anims) do
                    if anim.type == "slide" then
                        AnimManager.addSlide(anim.fromR, anim.fromC, anim.toR, anim.toC)
                    elseif anim.type == "spawn" then
                        AnimManager.addSpawnPop(anim.r, anim.c)
                    elseif anim.type == "neutralize" then
                        AnimManager.addFlash(anim.r, anim.c)
                        AnimManager.addNeutralPop(anim.r, anim.c)
                        -- Particle burst at neutralize cell center
                        local npx = BOARD_X + (anim.c - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2) + TILE_SIZE / 2
                        local npy = BOARD_Y + (anim.r - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2) + TILE_SIZE / 2
                        AnimManager.addParticles(npx, npy)
                    elseif anim.type == "merge" then
                        AnimManager.addFlash(anim.r, anim.c)
                        AnimManager.addNeutralPop(anim.r, anim.c)
                        local mpx = BOARD_X + (anim.c - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2) + TILE_SIZE / 2
                        local mpy = BOARD_Y + (anim.r - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2) + TILE_SIZE / 2
                        AnimManager.addParticles(mpx, mpy)
                    end
                end


                -- Score pop detection
                if s.score ~= lastScore then
                    AnimManager.addScorePop()
                    lastScore = s.score
                end

                -- Pick the most impactful SFX: neutralize > merge > move
                if result.neutralized > 0 then
                    SoundManager.play("neutralize")
                elseif result.merged > 0 then
                    SoundManager.play("mergePartial")
                else
                    SoundManager.play("move")
                end
                saveGame(engine)

                -- Track board density for "comeback" achievement
                local filledCount = MAX_TILES - #engine:getEmptyCells()
                if filledCount >= 33 then boardNearlyFull = true end

                -- Check progress-based achievements after each move
                local progressCtx = {
                    totalNeutralized   = stats.totalNeutralized + s.sessionNeutralized,
                    totalMerges        = (stats.totalMerges or 0) + s.sessionMerged,
                    gamesPlayed        = stats.gamesPlayed,
                    score              = s.score,
                    levelJustBeaten    = 0,
                    levelTimeSecs      = 0,
                    shufflesUsedThisLevel = 0,
                    shufflesUsedThisGame  = 0,
                    boardWasNearlyFull    = false,
                }
                local newly = Achievements.check(progressCtx)
                if #newly > 0 then
                    stats.achievements = Achievements.getUnlockedTable()
                    saveStats()
                    for _, def in ipairs(newly) do
                        table.insert(toastQueue, { name = def.name, timer = TOAST_DURATION })
                    end
                end
            else
                -- Pressed d-pad but nothing moved → wiggle tiles
                SoundManager.play("shake")
                AnimManager.addWiggle(GRID_SIZE)
            end
        end

        -- DEBUG CONTROLS
        if DEBUG_MODE then
            -- B: fill board with alternating tiles (force game over)
            if playdate.buttonJustPressed(playdate.kButtonB) then
                for r = 1, GRID_SIZE do
                    for c = 1, GRID_SIZE do
                        if s.grid[r][c] == nil then
                            s.grid[r][c] = ((r + c) % 2 == 0) and 1 or 1 -- same sign = no moves
                        end
                    end
                end
                if not engine:canAnyMove() then
                    s.isGameOver = true
                end
            end
            -- A: set 35 neutrals (force celebration)
            if playdate.buttonJustPressed(playdate.kButtonA) then
                local count = 0
                for r = 1, GRID_SIZE do
                    for c = 1, GRID_SIZE do
                        if count < 35 then
                            s.grid[r][c] = 0
                            count = count + 1
                        else
                            s.grid[r][c] = nil
                        end
                    end
                end
                s.isSpecialSequenceActive = true
            end
        end

        -- B: retract drawer (initials editor disabled; see FEATURE_INITIALS)
        -- FEATURE_INITIALS: swap the two `if` lines below — the commented block
        -- opens the initials editor when the drawer is fully open.
        -- if drawerY <= DRAWER_OPEN_Y + 4 and playdate.buttonJustPressed(playdate.kButtonB) then
        --     loadLastInitials(); initialsCursor=1; initialsBlink=0; initialsPhase=true
        --     SoundManager.play("button")
        -- elseif drawerY < DRAWER_CLOSED_Y and playdate.buttonJustPressed(playdate.kButtonB) then
        if not shuffleReminderVisible and drawerY < DRAWER_CLOSED_Y and playdate.buttonJustPressed(playdate.kButtonB) then
            drawerRetracting = true
            SoundManager.play("button")
        -- Menu invocation
        elseif not shuffleReminderVisible and not s.isGameOver and not s.isSpecialSequenceActive and not AnimManager.isTransitioning() and playdate.buttonJustPressed(playdate.kButtonA) then
            SoundManager.play("button")
            pauseTimer()
            pauseSnapshot = playdate.graphics.getDisplayImage()  -- freeze the board
            pauseFadeTimer = 0
            scene = SCENE_MENU
            menuSelector        = 1
            menuDebugOpen       = false
            menuDebugSel        = 1
            menuConfirmRestart  = false
            menuStatsY = 240
            menuJustOpened = true
            drawerY = DRAWER_CLOSED_Y  -- drawer resets to peek position when pausing
            crankVisualAngle = math.rad(playdate.getCrankPosition())  -- snap arm to current angle
            drawerScrollPx = 0
            drawerRetracting = false
            drawerVelocity = 0
        end

        -- Crank shuffle logic
        if not shuffleReminderVisible and not s.isGameOver and not s.isSpecialSequenceActive then
            -- Poll: if shuffle animation just completed, apply the new value
            if pendingShuffleNewVal and not AnimManager.isShuffling() then
                s.nextTileValue = pendingShuffleNewVal
                pendingShuffleNewVal = nil
                saveGame(engine)
            end

            -- Block cranking during animation or cooldown
            if not AnimManager.isShuffling() and not AnimManager.isShuffleCooldown() then
                if not playdate.isCrankDocked() then
                    local crankChange = playdate.getCrankChange()
                    if crankChange > 3 then
                        -- Forward crank: build charge
                        if shuffleAccumulator == 0 then
                            -- Pick the charge tile value once at the start
                            local ok, v = pcall(function() return engine:chooseRandomTileValue() end)
                            if ok and v then chargeDisplayVal = v end
                        end
                        shuffleAccumulator = shuffleAccumulator + crankChange
                        -- Ratchet tick: speeds up as the crank spins faster
                        crankRatchetAccum = crankRatchetAccum + crankChange
                        local tickInterval = math.max(8, 30 - crankChange * 1.5)
                        if crankRatchetAccum >= tickInterval then
                            crankRatchetAccum = crankRatchetAccum % tickInterval
                            SoundManager.playCrankTick()
                        end
                    elseif crankChange < -3 then
                        -- Reverse crank: snap back
                        shuffleAccumulator = 0
                        chargeFlipAccum    = 0
                        crankRatchetAccum  = 0
                    else
                        crankRatchetAccum = 0
                    end
                    -- Near-zero / idle: hold position

                    if shuffleAccumulator >= SHUFFLE_THRESHOLD and s.currentRerolls > 0 then
                        s.currentRerolls = s.currentRerolls - 1
                        local oldVal = s.nextTileValue
                        local ok, newVal = pcall(function() return engine:chooseRandomTileValue(-oldVal) end)
                        if ok and newVal ~= nil then
                            pendingShuffleNewVal = newVal
                        else
                            pendingShuffleNewVal = oldVal
                        end

                        AnimManager.startShuffle(oldVal, pendingShuffleNewVal, engine)
                        shuffleAccumulator = 0
                        chargeFlipAccum    = 0
                    end

                    if s.currentRerolls == 0 then
                        shuffleAccumulator = 0
                        chargeFlipAccum    = 0
                    end
                end
            else
                -- Drain crank input during anim/cooldown so it doesn't accumulate
                playdate.getCrankChange()
                shuffleAccumulator = 0
                chargeFlipAccum    = 0
            end
        end

        -- Check for transitions
        if s.isGameOver and not AnimManager.isTransitioning() then
            crankAccumulator = 0
            isNewHighScore = s.score > stats.highScore
            -- Efficiency: score² / max(minutes, 1) — saved every game.
            local eff = getEfficiency()
            if eff > (stats.bestEfficiency or 0) then
                stats.bestEfficiency = eff
                isNewBestEfficiency = true
            end
            gameOverEfficiency = eff
            -- Update stats
            stats.totalMoves = stats.totalMoves + s.moveCounter
            stats.totalNeutralized = stats.totalNeutralized + s.sessionNeutralized
            stats.totalMerges = (stats.totalMerges or 0) + s.sessionMerged
            gameOverEfficiency = eff
            if s.score > stats.highScore then stats.highScore = s.score end
            if s.level > stats.highestLevel then stats.highestLevel = s.level end
            stats.gamesPlayed = stats.gamesPlayed + 1
            if (8 - s.currentRerolls) == 0 then
                stats.gamesWithoutShuffle = (stats.gamesWithoutShuffle or 0) + 1
            else
                stats.gamesWithoutShuffle = 0
            end
            if not stats.scoreHistory then stats.scoreHistory = {} end
            table.insert(stats.scoreHistory, s.score)
            while #stats.scoreHistory > 100 do table.remove(stats.scoreHistory, 1) end

            -- Check games-played and score achievements on game over
            local gameOverCtx = {
                totalNeutralized      = stats.totalNeutralized,
                totalMerges           = stats.totalMerges or 0,
                gamesPlayed           = stats.gamesPlayed,
                score                 = stats.highScore,
                levelJustBeaten       = 0,
                levelTimeSecs         = 0,
                shufflesUsedThisLevel = 0,
                shufflesUsedThisGame  = 0,
                boardWasNearlyFull    = false,
            }
            local gameOverNewly = Achievements.check(gameOverCtx)
            stats.achievements = Achievements.getUnlockedTable()
            saveStats()

            -- Submit scores immediately (no initials prompt; see FEATURE_INITIALS)
            local sessionTimeSecs = getActiveTimeSecs()
            pendingScore    = s.score
            pendingTimeSecs = sessionTimeSecs

            for _, def in ipairs(gameOverNewly) do
                table.insert(toastQueue, { name = def.name, timer = TOAST_DURATION })
            end

            clearSavedGame()
            SoundManager.stopBGM()
            AnimManager.startTileWipe(function()
                if pendingTimeSecs > 0 then
                    Scoreboards.submitEfficiency(pendingScore, pendingTimeSecs)
                    Scoreboards.submitHighestScore(pendingScore)
                    -- Refresh cache so drawer shows updated scores after this game
                    Scoreboards.prefetch("efficiency")
                    Scoreboards.prefetch("highest_score")
                end
                -- FEATURE_INITIALS: replace direct submit above with initials prompt:
                -- loadLastInitials(); initialsCursor=1; initialsBlink=0
                -- if Scoreboards.hasSetInitials() then
                --     local s2 = initialsString()
                --     Scoreboards.submitEfficiency(pendingScore, pendingTimeSecs, s2)
                --     Scoreboards.submitHighestScore(pendingScore, s2)
                --     initialsPhase = false
                -- else initialsPhase = true end
                gameOverRevealTimer = -1
                scene = SCENE_GAMEOVER
            end)
        elseif s.isSpecialSequenceActive and not AnimManager.isTransitioning() then
            crankAccumulator = 0
            -- Phase 1: Start clear sweep (tiles implode outside-in)
            if not sweepStartedForLevelClear then
                SoundManager.play("neutralize")
                AnimManager.startClearSweep(GRID_SIZE)
                sweepStartedForLevelClear = true
            -- Phase 2: When sweep finishes, explode confetti and cut to level clear
            elseif not AnimManager.isClearSweepActive() then
                sweepStartedForLevelClear = false
                -- Burst confetti from each tile cell so it looks like the tiles explode
                for r = 1, GRID_SIZE do
                    for c = 1, GRID_SIZE do
                        local tcx = BOARD_X + (c - 1) * (TILE_SIZE + MARGIN) + math.floor(MARGIN / 2) + math.floor(TILE_SIZE / 2)
                        local tcy = BOARD_Y + (r - 1) * (TILE_SIZE + MARGIN) + math.floor(MARGIN / 2) + math.floor(TILE_SIZE / 2)
                        AnimManager.burstConfetti(tcx, tcy, 10)
                    end
                end
                AnimManager.addConfetti()
                SoundManager.stopBGM()
                SoundManager.playCelebration(engine.state.level)
                levelClearScale = 0
                -- Collect current board tile values for celebration floaters
                do
                    local vals = {}
                    for r = 1, GRID_SIZE do
                        for c = 1, GRID_SIZE do
                            local v = engine.state.grid[r][c]
                            if v ~= nil then table.insert(vals, v) end
                        end
                    end
                    AnimManager.initCelebFloaters(vals)
                end
                -- Efficiency: also saved here at level-clear
                local eff = getEfficiency()
                if eff > (stats.bestEfficiency or 0) then
                    stats.bestEfficiency = eff
                    isNewBestEfficiency = true
                    saveStats()
                end
                playdate.startAccelerometer()
                scene = SCENE_LEVELCLEAR
            end
        end -- end of SCENE_PLAY logic

        -- RENDER BOARD (SHARED BY BOTH PLAY AND MENU)
        -- Skip board render on the frame we cut to level-clear (sweep just finished;
        -- tiles would flash back at full size for 1 frame before confetti appears).
        if scene == SCENE_LEVELCLEAR then goto skipBoardRender end

        -- VFX: sidebar dither background (left + right panels)
        if VFXConfig.enabled and VFXConfig.sidebarBg.enabled and not reduceFlashing then
            gfx.setDitherPattern(VFXConfig.sidebarBg.density, VFXConfig.getDitherType(VFXConfig.sidebarBg.ditherType))
            gfx.fillRect(0, 0, BOARD_X, 240)          -- left panel
            gfx.fillRect(BOARD_X + GRID_SIZE * (TILE_SIZE + MARGIN), 0, 80, 240)  -- right panel
            gfx.setColor(gfx.kColorBlack)
        end

        -- VFX: board frame (dither border around play area)
        if VFXConfig.enabled and VFXConfig.boardFrame.enabled and not reduceFlashing then
            local bf = VFXConfig.boardFrame
            local boardW = GRID_SIZE * (TILE_SIZE + MARGIN)
            local boardH = boardW
            local fx = BOARD_X - bf.padding - bf.width
            local fy = BOARD_Y - bf.padding - bf.width
            local fw = boardW + (bf.padding + bf.width) * 2
            local fh = boardH + (bf.padding + bf.width) * 2
            gfx.setDitherPattern(bf.density, VFXConfig.getDitherType(bf.ditherType))
            for w = 0, bf.width - 1 do
                gfx.drawRect(fx + w, fy + w, fw - w * 2, fh - w * 2)
            end
            -- Inner shadow
            if bf.innerShadow then
                gfx.setDitherPattern(bf.innerDensity, VFXConfig.getDitherType(bf.ditherType))
                gfx.drawRect(BOARD_X - 1, BOARD_Y - 1, boardW + 2, boardH + 2)
            end
            gfx.setColor(gfx.kColorBlack)
        end

        local shakeX, shakeY = AnimManager.getShakeOffset()

        -- VFX: neutralize shake (additive; separate from wiggle shake)
        if VFXConfig.enabled and neutralizeShakeTimer > 0 and not reduceFlashing then
            local decay = neutralizeShakeTimer / (VFXConfig.neutralizeShake.frames or 4)
            shakeX = shakeX + math.random(-1, 1) * neutralizeShakeIntensity * decay
            shakeY = shakeY + math.random(-1, 1) * neutralizeShakeIntensity * decay
        end

        gfx.setLineWidth(2)

        -- Pass 1: Draw all cells. Slide destinations draw as empty placeholders
        -- (the moving tile will be drawn on top in pass 2, preventing source-cell
        -- overdraw from blinking the tile mid-animation).
        for r = 1, GRID_SIZE do
            for c = 1, GRID_SIZE do
                local basePx = BOARD_X + (c - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)
                local basePy = BOARD_Y + (r - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)

                local px = basePx + shakeX
                local py = basePy + shakeY

                -- No slide offset in pass 1; destination cells draw as empty
                local wigOx, wigOy = AnimManager.getWiggleOffset(r, c)
                px = px + wigOx
                py = py + wigOy

                local isSlideDest = AnimManager.isSlideDestination(r, c)

                -- Scale animations (only for non-sliding tiles)
                local drawSize = TILE_SIZE
                if not isSlideDest then
                    local sweepScale = AnimManager.getClearSweepScale(r, c)
                    local introScale = (sweepScale == nil) and AnimManager.getIntroScale(r, c) or nil
                    local neutralPopScale = (sweepScale == nil and introScale == nil) and AnimManager.getNeutralPopScale(r, c) or nil
                    local popScale = (sweepScale == nil and introScale == nil and neutralPopScale == nil) and AnimManager.getSpawnPopScale(r, c) or nil
                    local activeScale = sweepScale or introScale or neutralPopScale or popScale
                    if activeScale ~= nil then
                        if activeScale <= 0 then goto skipTile end
                        local clamped = math.max(0.01, math.min(activeScale, 1.35))
                        drawSize = math.floor(TILE_SIZE * clamped)
                        px = basePx + shakeX + wigOx + (TILE_SIZE - drawSize) / 2
                        py = basePy + shakeY + wigOy + (TILE_SIZE - drawSize) / 2
                    end
                end

                -- Skip slide destinations entirely in pass 1 — pass 2 draws them
                -- with their own background. Drawing a placeholder here causes the
                -- white box to flash behind the in-flight tile.
                if isSlideDest then goto skipTile end

                local v = s.grid[r][c]
                if v ~= nil then
                    local flashing = not AnimManager.isSliding() and AnimManager.isFlashing(r, c)
                    drawTile(v, px, py, drawSize, flashing)
                else
                    -- Empty cell
                    gfx.setColor(gfx.kColorWhite)
                    gfx.fillRoundRect(px, py, drawSize, drawSize, TILE_RADIUS)
                    if not reduceFlashing and not AnimManager.isSliding() then
                        gfx.setDitherPattern(0.1, gfx.image.kDitherTypeBayer8x8)
                        gfx.fillRoundRect(px, py, drawSize, drawSize, TILE_RADIUS)
                    end
                end

                gfx.setColor(gfx.kColorBlack)
                gfx.drawRoundRect(px, py, drawSize, drawSize, TILE_RADIUS)

                ::skipTile::
            end
        end

        -- Pass 2: Draw sliding tiles on top so source-cell backgrounds never cover them.
        -- No isSliding() gate — slides may exist before inputBlocked is set (frame 0).
        do
            for r = 1, GRID_SIZE do
                for c = 1, GRID_SIZE do
                    if AnimManager.isSlideDestination(r, c) then
                        local basePx = BOARD_X + (c - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)
                        local basePy = BOARD_Y + (r - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)

                        local slideOx, slideOy = AnimManager.getSlideOffset(r, c, TILE_SIZE, MARGIN)
                        local wigOx, wigOy = AnimManager.getWiggleOffset(r, c)
                        local px = basePx + shakeX + slideOx + wigOx
                        local py = basePy + shakeY + slideOy + wigOy

                        local v = s.grid[r][c]
                        if v ~= nil then
                            drawTile(v, px, py, TILE_SIZE, false)
                            gfx.setColor(gfx.kColorBlack)
                            gfx.drawRoundRect(px, py, TILE_SIZE, TILE_SIZE, TILE_RADIUS)
                        end
                    end
                end
            end
        end  -- Pass 2

        -- Draw particles and VFX on top of board
        AnimManager.drawParticles()
        AnimManager.drawRipples()

        -- ── LEFT UI PANEL ────────────────────────────────────────────
        tickTimers()
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        gfx.setFont(fontBold)

        local R    = TILE_RADIUS + 1  -- 5, matches right panel boxes
        local PAD  = 4                -- panel side padding
        local BW   = 80 - PAD * 2    -- box width = 72
        -- Fill full 240px height: 8 top + BH2 + 8 gap + BH2 + 8 bottom = 240
        -- level1: 8 + BH2 + 8 + BH1 + 8 = 240 → BH2=136, BH1=80 (approx)
        local isMultiLevel = s.level > 1
        local MARGIN = 8
        local GAP    = 8
        local totalH = 240 - MARGIN * 2 - GAP  -- 216
        local BH2    = isMultiLevel and math.floor(totalH * 0.55) or math.floor(totalH * 0.62)
        local BH1    = totalH - BH2

        -- Internal offsets scale with box height
        local LBL  = 10
        local VAL  = math.floor(BH2 * 0.28)
        local DIV  = math.floor(BH2 * 0.50)
        local LBL2 = math.floor(BH2 * 0.58)
        local VAL2 = math.floor(BH2 * 0.78)

        -- Primary box: LEVEL + divider + SCORE
        local p1Y = MARGIN
        gfx.drawRoundRect(PAD, p1Y, BW, BH2, R)
        gfx.setFont(fontSmall)
        gfx.drawTextAligned("LEVEL", 40, p1Y + LBL, kTextAlignment.center)
        gfx.setFont(fontBold)
        gfx.drawTextAligned("" .. s.level, 40, p1Y + VAL, kTextAlignment.center)
        gfx.drawLine(PAD + 8, p1Y + DIV, PAD + BW - 8, p1Y + DIV)
        gfx.setFont(fontSmall)
        gfx.drawTextAligned("SCORE", 40, p1Y + LBL2, kTextAlignment.center)
        gfx.setFont(fontBold)

        local popScale = AnimManager.getScorePopScale()
        local scoreStr = "" .. math.floor(displayScore)
        if popScale > 1.01 then
            gfx.pushContext(scorePopImg)
                gfx.clear(gfx.kColorClear)
                gfx.drawTextAligned(scoreStr, 40, 0, kTextAlignment.center)
            gfx.popContext()
            local scaledW = math.floor(80 * popScale)
            local scaledH = math.floor(20 * popScale)
            local scaledImg = scorePopImg:scaledImage(popScale)
            scaledImg:draw(40 - scaledW / 2, p1Y + VAL2 - (scaledH - 20) / 2)
        else
            gfx.drawTextAligned(scoreStr, 40, p1Y + VAL2, kTextAlignment.center)
        end

        -- Timer box
        local p2Y = p1Y + BH2 + GAP
        if s.level > 1 then
            gfx.drawRoundRect(PAD, p2Y, BW, BH1, R)
            gfx.setFont(fontSmall)
            gfx.drawTextAligned("LVL", 40, p2Y + LBL, kTextAlignment.center)
            gfx.setFont(fontBold)
            gfx.drawTextAligned(formatTime(levelElapsedAcc), 40, p2Y + VAL, kTextAlignment.center)
            gfx.drawLine(PAD + 8, p2Y + DIV, PAD + BW - 8, p2Y + DIV)
            gfx.setFont(fontSmall)
            gfx.drawTextAligned("TOTAL", 40, p2Y + LBL2, kTextAlignment.center)
            gfx.setFont(fontBold)
            gfx.drawTextAligned(formatTime(totalElapsedAcc), 40, p2Y + VAL2, kTextAlignment.center)
        else
            gfx.drawRoundRect(PAD, p2Y, BW, BH1, R)
            gfx.setFont(fontSmall)
            gfx.drawTextAligned("TIME", 40, p2Y + LBL, kTextAlignment.center)
            gfx.setFont(fontBold)
            gfx.drawTextAligned(formatTime(levelElapsedAcc), 40, p2Y + VAL, kTextAlignment.center)
        end

        gfx.setFont(fontRegular)

        -- RIGHT UI PANEL  (x=322 to x=398, center=360)
        -- Push right panel up when drawer encroaches
        local rightPanelBottom = 185   -- bottom of shuffle grouping
        local drawerPush = math.max(0, rightPanelBottom - (drawerY - 22))  -- 22 = pull tab height
        local rpOff = -drawerPush  -- negative = shift up

        local charge = 0
        if not AnimManager.isShuffling() and s.currentRerolls > 0 then
            charge = math.min(math.abs(shuffleAccumulator) / SHUFFLE_THRESHOLD, 1.0)
        end

        local panelCX = 360   -- right panel center x

        -- ── Layout constants ──
        local cellSize = 40   -- fixed 40px slot
        local previewTileSize = 30   -- slightly smaller than a board tile
        local cellX = panelCX - math.floor(cellSize / 2)   -- 340
        local grpTopY    = 8    -- small top margin
        local nextLabelY = grpTopY + 5   -- "NEXT" text top
        local cellY  = nextLabelY + 22 + rpOff
        local cellCX = panelCX
        local cellCY = cellY + math.floor(cellSize / 2)
        local boxSize = 32   -- square box, matches JB_W=JB_H in AnimManager
        local boxBodyY = cellY + cellSize + 20
        local ARM_LEN = 14
        -- Bottom crank tab geometry
        local NUB_W        = 22   -- horizontal extent of bottom tab
        local NUB_PROTRUDE = 8    -- downward protrusion
        local crankHubX    = panelCX
        local crankHubY    = boxBodyY + boxSize + NUB_PROTRUDE
        -- Pips: 4 cols × 2 rows, below the crank (clear of the arm's reach)
        local PIP_R    = 3
        local PIP_GAP  = 8
        local MAX_REROLLS = 8
        local PIP_COLS = 4
        local pipsRow1Y = crankHubY + ARM_LEN + PIP_R + 6
        local pipsRow2Y = pipsRow1Y + PIP_GAP

        -- ── Grouping outline ──
        local grpPad  = 5
        local grpX    = cellX - grpPad   -- 335
        local grpW    = cellSize + grpPad * 2
        local grpBotY = pipsRow2Y + PIP_R + 5
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        gfx.drawRoundRect(grpX, grpTopY, grpW, grpBotY - grpTopY, 7)

        -- ── NEXT label ──
        gfx.setFont(fontBold)
        gfx.drawTextAligned("NEXT", panelCX, nextLabelY, kTextAlignment.center)

        -- ── Tile cell ──
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRoundRect(cellX, cellY, cellSize, cellSize, TILE_RADIUS + 1)
        if not reduceFlashing then
            gfx.setDitherPattern(0.12, gfx.image.kDitherTypeBayer8x8)
            gfx.fillRoundRect(cellX, cellY, cellSize, cellSize, TILE_RADIUS + 1)
        end
        gfx.setColor(gfx.kColorBlack)
        gfx.drawRoundRect(cellX, cellY, cellSize, cellSize, TILE_RADIUS + 1)

        -- ── Preview tile ──
        do
            local shuffleDisplayVal = AnimManager.getShuffleDisplayVal()
            local nv = shuffleDisplayVal or s.nextTileValue or 1
            local previewScale = AnimManager.getShufflePreviewScale()
            local sz = previewTileSize
            if previewScale then sz = math.floor(previewTileSize * previewScale) end
            sz = math.max(8, math.min(sz, cellSize - 2))
            drawTile(nv, cellCX - math.floor(sz / 2), cellY + math.floor((cellSize - sz) / 2), sz)
        end

        -- ── Stream tiles flying from box to preview cell (drawn first, behind box) ──
        local streamTiles = AnimManager.getJackboxStreamTiles(panelCX, boxBodyY, cellCX, cellCY)
        if streamTiles then
            for _, ft in ipairs(streamTiles) do
                drawTile(ft.val, ft.x, ft.y, ft.size)
            end
        end

        -- ── Charge tile: rises from box top as player cranks (behind box) ──
        -- Grows from stream-launch size (16px) to half of previewTileSize as charge fills.
        if charge > 0 and not AnimManager.isShuffling() and s.currentRerolls > 0 then
            local chargeTileMin = 16
            local chargeTileMax = math.floor(previewTileSize / 2)   -- ~15px
            local csz = math.floor(chargeTileMin + (chargeTileMax - chargeTileMin) * charge)
            local riseAmt = math.floor(charge * chargeTileMax)      -- how far it pokes above box
            local tileTop = boxBodyY - riseAmt
            local visibleH = math.min(csz, boxBodyY - tileTop)
            if visibleH > 0 then
                local tx = panelCX - math.floor(csz / 2)
                gfx.setClipRect(tx, tileTop, csz, visibleH)
                drawTile(chargeDisplayVal, tx, tileTop, csz)
                gfx.clearClipRect()
            end
        end

        -- ── Bottom crank tab (drawn before box — folder tab style) ──
        local targetAngle = math.rad(playdate.getCrankPosition())
        local angleDiff = targetAngle - crankVisualAngle
        while angleDiff >  math.pi do angleDiff = angleDiff - 2 * math.pi end
        while angleDiff < -math.pi do angleDiff = angleDiff + 2 * math.pi end
        crankVisualAngle = crankVisualAngle + angleDiff * 0.4
        local cAngle = crankVisualAngle
        local hx = crankHubX + math.cos(cAngle) * ARM_LEN
        local hy = crankHubY + math.sin(cAngle) * ARM_LEN
        -- Tab protrudes downward; box covers the top 3px overlap
        local nubTabX = panelCX - math.floor(NUB_W / 2)
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRoundRect(nubTabX, boxBodyY + boxSize - 3, NUB_W, NUB_PROTRUDE + 5, 4)
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
        gfx.drawRoundRect(nubTabX, boxBodyY + boxSize - 3, NUB_W, NUB_PROTRUDE + 5, 4)
        gfx.drawLine(crankHubX, crankHubY, hx, hy)

        -- ── Shuffle box (drawn after tab so it covers tab's top edge) ──
        AnimManager.drawJackbox(panelCX, boxBodyY)

        -- ── Crank circles drawn last — on top of box ──
        gfx.setLineWidth(1)
        gfx.setColor(gfx.kColorWhite)
        gfx.fillCircleAtPoint(crankHubX, crankHubY, 6)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawCircleAtPoint(crankHubX, crankHubY, 6)
        gfx.setColor(gfx.kColorWhite)
        gfx.fillCircleAtPoint(hx, hy, 4)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawCircleAtPoint(hx, hy, 4)

        -- ── Shuffle pips: 4 cols × 2 rows, below crank (clear of arm reach) ──
        -- Remaining: solid filled circle. Used: thick outlined ring (empty center).
        local pipsRowStartX = panelCX - math.floor((PIP_COLS - 1) * PIP_GAP / 2)
        gfx.setColor(gfx.kColorBlack)
        for i = 1, MAX_REROLLS do
            local col = (i - 1) % PIP_COLS
            local row = math.floor((i - 1) / PIP_COLS)
            local ppx = pipsRowStartX + col * PIP_GAP
            local ppy = (row == 0) and pipsRow1Y or pipsRow2Y
            if i <= s.currentRerolls then
                gfx.setLineWidth(1)
                gfx.fillCircleAtPoint(ppx, ppy, PIP_R)
            else
                -- Ring: fill white center inside a solid border circle
                gfx.fillCircleAtPoint(ppx, ppy, PIP_R)
                gfx.setColor(gfx.kColorWhite)
                gfx.fillCircleAtPoint(ppx, ppy, PIP_R - 1)
                gfx.setColor(gfx.kColorBlack)
            end
        end
        gfx.setLineWidth(2)

        AnimManager.drawEnergyRings()

        -- Ⓐ button icon + "MENU" — fixed at bottom-right corner
        drawButtonIcon("A", panelCX, 208)
        gfx.setFont(fontBold)
        gfx.drawTextAligned("MENU", panelCX, 218, kTextAlignment.center)

        -- Crank indicator when docked and has rerolls
        if playdate.isCrankDocked() and s.currentRerolls > 0 then
            playdate.ui.crankIndicator:update()
        end

        AnimManager.drawConfetti()

        -- Transition overlays
        AnimManager.drawTileWipe()
        AnimManager.drawIris()

        -- Shuffle reminder popup (shown when player hasn't shuffled in 2+ games)
        if shuffleReminderVisible then
            local bw, bh = 300, 128
            local bx = 200 - math.floor(bw / 2)
            local by = 120 - math.floor(bh / 2)
            local br = 8

            -- Dithered shadow
            if VFXConfig.enabled and VFXConfig.dialogShadow.enabled then
                local ds = VFXConfig.dialogShadow
                gfx.setDitherPattern(ds.density, VFXConfig.getDitherType(ds.ditherType))
                gfx.fillRoundRect(bx + ds.offsetX, by + ds.offsetY, bw, bh, br)
                gfx.setColor(gfx.kColorBlack)
            end

            -- Box
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRoundRect(bx, by, bw, bh, br)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRoundRect(bx, by, bw, bh, br)

            -- Content (mirrors tutorial panel 5)
            gfx.drawTextAligned("*Don't forget to shuffle!*", 200, by + 14, kTextAlignment.center)
            gfx.setLineWidth(1)
            gfx.drawLine(bx + 12, by + 34, bx + bw - 12, by + 34)
            gfx.setLineWidth(2)
            gfx.drawTextAligned("*Crank* to shuffle your next tile.", 200, by + 44, kTextAlignment.center)
            gfx.drawTextAligned("You get *8* shuffles per game.", 200, by + 64, kTextAlignment.center)
            gfx.drawTextAligned("A / B: Got it", 200, by + bh - 20, kTextAlignment.center)

            -- Crank indicator
            if playdate.isCrankDocked() then
                playdate.ui.crankIndicator:update()
            end

            -- Dismiss
            if playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonB) then
                SoundManager.play("button")
                shuffleReminderVisible = false
            end
        end

        ::skipBoardRender::
        end -- end of if scene == SCENE_PLAY

    -- Modal Overlay Pause Screen (outside SCENE_PLAY block so it persists every frame)
    if scene == SCENE_MENU then
        local crankChange = playdate.getCrankChange()

        -- Ratchet tick for drawer scrolling in pause menu
        if math.abs(crankChange) > 0.5 then
            crankRatchetAccum = crankRatchetAccum + math.abs(crankChange)
            local tickInterval = math.max(8, 30 - math.abs(crankChange) * 1.5)
            if crankRatchetAccum >= tickInterval then
                crankRatchetAccum = crankRatchetAccum % tickInterval
                SoundManager.playCrankTick()
            end
        else
            crankRatchetAccum = 0
        end

        gfx.setImageDrawMode(gfx.kDrawModeCopy)
        gfx.clearClipRect()

        -- Draw the frozen game board snapshot
        if pauseSnapshot then
            pauseSnapshot:draw(0, 0)
        end

        -- Dithered black veil to dim the board (fades in over ~8 frames)
        -- Uses black dither so white symbols on neutral/negative tiles stay visible
        pauseFadeTimer = math.min(pauseFadeTimer + 1, 8)
        local veilAlpha = math.min(1.0, pauseFadeTimer / 8)
        gfx.setColor(gfx.kColorBlack)
        gfx.setDitherPattern(1.0 - 0.5 * veilAlpha, gfx.image.kDitherTypeBayer8x8)
        gfx.fillRect(0, 0, 400, 240)
        gfx.setColor(gfx.kColorBlack)

        -- Reinforce all tile symbols so they read as grey through the veil:
        -- White symbols (circle, minus) get redrawn in white; black symbols (plus) in black
        if engine then
            local s = engine.state
            for row = 1, GRID_SIZE do
                for col = 1, GRID_SIZE do
                    local v = s.grid[row] and s.grid[row][col]
                    if v ~= nil then
                        local px = BOARD_X + (col - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)
                        local py = BOARD_Y + (row - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)
                        local tcx = px + TILE_SIZE / 2
                        local tcy = py + TILE_SIZE / 2
                        local arm, t = 10, 4
                        local sArm, sT = 7, 3
                        local off, offL = 7, 8
                        local mag = math.abs(v)
                        if v == 0 then
                            -- Neutral: white circle on grey
                            gfx.setColor(gfx.kColorWhite)
                            gfx.setLineWidth(3)
                            gfx.drawCircleAtPoint(tcx, tcy, math.max(2, math.floor(TILE_SIZE * (7.0 / 24.0))))
                        elseif v > 0 then
                            -- Positive: black plus on grey
                            gfx.setColor(gfx.kColorBlack)
                            if mag == 1 then
                                drawPlus(tcx, tcy, arm, t)
                            elseif mag == 2 then
                                drawPlus(tcx - off, tcy, sArm, sT)
                                drawPlus(tcx + off, tcy, sArm, sT)
                            elseif mag == 3 then
                                drawPlus(tcx, tcy - off, 6, sT)
                                drawPlus(tcx - offL, tcy + off, 6, sT)
                                drawPlus(tcx + offL, tcy + off, 6, sT)
                            else
                                drawPlus(tcx - off, tcy - off, 6, sT)
                                drawPlus(tcx + off, tcy - off, 6, sT)
                                drawPlus(tcx - off, tcy + off, 6, sT)
                                drawPlus(tcx + off, tcy + off, 6, sT)
                            end
                        else
                            -- Negative: white minus on grey
                            gfx.setColor(gfx.kColorWhite)
                            if mag == 1 then
                                drawMinus(tcx, tcy, arm, t)
                            elseif mag == 2 then
                                drawMinus(tcx - off, tcy, sArm, sT)
                                drawMinus(tcx + off, tcy, sArm, sT)
                            elseif mag == 3 then
                                drawMinus(tcx, tcy - off, 6, sT)
                                drawMinus(tcx - offL, tcy + off, 6, sT)
                                drawMinus(tcx + offL, tcy + off, 6, sT)
                            else
                                drawMinus(tcx - off, tcy - off, 6, sT)
                                drawMinus(tcx + off, tcy - off, 6, sT)
                                drawMinus(tcx - off, tcy + off, 6, sT)
                                drawMinus(tcx + off, tcy + off, 6, sT)
                            end
                        end
                    end
                end
            end
            gfx.setLineWidth(2)
            gfx.setColor(gfx.kColorBlack)
        end

        -- Crank raises/lowers the drawer
        updateDrawerState(crankChange)

        -- ── Pause box ──────────────────────────────────────────────
        local boxW = 240
        local boxH = 204
        local boxX = 80
        local boxCX = boxX + boxW / 2   -- 200
        local boxY = math.min(42, drawerY - 22 - boxH - 4)

        -- Background: white + subtle dither for depth
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRoundRect(boxX, boxY, boxW, boxH, 10)
        if not reduceFlashing then
            gfx.setDitherPattern(0.07, gfx.image.kDitherTypeBayer8x8)
            gfx.fillRoundRect(boxX, boxY, boxW, boxH, 10)
        end
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(2)
        gfx.drawRoundRect(boxX, boxY, boxW, boxH, 10)
        gfx.setLineWidth(1)

        -- Title
        gfx.setFont(fontPauseTitle)
        gfx.drawTextAligned("PAUSED", boxCX, boxY + 12, kTextAlignment.center)

        -- Separator 1
        local sep1Y = boxY + 46
        gfx.setColor(gfx.kColorBlack)
        gfx.drawLine(boxX + 16, sep1Y, boxX + boxW - 16, sep1Y)

        -- Menu items
        local ITEM_W = 160
        local ITEM_H = 28
        local ITEM_R = 5
        local ITEM_GAP = 8
        local menuStartY = sep1Y + 14
        local itemX = boxCX - ITEM_W / 2

        local DEBUG_ITEM_H   = 20
        local DEBUG_ITEM_GAP = 4
        if menuDebugOpen then
            gfx.setFont(fontBold)
            gfx.drawTextAligned("DEBUG", boxCX, menuStartY, kTextAlignment.center)
            for i, label in ipairs(DEBUG_OPTS) do
                local oy = menuStartY + 18 + (i - 1) * (DEBUG_ITEM_H + DEBUG_ITEM_GAP)
                if menuDebugSel == i then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.fillRoundRect(itemX, oy, ITEM_W, DEBUG_ITEM_H, ITEM_R)
                    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                    gfx.drawTextAligned(label, boxCX, oy + 4, kTextAlignment.center)
                    gfx.setImageDrawMode(gfx.kDrawModeCopy)
                else
                    gfx.setColor(gfx.kColorWhite)
                    gfx.fillRoundRect(itemX, oy, ITEM_W, DEBUG_ITEM_H, ITEM_R)
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawRoundRect(itemX, oy, ITEM_W, DEBUG_ITEM_H, ITEM_R)
                    gfx.drawTextAligned(label, boxCX, oy + 4, kTextAlignment.center)
                end
            end
        else
            local opts = {"Resume", "Restart Game", "Debug ▶"}
            gfx.setFont(fontBold)
            for i, label in ipairs(opts) do
                local iy = menuStartY + (i - 1) * (ITEM_H + ITEM_GAP)
                if menuSelector == i then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.fillRoundRect(itemX, iy, ITEM_W, ITEM_H, ITEM_R)
                    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                    gfx.drawTextAligned(label, boxCX, iy + 5, kTextAlignment.center)
                    gfx.setImageDrawMode(gfx.kDrawModeCopy)
                else
                    gfx.setColor(gfx.kColorWhite)
                    gfx.fillRoundRect(itemX, iy, ITEM_W, ITEM_H, ITEM_R)
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawRoundRect(itemX, iy, ITEM_W, ITEM_H, ITEM_R)
                    gfx.drawTextAligned(label, boxCX, iy + 5, kTextAlignment.center)
                end
            end
        end

        -- Separator 2 + footer (only on main menu; debug submenu fills the box)
        if not menuDebugOpen then
            local sep2Y = menuStartY + 3 * (ITEM_H + ITEM_GAP) - ITEM_GAP + 10
            gfx.setColor(gfx.kColorBlack)
            gfx.drawLine(boxX + 16, sep2Y, boxX + boxW - 16, sep2Y)
            local hintY = sep2Y + 10
            if drawerY < DRAWER_CLOSED_Y then
                drawButtonHints(boxCX, hintY,
                    { {button="B", label="Close Drawer"} }, fontSmall)
            else
                drawButtonHints(boxCX, hintY,
                    { {button="B", label="Back"}, {label="*Crank:* Stats"} }, fontSmall)
            end
        end

        -- Drawer drawn on top of the veil
        drawUnifiedDrawer()

        -- Restart confirmation overlay (drawn above everything in the pause layer)
        if menuConfirmRestart then
            local cw, ch = 200, 80
            local cx = boxCX - math.floor(cw / 2)
            local cy = boxY + math.floor((boxH - ch) / 2)
            -- Shadow
            if VFXConfig.enabled and VFXConfig.dialogShadow.enabled and not reduceFlashing then
                local ds = VFXConfig.dialogShadow
                gfx.setDitherPattern(ds.density, VFXConfig.getDitherType(ds.ditherType))
                gfx.fillRoundRect(cx + ds.offsetX, cy + ds.offsetY, cw, ch, 8)
                gfx.setColor(gfx.kColorBlack)
            end
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRoundRect(cx, cy, cw, ch, 8)
            gfx.setColor(gfx.kColorBlack)
            gfx.setLineWidth(2)
            gfx.drawRoundRect(cx, cy, cw, ch, 8)
            gfx.setLineWidth(1)
            gfx.setFont(fontBold)
            gfx.drawTextAligned("Restart game?", boxCX, cy + 12, kTextAlignment.center)
            gfx.drawLine(cx + 12, cy + 34, cx + cw - 12, cy + 34)
            drawButtonHints(boxCX, cy + 44,
                { {button="A", label="Yes"}, {button="B", label="No"} }, fontSmall)
        end

        if not menuJustOpened and not AnimManager.isTransitioning() then
            if menuConfirmRestart then
                if playdate.buttonJustPressed(playdate.kButtonA) then
                    SoundManager.play("button")
                    menuConfirmRestart = false
                    AnimManager.startTileWipe(function() startNewGame() end)
                elseif playdate.buttonJustPressed(playdate.kButtonB) then
                    SoundManager.play("button")
                    menuConfirmRestart = false
                end
            elseif drawerY < DRAWER_CLOSED_Y then
                -- Drawer is open: B closes it
                if playdate.buttonJustPressed(playdate.kButtonB) then
                    drawerRetracting = true
                    SoundManager.play("button")
                end
            elseif menuDebugOpen then
                -- Debug submenu navigation
                if playdate.buttonJustPressed(playdate.kButtonUp) then
                    menuDebugSel = math.max(1, menuDebugSel - 1)
                    SoundManager.play("move")
                elseif playdate.buttonJustPressed(playdate.kButtonDown) then
                    menuDebugSel = math.min(#DEBUG_OPTS, menuDebugSel + 1)
                    SoundManager.play("move")
                elseif playdate.buttonJustPressed(playdate.kButtonA) then
                    SoundManager.play("button")
                    local s = engine.state
                    if menuDebugSel == 1 then
                        -- Fill board: 34 neutrals + +1 at (1,1) and -1 at (1,2)
                        -- One swipe neutralizes them and clears the board (matches web)
                        for r = 1, GRID_SIZE do
                            for c = 1, GRID_SIZE do
                                s.grid[r][c] = 0
                            end
                        end
                        s.grid[1][1] = 1
                        s.grid[1][2] = -1
                        s.score = 34
                        menuDebugOpen = false
                        resumeTimer()
                        scene = SCENE_PLAY
                    elseif menuDebugSel == 2 then
                        -- Force personal best: inflate score above current records
                        local fakeScore = (stats.highScore or 0) + 1000
                        isNewHighScore = true
                        isNewBestEfficiency = true
                        pendingScore = fakeScore
                        pendingTimeSecs = 60
                        gameOverEfficiency = fakeScore  -- integer, matches real formula
                        menuDebugOpen = false
                        AnimManager.startTileWipe(function()
                            gameOverRevealTimer = -1
                            scene = SCENE_GAMEOVER
                        end)
                    elseif menuDebugSel == 3 then
                        -- Go: Game Over screen
                        pendingScore = engine.state.score
                        pendingTimeSecs = getActiveTimeSecs()
                        isNewHighScore = false
                        isNewBestEfficiency = false
                        menuDebugOpen = false
                        AnimManager.startTileWipe(function()
                            -- FEATURE_INITIALS: add below to prompt for initials:
                            -- loadLastInitials(); initialsPhase = not Scoreboards.hasSetInitials()
                            gameOverRevealTimer = -1
                            scene = SCENE_GAMEOVER
                        end)
                    elseif menuDebugSel == 4 then
                        -- Go: Title screen
                        menuDebugOpen = false
                        AnimManager.startTileWipe(function() scene = SCENE_TITLE end)
                    else
                        -- Back
                        menuDebugOpen = false
                    end
                elseif playdate.buttonJustPressed(playdate.kButtonB) then
                    menuDebugOpen = false
                    SoundManager.play("button")
                end
            else
                -- Normal menu navigation
                local numOpts = 3
                if playdate.buttonJustPressed(playdate.kButtonUp) then
                    menuSelector = math.max(1, menuSelector - 1)
                    SoundManager.play("move")
                elseif playdate.buttonJustPressed(playdate.kButtonDown) then
                    menuSelector = math.min(numOpts, menuSelector + 1)
                    SoundManager.play("move")
                elseif playdate.buttonJustPressed(playdate.kButtonA) then
                    SoundManager.play("button")
                    if menuSelector == 1 then
                        resumeTimer()
                        scene = SCENE_PLAY
                    elseif menuSelector == 2 then
                        menuConfirmRestart = true
                    else
                        menuDebugOpen = true
                        menuDebugSel  = 1
                    end
                elseif playdate.buttonJustPressed(playdate.kButtonB) then
                    SoundManager.play("button")
                    resumeTimer()
                    scene = SCENE_PLAY
                end
            end
        end
        menuJustOpened = false
    end

    -----------------------------------------
    -- GAME OVER
    -----------------------------------------
    elseif scene == SCENE_GAMEOVER then
        AnimManager.update()

        -- ── Initials entry phase ────────────────────────────────
        -- Start reveal on first frame
        if gameOverRevealTimer < 0 then gameOverRevealTimer = 0 end
        gameOverRevealTimer = gameOverRevealTimer + 1

        local crankChange = playdate.getCrankChange()

        crankAccumulator = crankAccumulator + math.abs(crankChange)
        local pct = math.min(crankAccumulator / GAMEOVER_CRANK, 1.0)

        -- Ratchet tick while cranking to restart
        if math.abs(crankChange) > 0.5 then
            crankRatchetAccum = crankRatchetAccum + math.abs(crankChange)
            local tickInterval = math.max(8, 30 - math.abs(crankChange) * 1.5)
            if crankRatchetAccum >= tickInterval then
                crankRatchetAccum = crankRatchetAccum % tickInterval
                SoundManager.playCrankTick()
            end
        else
            crankRatchetAccum = 0
        end

        -- Board slides upward off screen; fresh board slides in from below
        local boardH = GRID_SIZE * (TILE_SIZE + MARGIN)
        local slideOff = pct * (BOARD_Y + boardH + 20)  -- old board slides up

        -- Draw old board sliding up
        gfx.setLineWidth(2)
        for r = 1, GRID_SIZE do
            for c = 1, GRID_SIZE do
                local px = BOARD_X + (c - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)
                local py = BOARD_Y + (r - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2) - slideOff
                if py > -TILE_SIZE and py < 240 + TILE_SIZE then
                    gfx.setColor(gfx.kColorBlack)
                    gfx.drawRoundRect(px, py, TILE_SIZE, TILE_SIZE, TILE_RADIUS)
                    local v = engine.state.grid[r][c]
                    if v ~= nil then drawTile(v, px, py) end
                end
            end
        end

        -- Draw fresh empty board sliding in from below
        if pct > 0 then
            local freshOff = (BOARD_Y + boardH + 20) - slideOff
            for r = 1, GRID_SIZE do
                for c = 1, GRID_SIZE do
                    local px = BOARD_X + (c - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2)
                    local py = BOARD_Y + (r - 1) * (TILE_SIZE + MARGIN) + (MARGIN / 2) + freshOff
                    if py > -TILE_SIZE and py < 240 + TILE_SIZE then
                        gfx.setColor(gfx.kColorWhite)
                        gfx.fillRoundRect(px, py, TILE_SIZE, TILE_SIZE, TILE_RADIUS)
                        gfx.setColor(gfx.kColorBlack)
                        gfx.drawRoundRect(px, py, TILE_SIZE, TILE_SIZE, TILE_RADIUS)
                    end
                end
            end
        end

        local isPersonalBest = isNewHighScore or isNewBestEfficiency
        local bannerH = isPersonalBest and 22 or 0
        local boxW    = 240
        local boxH    = 134
        local boxX    = 80
        local boxCX   = boxX + boxW / 2   -- 200
        local boxY0   = 54 - bannerH
        local boxY    = boxY0 + bannerH

        -- Personal best banner (black pill above the box)
        if isPersonalBest then
            local showBanner = (math.floor(gameOverRevealTimer / 8) % 2 == 0) or
                               (gameOverRevealTimer > 30)
            if showBanner then
                gfx.setColor(gfx.kColorBlack)
                gfx.fillRoundRect(boxX, boxY0, boxW, bannerH + 8, 8)
                gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
                gfx.setFont(fontSmall)
                gfx.drawTextAligned("★ NEW PERSONAL BEST ★", boxCX, boxY0 + 5, kTextAlignment.center)
                gfx.setImageDrawMode(gfx.kDrawModeCopy)
            end
        end

        -- Box: matches pause screen — white fill, subtle dither, 2px border, radius 10
        if VFXConfig.enabled and VFXConfig.dialogShadow.enabled and not reduceFlashing then
            local ds = VFXConfig.dialogShadow
            gfx.setDitherPattern(ds.density, VFXConfig.getDitherType(ds.ditherType))
            gfx.fillRoundRect(boxX + ds.offsetX, boxY + ds.offsetY, boxW, boxH, 10)
            gfx.setColor(gfx.kColorBlack)
        end
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRoundRect(boxX, boxY, boxW, boxH, 10)
        if not reduceFlashing then
            gfx.setDitherPattern(0.07, gfx.image.kDitherTypeBayer8x8)
            gfx.fillRoundRect(boxX, boxY, boxW, boxH, 10)
        end
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(2)
        gfx.drawRoundRect(boxX, boxY, boxW, boxH, 10)
        gfx.setLineWidth(1)

        -- Typed-on title "GAME OVER"
        local mainText    = "GAME OVER"
        local revealChars = math.min(#mainText, math.floor(gameOverRevealTimer / 2))
        if revealChars > 0 then
            local revealedText = string.sub(mainText, 1, revealChars)
            local cursor = ""
            if VFXConfig.enabled and VFXConfig.typewriterCursor.enabled and revealChars < #mainText then
                local blink = math.floor(vfxFrame / VFXConfig.typewriterCursor.blinkRate) % 2
                if blink == 0 then cursor = VFXConfig.typewriterCursor.cursorChar end
            end
            gfx.setFont(fontPauseTitle)
            gfx.drawTextAligned(mainText ~= revealedText and revealedText .. cursor or mainText,
                boxCX, boxY + 10, kTextAlignment.center)
        end

        -- Separator 1 (matches pause screen margins)
        local sep1Y = boxY + 46
        if gameOverRevealTimer >= #mainText * 2 then
            gfx.drawLine(boxX + 16, sep1Y, boxX + boxW - 16, sep1Y)
        end

        -- Stats (appear after reveal)
        if gameOverRevealTimer > #mainText * 2 + 4 then
            -- LEVEL (left) | SCORE (right) — two-column first row
            local leftCX  = boxX + math.floor(boxW / 4)       -- 140
            local rightCX = boxX + math.floor(3 * boxW / 4)   -- 260
            gfx.setFont(fontSmall)
            gfx.drawTextAligned("LEVEL", leftCX,  sep1Y + 10, kTextAlignment.center)
            gfx.drawTextAligned("SCORE", rightCX, sep1Y + 10, kTextAlignment.center)
            gfx.setFont(fontBold)
            gfx.drawTextAligned(tostring(engine.state.level), leftCX,  sep1Y + 24, kTextAlignment.center)
            gfx.drawTextAligned(tostring(engine.state.score), rightCX, sep1Y + 24, kTextAlignment.center)
            -- vertical divider between columns
            gfx.setLineWidth(1)
            gfx.drawLine(boxCX, sep1Y + 6, boxCX, sep1Y + 40)

            -- Separator 2
            local sep2Y = sep1Y + 46
            gfx.drawLine(boxX + 16, sep2Y, boxX + boxW - 16, sep2Y)

            -- EFFICIENCY
            gfx.setFont(fontSmall)
            local effLabel = isNewBestEfficiency and "BEST EFFICIENCY" or "EFFICIENCY"
            gfx.drawTextAligned(effLabel, boxCX, sep2Y + 10, kTextAlignment.center)
            gfx.setFont(fontBold)
            gfx.drawTextAligned(tostring(math.floor(gameOverEfficiency)), boxCX, sep2Y + 24, kTextAlignment.center)
        end

        if pct < 1.0 then
            local promptY  = boxY + boxH + 8
            local barY     = promptY + 14
            drawButtonHints(boxCX, promptY,
                { {button="A", label="to try again"} }, fontSmall)
            gfx.setFont(fontRegular)
            gfx.setLineWidth(1)
            gfx.drawRoundRect(150, barY, 100, 6, 2)
            if pct > 0 then
                if not reduceFlashing then
                    gfx.setDitherPattern(0.25, gfx.image.kDitherTypeBayer8x8)
                else
                    gfx.setColor(gfx.kColorBlack)
                end
                gfx.fillRoundRect(150, barY, math.max(4, pct * 100), 6, 2)
                gfx.setColor(gfx.kColorBlack)
            end

            -- A button instant restart
            if playdate.buttonJustPressed(playdate.kButtonA) and not AnimManager.isTransitioning() then
                AnimManager.startTileWipe(function()
                    startNewGame()
                end)
            end
        elseif not AnimManager.isTransitioning() then
            -- Fully cranked → restart
            AnimManager.startTileWipe(function()
                startNewGame()
            end)
        end

        if playdate.isCrankDocked() then
            playdate.ui.crankIndicator:update()
        end
        AnimManager.drawTileWipe()
        AnimManager.drawIris()

    -----------------------------------------
    -- LEVEL CLEAR
    -----------------------------------------
    elseif scene == SCENE_LEVELCLEAR then
        AnimManager.update()

        local crankChange = playdate.getCrankChange()

        -- Crank celebrates: burst + wind confetti + Shepard tone
        local absCrank = math.abs(crankChange)
        if absCrank > 2 then
            local bx = math.random(40, 360)
            local by = math.random(260, 280)  -- spawn from bottom edge, wind carries upward
            AnimManager.burstConfetti(bx, by, math.floor(absCrank / 3) + 2)
            AnimManager.swirlConfetti(crankChange)
            SoundManager.updateShepardCrank(crankChange)
        end

        -- Frenzy accumulator: crank really fast to trigger a surge
        if absCrank > 12 then
            crankFrenzyAccum = math.min(100, crankFrenzyAccum + absCrank * 0.35)
        else
            crankFrenzyAccum = math.max(0, crankFrenzyAccum - 1.5)
        end

        local ax, ay = playdate.readAccelerometer()
        AnimManager.setCelebAccel(ax, ay)
        AnimManager.updateCelebFloaters(crankChange, ax, ay)

        local mag = (ax and ay) and math.sqrt(ax*ax + ay*ay + 1.0) or 1.0
        local isHardCrank = absCrank > 10
        local isHardShake = mag > 1.8

        -- Shake detection: magnitude well above 1.0 resting gravity
        if mag > 2.4 then
            if crankFrenzyAccum > 25 then
                -- ★ COMBO: crank fast + physical shake = ALL HELL BREAKS LOOSE
                crankFrenzyAccum = 0
                frenzyShakeTimer = 50
                for i = 1, 14 do
                    AnimManager.burstConfetti(math.random(20, 380), math.random(10, 230), 50)
                end
                AnimManager.addMoreFloaters(4)
                AnimManager.addStreaks(12)
            else
                -- Regular shake burst: confetti + 1-2 new floaters
                AnimManager.burstConfetti(math.random(60, 340), math.random(40, 200), 35)
                AnimManager.burstConfetti(math.random(60, 340), math.random(40, 200), 25)
                AnimManager.burstConfetti(math.random(60, 340), math.random(40, 200), 20)
                AnimManager.addMoreFloaters(math.random(1, 2))
            end
        end

        -- Frenzy trigger: fast crank sustained long enough → mega shake + burst + streaks
        if crankFrenzyAccum >= 100 then
            crankFrenzyAccum = 0
            frenzyShakeTimer = 30
            for i = 1, 8 do
                AnimManager.burstConfetti(math.random(20, 380), math.random(10, 230), 40)
            end
            AnimManager.addMoreFloaters(3)
            AnimManager.addStreaks(5)
        end

        -- ★ WHIRLPOOL: sustained hard crank + hard shake for 5 seconds
        if isHardCrank and isHardShake then
            comboSustainTimer = comboSustainTimer + 1
            if comboSustainTimer >= 150 and not meltTriggered then
                -- First trigger: big chaos burst + start swirl
                meltTriggered = true
                AnimManager.triggerMelt()
                frenzyShakeTimer = 80
                for i = 1, 18 do
                    AnimManager.burstConfetti(math.random(20, 380), math.random(10, 230), 60)
                end
                AnimManager.addMoreFloaters(4)
                AnimManager.addStreaks(10)
            elseif meltTriggered then
                AnimManager.sustainMelt()
            end
        else
            comboSustainTimer = math.max(0, comboSustainTimer - 2)
            if meltTriggered and AnimManager.isMeltActive() then
                AnimManager.releaseMelt()
            end
        end

        -- Bonus points during whirlpool hold: +25 every 2 seconds
        if AnimManager.isMeltHolding() then
            celebBonusTimer = celebBonusTimer + 1
            if celebBonusTimer % 60 == 0 then
                engine.state.score = engine.state.score + 25
                celebBonusEarned   = celebBonusEarned + 25
                table.insert(toastQueue, { name = "+25 BONUS!", timer = TOAST_DURATION })
            end
        end

        -- Full-screen shake during frenzy (draw offset resets every frame)
        if frenzyShakeTimer > 0 then
            frenzyShakeTimer = frenzyShakeTimer - 1
            local intensity = math.ceil(frenzyShakeTimer * 0.18)
            playdate.graphics.setDrawOffset(
                math.random(-intensity, intensity),
                math.random(-intensity, intensity)
            )
        else
            playdate.graphics.setDrawOffset(0, 0)
        end

        -- Passive confetti trickle
        if math.random() > 0.6 then
            AnimManager.burstConfetti(200, 250, 1)
        end

        -- Advance pop-in scale (ease-out, ~7 frames to reach 1.0)
        levelClearScale = math.min(1.0, levelClearScale + 0.15)
        local s = levelClearScale

        -- Celebration tile floaters (behind confetti and dialog)
        do
            local cf = AnimManager.getCelebFloaters()
            for _, f in ipairs(cf) do
                local fx = math.floor(f.x)
                local fy = math.floor(f.y)
                local fsz = f.size
                if not f.rotCache then
                    local baseImg = gfx.image.new(fsz + 4, fsz + 4)
                    gfx.pushContext(baseImg)
                    drawTile(f.value, 2, 2, fsz)
                    gfx.popContext()
                    -- 12 steps × 30° = 360°; was 48 × 7.5° — 4× fewer image objects
                    f.rotCache = {}
                    for step = 0, 11 do
                        local ang = step * 30
                        if ang == 0 then
                            f.rotCache[step] = baseImg
                        else
                            f.rotCache[step] = baseImg:rotatedImage(ang)
                        end
                    end
                end
                local step = math.floor((f.angle % 360) / 30 + 0.5) % 12
                local rotImg = f.rotCache[step]
                local rw, rh = rotImg:getSize()
                rotImg:draw(fx + (fsz + 4) / 2 - rw / 2, fy + (fsz + 4) / 2 - rh / 2)
            end
        end

        -- Confetti falling (on top of tiles)
        AnimManager.drawConfetti()

        -- Light streaks: frenzy lasers zip across, drawn above confetti
        AnimManager.updateAndDrawStreaks()

        -- Whirlpool swirl: drawn above floaters/confetti/streaks, behind dialog
        AnimManager.updateAndDrawMelt()

        -- Overlay box (rounded), scaled from center (200, 120)
        local bw = math.floor(240 * s)
        local bh = math.floor(120 * s)
        local bx = 200 - math.floor(bw / 2)
        local by = 120 - math.floor(bh / 2)
        local br = math.max(1, math.floor(8 * s))

        -- VFX: dialog shadow
        if VFXConfig.enabled and VFXConfig.dialogShadow.enabled and not reduceFlashing then
            local ds = VFXConfig.dialogShadow
            gfx.setDitherPattern(ds.density, VFXConfig.getDitherType(ds.ditherType))
            gfx.fillRoundRect(bx + ds.offsetX, by + ds.offsetY, bw, bh, br)
            gfx.setColor(gfx.kColorBlack)
        end
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRoundRect(bx, by, bw, bh, br)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawRoundRect(bx, by, bw, bh, br)

        -- Content: clip to box so text doesn't overflow during scale-in
        if s > 0.1 then
            gfx.setClipRect(bx, by, bw, bh)
            gfx.drawTextAligned("*LEVEL " .. engine.state.level .. " CLEARED!*", 200, 75, kTextAlignment.center)
            gfx.drawTextAligned("Score: *" .. engine.state.score .. "*", 200, 100, kTextAlignment.center)
            gfx.clearClipRect()
        end

        local function advanceToNextLevel()
            AnimManager.startTileWipe(function()
                SoundManager.stopCelebration()
                AnimManager.setCelebAccel(0, 0)
                AnimManager.clearCelebFloaters()
                playdate.stopAccelerometer()
                playdate.graphics.setDrawOffset(0, 0)
                crankFrenzyAccum    = 0
                frenzyShakeTimer    = 0
                comboSustainTimer   = 0
                meltTriggered       = false
                celebBonusTimer     = 0
                local celebBonusThisLevel = celebBonusEarned
                celebBonusEarned    = 0
                AnimManager.clearStreaks()
                AnimManager.clearMelt()
                SoundManager.playBGM()
                local levelBeaten = engine.state.level
                local levelTimeSecs = levelElapsedAcc
                local shufflesUsedThisLevel = rerollsAtLevelStart - engine.state.currentRerolls

                -- Check level-beat and mastery achievements before advancing
                local levelCtx = {
                    totalNeutralized      = stats.totalNeutralized + engine.state.sessionNeutralized,
                    totalMerges           = (stats.totalMerges or 0) + engine.state.sessionMerged,
                    gamesPlayed           = stats.gamesPlayed,
                    score                 = engine.state.score,
                    levelJustBeaten       = levelBeaten,
                    levelTimeSecs         = levelTimeSecs,
                    shufflesUsedThisLevel = shufflesUsedThisLevel,
                    shufflesUsedThisGame  = 8 - engine.state.currentRerolls,
                    boardWasNearlyFull    = boardNearlyFull,
                    celebBonusEarned      = celebBonusThisLevel,
                }
                local levelNewly = Achievements.check(levelCtx)
                if #levelNewly > 0 then
                    stats.achievements = Achievements.getUnlockedTable()
                    for _, def in ipairs(levelNewly) do
                        table.insert(toastQueue, { name = def.name, timer = TOAST_DURATION })
                    end
                end

                if engine.state.level > stats.highestLevel then
                    stats.highestLevel = engine.state.level
                end
                engine:advanceLevel()
                resetLevelTimer()
                -- Reset per-level tracking for the new level
                rerollsAtLevelStart = engine.state.currentRerolls
                boardNearlyFull = false
                crankAccumulator = 0
                shuffleAccumulator = 0
                lastScore = engine.state.score
                AnimManager.addTileIntro(GRID_SIZE)
                saveGame(engine)
                saveStats()
                scene = SCENE_PLAY
            end)
        end

        -- Prompt: show once box is fully in
        if s >= 1.0 then
            drawButtonHints(200, 145,
                { {button="A", label="continue"}, {label="Crank to celebrate"} },
                fontSmall)
            gfx.setFont(fontSmall)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawTextAligned("Tilt for joy", 200, 157, kTextAlignment.center)
        end

        if playdate.buttonJustPressed(playdate.kButtonA) and not AnimManager.isTransitioning() and s >= 1.0 then
            SoundManager.stopShepard()
            advanceToNextLevel()
        end

        if playdate.isCrankDocked() then
            playdate.ui.crankIndicator:update()
        end
        AnimManager.drawTileWipe()

    end

    -- ── Achievement toast (drawn on top of everything, all scenes) ──
    if #toastQueue > 0 then
        local toast = toastQueue[1]
        toast.timer = toast.timer - 1
        if toast.timer <= 0 then
            table.remove(toastQueue, 1)
        else
            -- Slide in from bottom over first 8 frames, out over last 8
            local slideIn  = math.min(1, (TOAST_DURATION - toast.timer) / 8)
            local slideOut = math.min(1, toast.timer / 8)
            local alpha    = math.min(slideIn, slideOut)
            local bannerH  = 20
            local bannerY  = 240 - math.floor(alpha * bannerH)
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRect(0, bannerY, 400, bannerH)
            -- VFX: dither top border on toast
            if VFXConfig.enabled and VFXConfig.toast.topBorder.enabled and not reduceFlashing then
                local tb = VFXConfig.toast.topBorder
                gfx.setDitherPattern(tb.density, gfx.image.kDitherTypeBayer8x8)
                gfx.fillRect(0, bannerY - tb.height, 400, tb.height)
                gfx.setColor(gfx.kColorBlack)
            end
            gfx.setColor(gfx.kColorWhite)
            gfx.setFont(fontSmall)
            gfx.drawTextAligned("* " .. toast.name .. " *", 200, bannerY + 3, kTextAlignment.center)
            gfx.setColor(gfx.kColorBlack)
        end
    end
    -- FEATURE_INITIALS: initials entry overlay — restore this block to re-enable.
    -- Search "FEATURE_INITIALS" throughout this file to find all related sites.
    -- if initialsPhase then
    --     initialsBlink = initialsBlink + 1
    --     if playdate.buttonJustPressed(playdate.kButtonUp) then
    --         initialsIdx[initialsCursor] = (initialsIdx[initialsCursor] - 2) % ALPHA_LEN + 1
    --     elseif playdate.buttonJustPressed(playdate.kButtonDown) then
    --         initialsIdx[initialsCursor] = initialsIdx[initialsCursor] % ALPHA_LEN + 1
    --     elseif playdate.buttonJustPressed(playdate.kButtonLeft) then
    --         initialsCursor = (initialsCursor - 2) % 3 + 1
    --     elseif playdate.buttonJustPressed(playdate.kButtonRight) then
    --         initialsCursor = initialsCursor % 3 + 1
    --     end
    --     local crankDelta = playdate.getCrankChange()
    --     local crankSteps = math.floor(math.abs(crankDelta) / 15)
    --     if crankSteps > 0 then
    --         local dir = crankDelta > 0 and 1 or -1
    --         for _ = 1, crankSteps do
    --             if dir > 0 then initialsIdx[initialsCursor] = initialsIdx[initialsCursor] % ALPHA_LEN + 1
    --             else initialsIdx[initialsCursor] = (initialsIdx[initialsCursor] - 2) % ALPHA_LEN + 1 end
    --         end
    --     end
    --     local function confirmInitials()
    --         local s = initialsString()
    --         Scoreboards.saveLastInitials(s)
    --         if pendingTimeSecs > 0 then
    --             Scoreboards.submitEfficiency(pendingScore, pendingTimeSecs, s)
    --             Scoreboards.submitHighestScore(pendingScore, s)
    --             pendingTimeSecs = 0
    --         end
    --         initialsPhase = false; gameOverRevealTimer = -1
    --     end
    --     if playdate.buttonJustPressed(playdate.kButtonA) then confirmInitials()
    --     elseif playdate.buttonJustPressed(playdate.kButtonB) then confirmInitials() end
    --     if initialsPhase then
    --         gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
    --         gfx.setColor(gfx.kColorBlack); gfx.fillRect(0, 0, 400, 240)
    --         local boxW, boxH, boxX, boxY = 240, 130, 80, 55
    --         gfx.setColor(gfx.kColorWhite); gfx.fillRoundRect(boxX, boxY, boxW, boxH, 8)
    --         gfx.setColor(gfx.kColorBlack); gfx.setLineWidth(2)
    --         gfx.drawRoundRect(boxX, boxY, boxW, boxH, 8); gfx.setLineWidth(1)
    --         gfx.setFont(fontSmall)
    --         gfx.drawTextAligned("YOUR INITIALS", 200, boxY + 8, kTextAlignment.center)
    --         local slotW, slotH, slotGap = 36, 44, 12
    --         local slotStartX = 200 - (3*slotW + 2*slotGap) / 2
    --         local slotY = boxY + 30
    --         for i = 1, 3 do
    --             local sx = slotStartX + (i-1)*(slotW+slotGap)
    --             local isActive = (i == initialsCursor)
    --             if isActive then gfx.setColor(gfx.kColorBlack); gfx.fillRoundRect(sx,slotY,slotW,slotH,4)
    --             else gfx.setColor(gfx.kColorWhite); gfx.fillRoundRect(sx,slotY,slotW,slotH,4)
    --                  gfx.setColor(gfx.kColorBlack); gfx.drawRoundRect(sx,slotY,slotW,slotH,4) end
    --             gfx.setFont(fontBold)
    --             if isActive then gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    --             else gfx.setImageDrawMode(gfx.kDrawModeCopy) end
    --             gfx.drawTextAligned(ALPHA[initialsIdx[i]], sx+slotW/2, slotY+10, kTextAlignment.center)
    --             gfx.setImageDrawMode(gfx.kDrawModeCopy)
    --             if isActive then
    --                 local ax = sx+slotW/2
    --                 gfx.fillTriangle(ax,slotY-8,ax-5,slotY-2,ax+5,slotY-2)
    --                 gfx.fillTriangle(ax,slotY+slotH+8,ax-5,slotY+slotH+2,ax+5,slotY+slotH+2)
    --             end
    --         end
    --         gfx.setFont(fontSmall)
    --         gfx.drawTextAligned("↑↓ change  ←→ move  A: save", 200, boxY+boxH-16, kTextAlignment.center)
    --     end
    -- end  -- END FEATURE_INITIALS

    ::continueGameLoop::
end

-- ── Lifecycle callbacks — save on quit/sleep ──────────────────────────────────
function playdate.gameWillTerminate()
    saveGame(engine)
    saveStats()
end

function playdate.deviceWillSleep()
    saveGame(engine)
    saveStats()
end

function playdate.gameWillPause()
    pauseTimer()
end

function playdate.gameWillResume()
    -- Only resume the timer if we are in SCENE_PLAY, otherwise let SCENE_MENU logic resume it when the player unpauses
    if scene == SCENE_PLAY then
        resumeTimer()
    end
end
