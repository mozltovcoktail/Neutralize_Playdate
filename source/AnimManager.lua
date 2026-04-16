-- AnimManager.lua — Lightweight animation system for Neutralize on Playdate
-- All VFX are frame-based (30 fps). main.lua queries offsets/states during render.

local gfx = playdate.graphics

AnimManager = {}
AnimManager.__index = AnimManager

-- ─── Active animation lists ──────────────────────────────────
local slides = {}       -- {fromR,fromC,toR,toC,timer,duration}
local shakeTimer = 0
local shakeOffX, shakeOffY = 0, 0
local flashes = {}      -- key "r,c" → timer
local scorePopTimer = 0
local particles = {}    -- {x,y,dx,dy,timer}
local confetti = {}     -- {x,y,dy,driftX,size,pattern,timer}
local introTiles = {}   -- key "r,c" → {delay, timer}
local floaters = {}     -- {x,y,dx,dy,value,size} — splash screen tiles
local celebFloaters    = {} -- {x,y,dx,dy,value,size,spin,angle,lifetime,damp}
local streaks          = {} -- {x,y,ndx,ndy,speed,timer,maxTimer} — frenzy light streaks
local celebGravX       = 0
local celebGravY       = 0
local floaterCrankAccum = 0  -- slow trickle: crank degrees → new floater
local MAX_FLOATERS      = 8  -- hard cap: each floater holds 12 rotated images
local meltState         = nil -- nil = inactive; table = melt in progress
local wiggleTimer = 0
local wigglePhases = {} -- key "r,c" → random phase offset
local orbitBlend = 0.0  -- 0 = free float, 1 = full orbit
local orbitAngle = 0    -- cumulative crank angle (degrees)
local orbitVelocity = 0 -- physics momentum for orbit
local orbitHeroCX = 200 -- hero tile center x
local orbitHeroCY = 50  -- hero tile center y
local orbitRadius = 90  -- orbit circle radius
local irisTimer = 0
local irisDir = 0       -- 1 = closing (out), -1 = opening (in), 0 = idle
local irisDuration = 10
local irisCallback = nil
-- Tile wipe transition
local tileWipeTimer = 0
local tileWipePhase = 0  -- 0=idle, 1=grow, 2=hold, 3=shrink
local tileWipeCallback = nil
local TILE_WIPE_GROW = 14
local TILE_WIPE_HOLD = 4
local TILE_WIPE_SHRINK = 10
local inputBlocked = false

-- SpawnPop state
local spawnPops = {}        -- key "r,c" → timer (0..SPAWN_POP_DURATION)
-- NeutralPop state: grow-then-shrink when a tile becomes neutral
local neutralPops = {}      -- key "r,c" → timer (0..NEUTRAL_POP_DURATION)
local NEUTRAL_POP_DURATION = 14
-- Ripple state
local ripples = {}          -- {cx, cy, timer}
-- Clear sweep state
local clearSweep = {}       -- key "r,c" → {timer, maxTimer}
local sweepActive = false
-- D-Pad ghost arrow
local dpadGhost = nil       -- {dx, dy, timer}
-- Energy ring charge state
local energyRings = {}      -- {timer, cx, cy}

-- Jack-in-the-box shuffle animation state
local jackboxAnim = nil   -- {timer,phase,tiles,newVal,displayVal,flipEvent,nextFlip,streamDone,landPop,engine}
local jackboxCooldown = 0

local JB_STREAM_FRAMES = 36  -- total stream duration (matches web ~1.2s at 30fps)
local JB_TILE_TRAVEL   = 12  -- frames each tile takes to fly from box top to cell
local JB_POP_FRAMES    = 8   -- frames for final landing pop
local JB_FLIP_FAST     = 2   -- min flip interval at stream start (fast)
local JB_FLIP_SLOW     = 12  -- max flip interval at stream end (slow)
local JB_LAND_POP      = 4   -- frames of preview pulse when tile lands
local JB_COOLDOWN      = 20  -- cooldown after anim completes

-- Box geometry (flat 2D, square)
local JB_W = 32   -- box width (px)
local JB_H = 32   -- box height (px)
local JB_R = 5    -- corner radius

-- ─── Constants ───────────────────────────────────────────────
local SLIDE_DURATION = 4
local SHAKE_DURATION = 8
local FLASH_DURATION = 4
local SCORE_POP_DURATION = 6
local PARTICLE_DURATION = 8
local PARTICLE_COUNT = 7
local CONFETTI_COUNT = 25
local CONFETTI_DURATION = 60
local INTRO_PER_TILE = 6
local INTRO_STAGGER = 2
local IRIS_DURATION = 10
local WIGGLE_DURATION = 12  -- frames (~0.4s at 30fps)
local SPAWN_POP_DURATION = 9
local RIPPLE_DURATION = 14
local SWEEP_DURATION = 18
local SWEEP_STAGGER = 3
local DPAD_GHOST_DURATION = 5
local ENERGY_RING_DURATION = 22

-- ─── Update (call once per frame) ────────────────────────────
function AnimManager.update()
    -- Slides
    local slideActive = false
    for i = #slides, 1, -1 do
        slides[i].timer = slides[i].timer + 1
        if slides[i].timer >= slides[i].duration then
            table.remove(slides, i)
        else
            slideActive = true
        end
    end
    inputBlocked = slideActive

    -- Shake
    if shakeTimer > 0 then
        shakeTimer = shakeTimer - 1
        local intensity = (shakeTimer / SHAKE_DURATION) * 3
        shakeOffX = math.random(-1, 1) * intensity
        shakeOffY = math.random(-1, 1) * intensity
        if shakeTimer == 0 then
            shakeOffX, shakeOffY = 0, 0
        end
    end

    -- Wiggle (per-tile)
    if wiggleTimer > 0 then
        wiggleTimer = wiggleTimer - 1
    end

    -- SpawnPops
    for k, t in pairs(spawnPops) do
        spawnPops[k] = t + 1
        if spawnPops[k] >= SPAWN_POP_DURATION then spawnPops[k] = nil end
    end

    -- NeutralPops
    for k, t in pairs(neutralPops) do
        neutralPops[k] = t + 1
        if neutralPops[k] >= NEUTRAL_POP_DURATION then neutralPops[k] = nil end
    end

    -- Ripples
    for i = #ripples, 1, -1 do
        local rp = ripples[i]
        rp.timer = rp.timer + 1
        if rp.timer >= RIPPLE_DURATION then table.remove(ripples, i) end
    end

    -- Clear sweep
    if sweepActive then
        local anyAlive = false
        for _, info in pairs(clearSweep) do
            info.timer = info.timer + 1
            if info.timer < info.maxTimer then anyAlive = true end
        end
        if not anyAlive then sweepActive = false end
    end

    -- D-pad ghost
    if dpadGhost then
        dpadGhost.timer = dpadGhost.timer - 1
        if dpadGhost.timer <= 0 then dpadGhost = nil end
    end

    -- Energy rings
    for i = #energyRings, 1, -1 do
        energyRings[i].timer = energyRings[i].timer + 1
        if energyRings[i].timer >= ENERGY_RING_DURATION then table.remove(energyRings, i) end
    end

    -- Flashes
    for k, t in pairs(flashes) do
        flashes[k] = t - 1
        if flashes[k] <= 0 then
            flashes[k] = nil
        end
    end

    -- Score pop
    if scorePopTimer > 0 then
        scorePopTimer = scorePopTimer - 1
    end

    -- Particles
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.x = p.x + p.dx
        p.y = p.y + p.dy
        p.timer = p.timer - 1
        if p.timer <= 0 then
            table.remove(particles, i)
        end
    end

    -- Confetti
    local hasCelebAccel = celebGravX ~= 0 or celebGravY ~= 0
    for i = #confetti, 1, -1 do
        local c = confetti[i]
        -- Apply accelerometer gravity (celebration mode) or per-particle gravity
        local vx = (c.dx or 0) + (c.driftX or 0)
        local vy = c.dy
        if hasCelebAccel then
            vx = vx + celebGravX
            vy = vy + celebGravY
            -- Speed cap so particles don't fly off screen instantly
            local spd = math.sqrt(vx * vx + vy * vy)
            if spd > 9 then
                local sc = 9 / spd
                vx = vx * sc
                vy = vy * sc
            end
        else
            if c.gravity then vy = vy + c.gravity end
        end
        -- Gentle damping
        vx = vx * 0.97
        vy = vy * 0.99
        c.dx = vx
        c.driftX = 0  -- absorbed into dx
        c.dy = vy
        c.x = c.x + c.dx
        c.y = c.y + c.dy

        c.timer = c.timer - 1
        if c.timer <= 0 then
            table.remove(confetti, i)
        end
    end

    -- Tile intro
    for k, info in pairs(introTiles) do
        if info.delay > 0 then
            info.delay = info.delay - 1
        else
            info.timer = info.timer + 1
            if info.timer >= INTRO_PER_TILE then
                introTiles[k] = nil
            end
        end
    end

    -- Floating tiles (splash) physics are updated downstream in main.lua

    -- Shuffle animation
    -- Jack-in-the-box stream animation
    if jackboxAnim then
        jackboxAnim.timer = jackboxAnim.timer + 1
        jackboxAnim.flipEvent = nil
        if jackboxAnim.landPop > 0 then jackboxAnim.landPop = jackboxAnim.landPop - 1 end

        if jackboxAnim.phase == "stream" then
            -- Advance in-flight tiles; land them when they reach the cell
            for i = #jackboxAnim.tiles, 1, -1 do
                local tile = jackboxAnim.tiles[i]
                tile.age = tile.age + 1
                if tile.age >= JB_TILE_TRAVEL then
                    -- Tile lands: update preview value
                    jackboxAnim.displayVal = tile.val
                    jackboxAnim.flipEvent = tile.val
                    jackboxAnim.landPop = JB_LAND_POP
                    table.remove(jackboxAnim.tiles, i)
                end
            end

            -- Launch next tile while stream is running
            if not jackboxAnim.streamDone then
                jackboxAnim.nextFlip = jackboxAnim.nextFlip - 1
                if jackboxAnim.nextFlip <= 0 then
                    local isLast = jackboxAnim.timer >= JB_STREAM_FRAMES
                    -- Pick value: last tile uses resolved newVal; others use random pool
                    local v
                    if isLast then
                        v = jackboxAnim.newVal
                        jackboxAnim.streamDone = true
                    elseif jackboxAnim.engine then
                        local att = 0
                        repeat
                            v = jackboxAnim.engine:chooseRandomTileValue()
                            att = att + 1
                        until v ~= jackboxAnim.displayVal or att > 20
                    else
                        local vals = {1, -1, 2, -2, 3, -3}
                        v = vals[math.random(#vals)]
                    end
                    table.insert(jackboxAnim.tiles, { val = v, age = 0 })
                    jackboxAnim.flipEvent = v
                    -- Lerp next interval: fast at start → slow at end
                    local t = math.min(jackboxAnim.timer / JB_STREAM_FRAMES, 1)
                    jackboxAnim.nextFlip = math.max(JB_FLIP_FAST,
                        math.floor(JB_FLIP_FAST + (JB_FLIP_SLOW - JB_FLIP_FAST) * t))
                end
            end

            -- Transition to pop once stream done and all tiles landed
            if jackboxAnim.streamDone and #jackboxAnim.tiles == 0 then
                jackboxAnim.phase = "pop"
                jackboxAnim.timer = 0
                jackboxAnim.displayVal = jackboxAnim.newVal
                jackboxAnim.flipEvent = jackboxAnim.newVal
            end

        elseif jackboxAnim.phase == "pop" then
            if jackboxAnim.timer >= JB_POP_FRAMES then
                jackboxAnim = nil
                jackboxCooldown = JB_COOLDOWN
            end
        end
    end
    if jackboxCooldown > 0 then jackboxCooldown = jackboxCooldown - 1 end

    -- Tile wipe transition
    if tileWipePhase > 0 then
        tileWipeTimer = tileWipeTimer + 1
        if tileWipePhase == 1 and tileWipeTimer >= TILE_WIPE_GROW then
            tileWipePhase = 2
            tileWipeTimer = 0
            if tileWipeCallback then
                tileWipeCallback()
                tileWipeCallback = nil
            end
        elseif tileWipePhase == 2 and tileWipeTimer >= TILE_WIPE_HOLD then
            tileWipePhase = 3
            tileWipeTimer = 0
        elseif tileWipePhase == 3 and tileWipeTimer >= TILE_WIPE_SHRINK then
            tileWipePhase = 0
            tileWipeTimer = 0
        end
    end

    -- Iris transition
    if irisDir ~= 0 then
        irisTimer = irisTimer + 1
        if irisTimer >= irisDuration then
            if irisDir == 1 and irisCallback then
                -- Iris closed — execute callback (scene change), then open
                irisCallback()
                irisCallback = nil
                irisDir = -1
                irisTimer = 0
            elseif irisDir == -1 then
                -- Iris fully open — done
                irisDir = 0
                irisTimer = 0
            end
        end
    end
end

-- ─── Slide ───────────────────────────────────────────────────

function AnimManager.addSlide(fromR, fromC, toR, toC)
    table.insert(slides, {
        fromR = fromR, fromC = fromC,
        toR = toR, toC = toC,
        timer = 0, duration = SLIDE_DURATION
    })
end

--- Get pixel offset for a tile at grid position (r,c).
--- Returns dx, dy to add to the tile's final pixel position.
function AnimManager.getSlideOffset(r, c, tileSize, margin)
    for _, s in ipairs(slides) do
        if s.toR == r and s.toC == c then
            local progress = s.timer / s.duration
            -- Ease-out quart (snappy start, smooth stop)
            local inv = 1 - progress
            local t = 1 - inv * inv * inv * inv
            local cellStep = tileSize + margin
            local startOffX = (s.fromC - s.toC) * cellStep
            local startOffY = (s.fromR - s.toR) * cellStep
            return startOffX * (1 - t), startOffY * (1 - t)
        end
    end
    return 0, 0
end

--- Returns true if (r,c) is currently the destination of an active slide.
--- Used to defer drawing of sliding tiles to a second pass.
function AnimManager.isSlideDestination(r, c)
    for _, s in ipairs(slides) do
        if s.toR == r and s.toC == c then return true end
    end
    return false
end

--- Returns true if (r,c) is the source of an active slide (cell should draw empty).
function AnimManager.isSlideSource(r, c)
    for _, s in ipairs(slides) do
        if s.fromR == r and s.fromC == c then return true end
    end
    return false
end

function AnimManager.isSliding()
    return inputBlocked
end

-- ─── Shake ───────────────────────────────────────────────────

function AnimManager.addShake()
    shakeTimer = SHAKE_DURATION
end

function AnimManager.getShakeOffset()
    return shakeOffX, shakeOffY
end

-- ─── Wiggle (per-tile jitter on failed swipe) ────────────────

function AnimManager.addWiggle(gridSize)
    wiggleTimer = WIGGLE_DURATION
    wigglePhases = {}
    for r = 1, gridSize do
        for c = 1, gridSize do
            wigglePhases[r .. "," .. c] = math.random() * math.pi * 2
        end
    end
end

--- Returns per-tile x,y offset for the wiggle animation.
--- Each tile oscillates independently with its own phase.
function AnimManager.getWiggleOffset(r, c)
    if wiggleTimer <= 0 then return 0, 0 end
    local phase = wigglePhases[r .. "," .. c]
    if not phase then return 0, 0 end
    local decay = wiggleTimer / WIGGLE_DURATION
    local t = (WIGGLE_DURATION - wiggleTimer) * 0.8  -- speed of oscillation
    local ox = math.sin(t * 6 + phase) * 2.5 * decay
    local oy = math.cos(t * 5 + phase * 1.3) * 1.5 * decay
    return ox, oy
end

-- ─── Flash ───────────────────────────────────────────────────

function AnimManager.addFlash(r, c)
    flashes[r .. "," .. c] = FLASH_DURATION
end

function AnimManager.isFlashing(r, c)
    local t = flashes[r .. "," .. c]
    if t and t > FLASH_DURATION / 2 then
        return true  -- first half = inverted
    end
    return false
end

-- ─── Score Pop ───────────────────────────────────────────────

function AnimManager.addScorePop()
    scorePopTimer = SCORE_POP_DURATION
end

--- Returns scale factor for score text (1.0 = normal).
function AnimManager.getScorePopScale()
    if scorePopTimer <= 0 then return 1.0 end
    local half = SCORE_POP_DURATION / 2
    local t
    if scorePopTimer > half then
        t = (SCORE_POP_DURATION - scorePopTimer) / half  -- 0→1 (growing)
    else
        t = scorePopTimer / half  -- 1→0 (shrinking)
    end
    return 1.0 + t * 0.5  -- max 1.5x
end

-- ─── Particles ───────────────────────────────────────────────

function AnimManager.addParticles(px, py)
    for i = 1, PARTICLE_COUNT do
        local angle = (math.pi * 2 * i) / PARTICLE_COUNT + (math.random() - 0.5) * 0.8
        local speed = 1.5 + math.random() * 1.5
        local sz = math.random(1, 3)  -- varied particle sizes
        table.insert(particles, {
            x = px,
            y = py,
            dx = math.cos(angle) * speed,
            dy = math.sin(angle) * speed,
            timer = PARTICLE_DURATION,
            size = sz,
            useDither = (math.random() < 0.3),  -- 30% use dither instead of solid
            color = (math.random() > 0.5),  -- randomized black/white
        })
    end
end

function AnimManager.drawParticles()
    for _, p in ipairs(particles) do
        local sz = p.size or 2
        local px, py = math.floor(p.x), math.floor(p.y)
        if p.useDither then
            gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer4x4)
            gfx.fillRect(px, py, sz, sz)
        elseif p.color then
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRect(px, py, sz, sz)
        else
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRect(px, py, sz, sz)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRect(px - 1, py - 1, sz + 2, sz + 2)
        end
    end
    gfx.setColor(gfx.kColorBlack)
end

-- ─── Confetti ────────────────────────────────────────────────

function AnimManager.addConfetti()
    for i = 1, CONFETTI_COUNT do
        -- VFX: some confetti become tiny sparkle dots
        local isSparkle = VFXConfig and VFXConfig.enabled and VFXConfig.confettiSparkle.enabled
            and math.random() < (VFXConfig.confettiSparkle.ratio or 0.3)
        local sz = isSparkle
            and math.random(VFXConfig.confettiSparkle.minSize or 1, VFXConfig.confettiSparkle.maxSize or 2)
            or 3 + math.random(0, 3)
        table.insert(confetti, {
            x = math.random(10, 390),
            y = math.random(-40, -5),
            dy = 1.0 + math.random() * 1.5,
            driftX = (math.random() - 0.5) * 0.8,
            size = sz,
            pattern = isSparkle and 4 or math.random(1, 3),
            timer = CONFETTI_DURATION + math.random(0, 20)
        })
    end
end

function AnimManager.burstConfetti(cx, cy, count)
    for i = 1, count or 25 do
        local angle = math.random() * math.pi * 2
        local speed = 3.0 + math.random() * 6.0
        -- VFX: sparkle confetti in bursts too
        local isSparkle = VFXConfig and VFXConfig.enabled and VFXConfig.confettiSparkle.enabled
            and math.random() < (VFXConfig.confettiSparkle.ratio or 0.3)
        local sz = isSparkle
            and math.random(VFXConfig.confettiSparkle.minSize or 1, VFXConfig.confettiSparkle.maxSize or 2)
            or 3 + math.random(0, 4)
        table.insert(confetti, {
            x = cx,
            y = cy,
            dx = math.cos(angle) * speed,
            dy = math.sin(angle) * speed - 2.0, -- UPward bias
            gravity = 0.25,
            driftX = 0,
            size = sz,
            pattern = isSparkle and 4 or math.random(1, 3),
            timer = CONFETTI_DURATION + math.random(0, 10)
        })
    end
end

function AnimManager.drawConfetti()
    for _, c in ipairs(confetti) do
        local x, y = math.floor(c.x), math.floor(c.y)
        if c.pattern == 4 then
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRect(x, y, c.size, c.size)
        elseif c.pattern == 1 then
            gfx.setDitherPattern(0.5, gfx.image.kDitherTypeDiagonalLine)
            gfx.fillRect(x, y, c.size, c.size)
        elseif c.pattern == 2 then
            gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer4x4)
            gfx.fillRect(x, y, c.size, c.size)
        else
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRect(x, y, c.size, c.size)
        end
    end
    gfx.setColor(gfx.kColorBlack)
end

function AnimManager.hasConfetti()
    return #confetti > 0
end

--- Fire confetti from a grid of positions across the full screen.
--- Used to flood the display on level-clear so the board disappears behind
--- a wall of particles rather than flashing white.
function AnimManager.floodConfetti()
    -- 6×4 grid covers the full 400×240 screen
    local cols, rows = 6, 4
    for gx = 1, cols do
        for gy = 1, rows do
            local cx = math.floor(gx * 400 / (cols + 1))
            local cy = math.floor(gy * 240 / (rows + 1))
            AnimManager.burstConfetti(cx, cy, 25)
        end
    end
    -- Extra dense burst at board center
    AnimManager.burstConfetti(200, 120, 60)
end

--- Apply crank-driven wind to confetti: horizontal drift (left/right blow).
--- Stronger crank = stronger wind. This is the original feel.
function AnimManager.swirlConfetti(crankDelta)
    local drift = crankDelta * 0.28
    for _, c in ipairs(confetti) do
        c.driftX = (c.driftX or 0) + drift
    end
end

--- Set accelerometer-driven gravity for celebration confetti.
--- Call each frame during SCENE_LEVELCLEAR; call with (0,0) on exit.
--- Scale is intentionally subtle — tilt is a gentle nudge, not a force.
function AnimManager.setCelebAccel(ax, ay)
    local SCALE = 0.04
    celebGravX =  (ax or 0) * SCALE
    celebGravY = -(ay or 0) * SCALE   -- Playdate y+ = tilt toward user = up on screen
end

-- ─── Tile Intro ──────────────────────────────────────────────

function AnimManager.addTileIntro(gridSize)
    introTiles = {}
    local center = (gridSize + 1) / 2
    for r = 1, gridSize do
        for c = 1, gridSize do
            local dist = math.max(math.abs(r - center), math.abs(c - center))
            introTiles[r .. "," .. c] = {
                delay = math.floor(dist * INTRO_STAGGER),
                timer = 0
            }
        end
    end
end

--- Returns scale factor for tile at (r,c) during intro. 1.0 = fully visible.
--- Returns nil if tile is not in intro mode (draw normally).
function AnimManager.getIntroScale(r, c)
    local info = introTiles[r .. "," .. c]
    if not info then return nil end
    if info.delay > 0 then return 0 end  -- not started yet — invisible
    local t = info.timer / INTRO_PER_TILE
    -- Ease-out back (slight overshoot)
    local s = 1.70158
    t = t - 1
    return (t * t * ((s + 1) * t + s) + 1)
end

function AnimManager.isIntroActive()
    for _ in pairs(introTiles) do return true end
    return false
end

-- ─── Floating Tiles (Splash Screen) ─────────────────────────

function AnimManager.initFloaters(highestLevel)
    floaters = {}
    -- Force even distribution: 4 positive, 4 negative, 4 zero
    local maxVal = 1
    if (highestLevel or 1) >= 3 then maxVal = 3
    elseif (highestLevel or 1) >= 2 then maxVal = 2 end
    
    local forcedValues = {}
    for i = 1, 6 do
        table.insert(forcedValues, math.random(1, maxVal))   -- positive
        table.insert(forcedValues, -math.random(1, maxVal))  -- negative
    end
    -- Shuffle array (we already just insert randomly, but good enough)

    for i = 1, 12 do
        local size = 16 + math.random(0, 20)
        local angleRad = math.random() * math.pi * 2
        local speed = 0.5 + math.random() * 1.5
        table.insert(floaters, {
            x = math.random(20, 380),
            y = math.random(20, 220),
            dx = math.cos(angleRad) * speed,
            dy = math.sin(angleRad) * speed,
            value = forcedValues[i],
            size = size
        })
    end
end

function AnimManager.getFloaters()
    return floaters
end

-- ─── Celebration Tile Floaters (Level Clear Screen) ──────────

--- Spawn celebration tile floaters using values from the current level.
--- values: flat array of tile values to sample from (e.g. engine.state grid values)
function AnimManager.initCelebFloaters(values)
    celebFloaters = {}
    local pool = values or {1, -1, 2, -2, 1, -1}

    -- Stratified spawn: 4 cols × 4 rows grid, shuffle and take first 14 slots
    -- so tiles start evenly spread across the screen instead of clustering.
    local COLS, ROWS = 4, 4
    local cellW = 400 / COLS   -- 100
    local cellH = 240 / ROWS   -- 60
    local slots = {}
    for r = 0, ROWS - 1 do
        for c = 0, COLS - 1 do
            table.insert(slots, {col = c, row = r})
        end
    end
    -- Fisher-Yates shuffle
    for i = #slots, 2, -1 do
        local j = math.random(1, i)
        slots[i], slots[j] = slots[j], slots[i]
    end

    local count = math.min(8, MAX_FLOATERS)
    for i = 1, count do
        local slot = slots[i]
        -- Full-cell jitter: tiles can land anywhere in their cell
        local jitterX = math.random() * cellW * 0.85
        local jitterY = math.random() * cellH * 0.85
        local sx = slot.col * cellW + cellW * 0.075 + jitterX
        local sy = slot.row * cellH + cellH * 0.075 + jitterY
        local v = pool[math.random(1, #pool)]
        local size = 14 + math.random(0, 20)
        local angleRad = math.random() * math.pi * 2
        -- Wider speed range: slow drifters and fast flyers prevent lockstep clustering
        local speed = 0.4 + math.random() * 4.0
        -- Per-tile damping variation: fast tiles slow sooner, slow tiles coast longer
        local damp = 0.982 + math.random() * 0.014
        table.insert(celebFloaters, {
            x        = sx,
            y        = sy,
            dx       = math.cos(angleRad) * speed,
            dy       = math.sin(angleRad) * speed,
            value    = v,
            size     = size,
            spin     = (math.random() - 0.5) * 6,
            angle    = math.random(0, 360),
            damp     = damp,
            lifetime = 120 + math.random(0, 90),  -- 4-7 s at 30 fps
        })
    end
end

--- Append extra floaters mid-celebration (for frenzy bursts).
function AnimManager.addMoreFloaters(count)
    -- Build pool from existing floaters so new ones match what's on screen
    local pool = {}
    for _, f in ipairs(celebFloaters) do table.insert(pool, f.value) end
    if #pool == 0 then pool = {1, -1, 2, -2, 0} end

    local toAdd = math.min(count, MAX_FLOATERS - #celebFloaters)
    for i = 1, toAdd do
        local sx = math.random(20, 380)
        local sy = math.random(10, 230)
        local v  = pool[math.random(1, #pool)]
        local sz = 14 + math.random(0, 20)
        local a  = math.random() * math.pi * 2
        local spd = 2.0 + math.random() * 5.0
        table.insert(celebFloaters, {
            x        = sx, y = sy,
            dx       = math.cos(a) * spd, dy = math.sin(a) * spd,
            value    = v, size = sz,
            spin     = (math.random() - 0.5) * 10,
            angle    = math.random(0, 360),
            damp     = 0.985 + math.random() * 0.010,
            lifetime = 120 + math.random(0, 90),
        })
    end
end

--- Spawn a single floater at a random position (used for slow crank trickle).
function AnimManager.spawnOneFloater()
    if #celebFloaters >= MAX_FLOATERS then return end
    local pool = {}
    for _, f in ipairs(celebFloaters) do table.insert(pool, f.value) end
    if #pool == 0 then pool = {1, -1, 2, -2, 0} end
    local sx  = math.random(20, 380)
    local sy  = math.random(10, 230)
    local a   = math.random() * math.pi * 2
    local spd = 0.6 + math.random() * 2.0   -- slower than frenzy-spawned tiles
    table.insert(celebFloaters, {
        x        = sx, y = sy,
        dx       = math.cos(a) * spd, dy = math.sin(a) * spd,
        value    = pool[math.random(1, #pool)],
        size     = 14 + math.random(0, 20),
        spin     = (math.random() - 0.5) * 4,
        angle    = math.random(0, 360),
        damp     = 0.984 + math.random() * 0.012,
        lifetime = 120 + math.random(0, 90),
    })
end

--- Update celebration floaters: physics + crank wind + subtle accelerometer tilt.
--- ax, ay: accelerometer axes (Playdate: x=tilt right, y=tilt toward user → screen-bottom gravity)
function AnimManager.updateCelebFloaters(crankDelta, ax, ay)
    -- Accelerometer: very subtle gravity — a gentle lean, not a force
    local ACCEL_SCALE = 0.08
    local MAX_SPEED   = 5.5
    local MIN_SPEED   = 0.8   -- tiles never fully stop; higher = more lively
    local SPIN_WIND_K = 0.12  -- spin torque per unit of horizontal wind force
    local gx = ax and (ax * ACCEL_SCALE) or 0
    local gy = ay and (-ay * ACCEL_SCALE) or 0   -- Playdate y+ = tilt toward user = up on screen

    -- Crank: horizontal wind impulse (same direction/sign as confetti wind)
    local windX = 0
    if crankDelta and math.abs(crankDelta) > 2 then
        windX = crankDelta * 0.14
    end

    for _, f in ipairs(celebFloaters) do
        -- Wind from crank — each tile gets its own slight variation to prevent lockstep
        local fw = windX * (0.8 + math.random() * 0.4)
        f.dx = f.dx + fw

        -- Spin torque: positive wind (right) → clockwise (+spin), negative → counter-clockwise
        local targetSpin = fw * SPIN_WIND_K * 60
        f.spin = f.spin + (targetSpin - f.spin) * 0.08

        -- Tilt gravity (subtle per-tile variation to spread out)
        local tiltVar = 0.8 + math.random() * 0.4
        f.dx = f.dx + gx * tiltVar
        f.dy = f.dy + gy * tiltVar

        -- Per-tile damping: tiles have different drag so they spread at different rates
        local d = f.damp or 0.990
        f.dx = f.dx * d
        f.dy = f.dy * (d + 0.003)  -- slightly less vertical drag keeps them floating

        -- Speed cap
        local spd = math.sqrt(f.dx * f.dx + f.dy * f.dy)
        if spd > MAX_SPEED then
            f.dx = f.dx / spd * MAX_SPEED
            f.dy = f.dy / spd * MAX_SPEED
        end

        -- Minimum speed: tiles keep drifting, never fully stall
        if spd < MIN_SPEED then
            if spd > 0.01 then
                local sc = MIN_SPEED / spd
                f.dx = f.dx * sc
                f.dy = f.dy * sc
            else
                local a = math.random() * math.pi * 2
                f.dx = math.cos(a) * MIN_SPEED
                f.dy = math.sin(a) * MIN_SPEED
            end
        end

        f.x = f.x + f.dx
        f.y = f.y + f.dy
        f.spin  = f.spin * 0.985
        f.angle = (f.angle + f.spin) % 360

        -- Bounce off walls
        if f.x < 0 then f.x = 0; f.dx = math.abs(f.dx) end
        if f.x + f.size > 400 then f.x = 400 - f.size; f.dx = -math.abs(f.dx) end
        if f.y < 0 then f.y = 0; f.dy = math.abs(f.dy) end
        if f.y + f.size > 260 then f.y = 260 - f.size; f.dy = -math.abs(f.dy) end
    end

    -- Mild repulsion: tiles that overlap push each other apart
    for i = 1, #celebFloaters do
        local fi = celebFloaters[i]
        for j = i + 1, #celebFloaters do
            local fj = celebFloaters[j]
            local dx   = fj.x - fi.x
            local dy   = fj.y - fi.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local minD = (fi.size + fj.size) * 0.55
            if dist < minD and dist > 0.5 then
                local force = (minD - dist) / minD * 0.25
                local nx = dx / dist
                local ny = dy / dist
                fi.dx = fi.dx - nx * force
                fi.dy = fi.dy - ny * force
                fj.dx = fj.dx + nx * force
                fj.dy = fj.dy + ny * force
            end
        end
    end

    -- Lifetime: count down, spin up as tile nears death, pop on expiry
    local i = #celebFloaters
    while i >= 1 do
        local f = celebFloaters[i]
        if f.lifetime then
            f.lifetime = f.lifetime - 1
            -- Spin-up telegraph: tile starts spinning faster in last ~0.8s
            if f.lifetime <= 24 and f.lifetime > 0 then
                local urgency = 1.0 - f.lifetime / 24
                f.spin = f.spin + (math.random() - 0.5) * urgency * 3
            end
            if f.lifetime <= 0 then
                -- Pop: small confetti burst at tile centre
                AnimManager.burstConfetti(
                    math.floor(f.x + f.size * 0.5),
                    math.floor(f.y + f.size * 0.5), 4)
                table.remove(celebFloaters, i)
            end
        end
        i = i - 1
    end

    -- Slow crank trickle: accumulate crank degrees, spawn 1 tile per ~25°
    if crankDelta and math.abs(crankDelta) > 1 then
        floaterCrankAccum = floaterCrankAccum + math.abs(crankDelta) * 0.04
        if floaterCrankAccum >= 1.0 then
            floaterCrankAccum = floaterCrankAccum - 1.0
            AnimManager.spawnOneFloater()
        end
    end
end

--- Returns the celebration floaters array for main.lua to render.
function AnimManager.getCelebFloaters()
    return celebFloaters
end

--- Clear celebration floaters (call when leaving level-clear scene).
function AnimManager.clearCelebFloaters()
    celebFloaters = {}
    celebGravX = 0
    celebGravY = 0
    floaterCrankAccum = 0
end

-- ─── Light streaks (frenzy lasers) ───────────────────────────

--- Spawn `count` streaks. They shoot horizontally across the screen with a
--- slight angle, entering from one side and exiting the other.
function AnimManager.addStreaks(count)
    for _ = 1, count do
        local fromLeft = math.random() > 0.5
        local sx   = fromLeft and -10 or 410
        local sy   = math.random(8, 232)
        local ang  = math.rad(math.random(-30, 30))
        local dirX = fromLeft and 1 or -1
        local ndx  = dirX * math.cos(ang)
        local ndy  = math.sin(ang)
        local spd  = 38 + math.random() * 28    -- 38-66 px/frame: fast zap
        local maxT = 7 + math.random(0, 5)
        table.insert(streaks, {
            x = sx, y = sy,
            ndx = ndx, ndy = ndy,
            speed = spd,
            timer = maxT, maxTimer = maxT,
        })
    end
end

--- Update positions and draw all active streaks. Call once per frame during
--- level-clear rendering, after confetti and before the dialog box.
function AnimManager.updateAndDrawStreaks()
    local TAIL = 80    -- tail length in pixels
    local i = 1
    while i <= #streaks do
        local st = streaks[i]
        st.x = st.x + st.ndx * st.speed
        st.y = st.y + st.ndy * st.speed
        st.timer = st.timer - 1

        if st.timer <= 0 or st.x < -TAIL - 10 or st.x > 410 + TAIL then
            table.remove(streaks, i)
        else
            -- Fade factor: streak dims as it ages (1.0 → 0 over lifetime)
            local fade = st.timer / st.maxTimer

            -- Tail: three segments with increasing density toward the head
            -- Segment positions along the trail (tail → head)
            local tx0 = st.x - st.ndx * TAIL
            local ty0 = st.y - st.ndy * TAIL
            local tx1 = st.x - st.ndx * (TAIL * 0.55)
            local ty1 = st.y - st.ndy * (TAIL * 0.55)
            local tx2 = st.x - st.ndx * (TAIL * 0.18)
            local ty2 = st.y - st.ndy * (TAIL * 0.18)

            -- Ghost tail
            gfx.setDitherPattern(0.15 * fade, gfx.image.kDitherTypeBayer8x8)
            gfx.setLineWidth(1)
            gfx.drawLine(math.floor(tx0), math.floor(ty0), math.floor(tx1), math.floor(ty1))

            -- Mid trail
            gfx.setDitherPattern(0.5 * fade, gfx.image.kDitherTypeBayer8x8)
            gfx.setLineWidth(1)
            gfx.drawLine(math.floor(tx1), math.floor(ty1), math.floor(tx2), math.floor(ty2))

            -- Solid head
            gfx.setColor(gfx.kColorBlack)
            gfx.setLineWidth(2)
            gfx.drawLine(math.floor(tx2), math.floor(ty2), math.floor(st.x), math.floor(st.y))

            -- Bright tip dot
            gfx.fillCircleAtPoint(math.floor(st.x), math.floor(st.y), 2)

            gfx.setColor(gfx.kColorBlack)
            gfx.setLineWidth(1)
            i = i + 1
        end
    end
end

--- Clear all streaks (call when leaving level-clear scene).
function AnimManager.clearStreaks()
    streaks = {}
end

-- ─── Whirlpool / swirl (sustained crank+shake combo) ─────────
--
-- Draws a spinning mandala of concentric arc arms centred on screen.
-- Inner rings rotate faster than outer ones (real vortex physics).
-- Outer rings are dithered so they fade like water. Builds up, holds
-- as long as the combo is sustained, then fades out when released.

local SWIRL_RINGS = 8
local SWIRL_ARMS  = 5
local SWIRL_ARC   = 52    -- degrees per arm arc
local SWIRL_MAX_R = 215   -- radius of outermost ring at full intensity

function AnimManager.triggerMelt()
    local ringAngles = {}
    for r = 1, SWIRL_RINGS do
        ringAngles[r] = math.random(0, 359)
    end
    meltState = {
        ringAngles = ringAngles,
        timer     = 0,
        phase     = "build",   -- build → hold → fade
        intensity = 0.0,
    }
end

--- Sustain the swirl: keeps it in "hold" as long as you're still going.
--- Call every frame the combo is active; stop calling to begin fade.
function AnimManager.sustainMelt()
    if meltState and meltState.phase == "fade" then
        meltState.phase = "hold"   -- un-fade if they start again
    end
end

--- Begin fading the swirl out (call when combo drops below threshold).
function AnimManager.releaseMelt()
    if meltState and meltState.phase == "hold" then
        meltState.phase = "fade"
    end
end

--- Draw and advance the swirl. Call after confetti/streaks, before dialog.
function AnimManager.updateAndDrawMelt()
    if not meltState then return end
    local ms = meltState
    ms.timer = ms.timer + 1

    -- Phase transitions
    if ms.phase == "build" then
        ms.intensity = math.min(1.0, ms.intensity + 0.045)
        if ms.intensity >= 1.0 then ms.phase = "hold" end
    elseif ms.phase == "fade" then
        ms.intensity = math.max(0.0, ms.intensity - 0.04)
        if ms.intensity <= 0.0 then meltState = nil; return end
    end
    -- "hold": intensity stays at 1.0 until releaseMelt() is called

    -- Spin each ring: inner ones faster (vortex), modulated by intensity
    for r = 1, SWIRL_RINGS do
        local speedFrac = (SWIRL_RINGS - r + 1) / SWIRL_RINGS  -- 1.0 = inner
        ms.ringAngles[r] = (ms.ringAngles[r] + 4.5 * speedFrac * ms.intensity) % 360
    end

    -- Draw rings outermost-first so inner arcs paint over outer ones
    for r = SWIRL_RINGS, 1, -1 do
        local radius = math.floor(r * SWIRL_MAX_R / SWIRL_RINGS * ms.intensity)
        if radius < 4 then goto nextRing end

        local outerFrac = r / SWIRL_RINGS   -- 1.0 = outermost
        -- Outer rings fade with dither; inner rings stay solid
        if outerFrac > 0.55 then
            local density = (1.0 - outerFrac) * 2.2 * ms.intensity
            gfx.setDitherPattern(math.min(1.0, density), gfx.image.kDitherTypeBayer8x8)
        else
            gfx.setColor(gfx.kColorBlack)
        end
        gfx.setLineWidth(r <= 3 and 2 or 1)

        local armSpacing = 360 / SWIRL_ARMS
        for arm = 0, SWIRL_ARMS - 1 do
            local sa = ms.ringAngles[r] + arm * armSpacing
            gfx.drawArc(200, 120, radius, sa, sa + SWIRL_ARC)
        end

        ::nextRing::
    end

    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)
end

function AnimManager.isMeltActive()
    return meltState ~= nil
end

--- Returns true during the hold phase — used to gate bonus point ticks.
function AnimManager.isMeltHolding()
    return meltState ~= nil and meltState.phase == "hold"
end

function AnimManager.clearMelt()
    meltState = nil
end

--- heroCX, heroCY: pixel center of the hero neutral tile.
function AnimManager.setCrankOrbit(crankDelta, heroCX, heroCY)
    orbitHeroCX = heroCX
    orbitHeroCY = heroCY
    -- Physics: crank adds force to velocity instead of setting angle directly
    orbitVelocity = orbitVelocity + crankDelta * 0.12
    orbitVelocity = math.max(-10, math.min(10, orbitVelocity))
    
    -- Increase blend when cranking (so backward cranking also works)
    if math.abs(crankDelta) > 0.5 then
        orbitBlend = math.min(1.0, orbitBlend + 0.08)
    else
        -- Decay blend gracefully if undocked but not actively turning
        orbitBlend = math.max(0.0, orbitBlend - 0.015)
    end
end

--- Call each frame when crank is docked (release tiles back to free float).
function AnimManager.releaseCrankOrbit()
    orbitBlend = math.max(0.0, orbitBlend - 0.03)
end

function AnimManager.getOrbitBlend()
    return orbitBlend
end

-- ─── Shuffle Box Stream ──────────────────────────────────────

function AnimManager.startShuffle(oldVal, newVal, engine)
    jackboxAnim = {
        timer      = 0,
        phase      = "stream",
        tiles      = {},           -- in-flight tiles: {val, age}
        oldVal     = oldVal,
        newVal     = newVal,
        displayVal = oldVal,
        flipEvent  = nil,
        nextFlip   = JB_FLIP_FAST,
        streamDone = false,
        landPop    = 0,
        engine     = engine,
    }
end

function AnimManager.isShuffling()
    return jackboxAnim ~= nil
end

function AnimManager.getShuffleFlipVal()
    return jackboxAnim and jackboxAnim.flipEvent or nil
end

function AnimManager.getShuffleDisplayVal()
    return jackboxAnim and jackboxAnim.displayVal or nil
end

--- Preview scale: pulses on each tile landing; full overshoot pop on final landing.
function AnimManager.getShufflePreviewScale()
    if not jackboxAnim then return nil end
    if jackboxAnim.phase == "stream" then
        if jackboxAnim.landPop > 0 then
            local t = jackboxAnim.landPop / JB_LAND_POP
            return 1.0 + 0.15 * t   -- small pulse per tile
        end
        return 1.0
    elseif jackboxAnim.phase == "pop" then
        local t = jackboxAnim.timer / JB_POP_FRAMES
        return 1.0 + 0.4 * (1 - t) * (1 - t)
    end
    return 1.0
end

function AnimManager.isShuffleCooldown()
    return jackboxCooldown > 0
end

--- Returns in-flight tile draw data, or nil when no stream is active.
--- boxTopY: y of box top edge (where tiles emerge from).
--- cellCX, cellCY: center of destination preview cell.
function AnimManager.getJackboxStreamTiles(boxCX, boxTopY, cellCX, cellCY)
    if not jackboxAnim or jackboxAnim.phase ~= "stream" then return nil end
    local result = {}
    for _, tile in ipairs(jackboxAnim.tiles) do
        local t = tile.age / JB_TILE_TRAVEL
        -- Ease out: fast at launch, decelerates as it arrives
        local easedT = 1 - (1 - t) * (1 - t)
        local x = boxCX + (cellCX - boxCX) * t   -- box and cell share same x, so effectively 0 drift
        local y = boxTopY + (cellCY - boxTopY) * easedT
        -- Tile grows from small (launching) to full size as it arrives
        local sz = math.max(16, math.floor(16 + (36 - 16) * t))  -- min 16px so corners always visible
        table.insert(result, {
            x   = math.floor(x - sz / 2),
            y   = math.floor(y - sz / 2),
            val = tile.val,
            size = sz,
        })
    end
    return result
end

--- Draw the shuffle box (flat 2D rect, shuffle icon, crank indicator on bottom).
--- cx: horizontal center, bodyY: top of box.
function AnimManager.drawJackbox(cx, bodyY)
    local x1 = cx - math.floor(JB_W / 2)
    local x2 = cx + math.floor(JB_W / 2)
    local y2 = bodyY + JB_H

    -- Box fill + border (rounded)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(x1, bodyY, JB_W, JB_H, JB_R)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)
    gfx.drawRoundRect(x1, bodyY, JB_W, JB_H, JB_R)

    -- Shuffle icon: 14×14 centered in 32×32 box (9px margin each side).
    local ox = cx - 7
    local oy = bodyY + 9
    gfx.setLineWidth(2)
    -- Long diagonal: bottom-left to top-right
    gfx.drawLine(ox + 2, oy + 13, ox + 13, oy + 2)
    -- Top-right L-arrow
    gfx.drawLine(ox + 10, oy + 2, ox + 13, oy + 2)
    gfx.drawLine(ox + 13, oy + 2, ox + 13, oy + 5)
    -- Top-left stub
    gfx.drawLine(ox + 2, oy + 2, ox + 6, oy + 6)
    -- Bottom-right stub
    gfx.drawLine(ox + 9, oy + 9, ox + 13, oy + 13)
    -- Bottom-right L-arrow
    gfx.drawLine(ox + 13, oy + 9, ox + 13, oy + 13)
    gfx.drawLine(ox + 13, oy + 13, ox + 10, oy + 13)
    gfx.setLineWidth(1)
end

function AnimManager.startPlasmaBeam() end   -- no-op stub
function AnimManager.drawPlasmaBeam() end    -- no-op stub
function AnimManager.isPlasmaBeamActive() return false end

-- ─── Hollow Shuffle Icon Drawing ─────────────────────────────

--- Draw the shuffle icon (always solid) at (cx, cy).
--- fillPct (0-1): crank progress toward shuffle.
--- rerolls: number of remaining shuffles (for pip display).
function AnimManager.drawShuffleIcon(cx, cy, fillPct, rerolls, crankAngle)
    local iconW, iconH = 28, 18
    local x1 = cx - iconW / 2
    local x2 = cx + iconW / 2
    local y1 = cy - iconH / 2
    local y2 = cy + iconH / 2

    -- 1) Shuffle icon (fills visually with crank)
    gfx.setLineWidth(3)
    
    local function drawArrows()
        gfx.drawLine(x1, y1, x2, y2)
        gfx.drawLine(x1, y2, x2, y1)
        local aLen = 7
        gfx.drawLine(x2, y1, x2 - aLen, y1)
        gfx.drawLine(x2, y1, x2, y1 + aLen)
        gfx.drawLine(x2, y2, x2 - aLen, y2)
        gfx.drawLine(x2, y2, x2, y2 - aLen)
    end

    if rerolls <= 0 then
        -- Empty state (diagonal dither)
        gfx.setDitherPattern(0.5, gfx.image.kDitherTypeDiagonalLine)
        drawArrows()
    else
        -- Unfilled state (faint dither)
        gfx.setDitherPattern(0.1, gfx.image.kDitherTypeBayer8x8)
        drawArrows()
        
        -- Filled state: animated dither sweep instead of solid black
        if fillPct > 0 then
            local maxH = iconH + 8
            local fillArea = math.floor(fillPct * maxH)
            gfx.setClipRect(x1 - 8, y2 + 4 - fillArea, iconW + 16, fillArea)
            -- Cycle dither pattern as fill progresses for energy feel
            local sweepPhase = math.floor(fillPct * 12) % 3
            if sweepPhase == 0 then
                gfx.setColor(gfx.kColorBlack)
            elseif sweepPhase == 1 then
                gfx.setDitherPattern(0.15, gfx.image.kDitherTypeBayer4x4)
            else
                gfx.setColor(gfx.kColorBlack)
            end
            drawArrows()
            gfx.clearClipRect()
        end
    end

    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)

    -- 2) Progress bar beneath icon with sci-fi scanlines
    local barW = 30
    local barH = 4
    local barX = cx - barW / 2
    local barY = cy + iconH / 2 + 6
    gfx.drawRoundRect(barX, barY, barW, barH, 1)
    if fillPct > 0 and rerolls > 0 then
        local fillW = math.max(3, math.floor(fillPct * barW))
        -- Scanline effect: alternate solid/dither rows
        gfx.fillRoundRect(barX, barY, fillW, barH, 1)
        if fillW > 6 then
            gfx.setColor(gfx.kColorWhite)
            gfx.drawLine(barX + 1, barY + 1, barX + fillW - 2, barY + 1)  -- scanline
            gfx.setColor(gfx.kColorBlack)
        end
    end

    -- 3) Spinning crank knob attached to progress bar
    local knobR = 3
    local axleLen = 2
    local knobCX = barX + barW + axleLen + knobR
    local knobCY = barY + barH / 2

    -- Draw axle connecting bar to crank
    gfx.drawLine(barX + barW, knobCY, knobCX - knobR, knobCY)

    -- Crank knob with glow when filling
    if fillPct > 0.1 and rerolls > 0 then
        -- Dithered glow ring around knob when active
        gfx.setDitherPattern(0.3, gfx.image.kDitherTypeBayer4x4)
        gfx.fillCircleAtPoint(knobCX, knobCY, knobR + 3)
        gfx.setColor(gfx.kColorBlack)
    end
    gfx.drawCircleAtPoint(knobCX, knobCY, knobR)

    local handleRad = math.rad(crankAngle or 0)
    local hx = knobCX + math.cos(handleRad) * (knobR + 1)
    local hy = knobCY + math.sin(handleRad) * (knobR + 1)
    local hx2 = knobCX + math.cos(handleRad) * (knobR + 5)
    local hy2 = knobCY + math.sin(handleRad) * (knobR + 5)
    gfx.drawLine(hx, hy, hx2, hy2)
    gfx.fillCircleAtPoint(hx2, hy2, 2)

    -- 4) Shuffle pips below bar (two rows of up to 4)
    local pipStartY = barY + barH + 8
    local pipR = 2
    local pipSpacingX = 8
    local pipSpacingY = 8
    local rowCols = 4

    for i = 1, rerolls do
        local idx = i - 1
        local row = math.floor(idx / rowCols)
        local col = idx % rowCols

        local pipsInThisRow = math.min(rowCols, rerolls - row * rowCols)
        local totalPipW = (pipsInThisRow - 1) * pipSpacingX
        local pipStartX = cx - totalPipW / 2

        local px = pipStartX + col * pipSpacingX
        local py = pipStartY + row * pipSpacingY

        gfx.fillCircleAtPoint(px, py, pipR)
    end
end

-- ─── Spawn Pop (tile born spring animation) ─────────────────

function AnimManager.addSpawnPop(r, c)
    spawnPops[r .. "," .. c] = 0
end

--- Returns elastic overshoot spring scale for newly spawned tile. nil = no pop active.
function AnimManager.getSpawnPopScale(r, c)
    local t = spawnPops[r .. "," .. c]
    if t == nil then return nil end
    local p = t / SPAWN_POP_DURATION
    local s = 2.0
    local p2 = p - 1
    return math.max(0, p2 * p2 * ((s + 1) * p2 + s) + 1)
end

function AnimManager.addNeutralPop(r, c)
    neutralPops[r .. "," .. c] = 0
end

--- Returns scale for neutral tile pop: grows to 1.3 then eases back to 1.0. nil = no pop active.
function AnimManager.getNeutralPopScale(r, c)
    local t = neutralPops[r .. "," .. c]
    if t == nil then return nil end
    local p = t / NEUTRAL_POP_DURATION
    -- sine arch: peaks at midpoint, returns to 1.0 at end
    return 1.0 + 0.3 * math.sin(p * math.pi)
end

-- ─── Ripple Rings (neutralize shockwave) ──────────────────────

function AnimManager.addRipple(cx, cy)
    table.insert(ripples, {cx=cx, cy=cy, timer=0})
    table.insert(ripples, {cx=cx, cy=cy, timer=-5})  -- second ring, delayed
end

function AnimManager.drawRipples()
    for _, rp in ipairs(ripples) do
        if rp.timer > 0 then
            local t = rp.timer / RIPPLE_DURATION
            local radius = math.max(1, math.floor(t * 34))
            local fade = 1.0 - t
            gfx.setLineWidth(math.max(1, math.floor(fade * 3)))
            if fade > 0.55 then
                gfx.setColor(gfx.kColorBlack)
            else
                gfx.setDitherPattern(math.max(0.05, fade * 1.6), gfx.image.kDitherTypeBayer4x4)
            end
            gfx.drawCircleAtPoint(math.floor(rp.cx), math.floor(rp.cy), radius)
        end
    end
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
end

-- ─── Clear Sweep (level-end tile implosion) ───────────────────

--- Tiles implode from outside→in, staggered by distance from center.
function AnimManager.startClearSweep(gridSize)
    clearSweep = {}
    sweepActive = true
    local center = (gridSize + 1) / 2
    for r = 1, gridSize do
        for c = 1, gridSize do
            local dist = math.max(math.abs(r - center), math.abs(c - center))
            local delay = math.floor((3 - dist) * SWEEP_STAGGER)  -- outer first
            clearSweep[r .. "," .. c] = {timer = -math.max(0, delay), maxTimer = SWEEP_DURATION}
        end
    end
end

--- Returns 1.0→0 scale as tile implodes. nil = sweep not active.
function AnimManager.getClearSweepScale(r, c)
    if not sweepActive then return nil end
    local info = clearSweep[r .. "," .. c]
    if not info then return nil end
    if info.timer <= 0 then return 1.0 end
    local t = info.timer / info.maxTimer
    return math.max(0, 1.0 - t * t * t)  -- ease-in cubic
end

function AnimManager.isClearSweepActive()
    return sweepActive
end

function AnimManager.clearSweepTotalDuration()
    return SWEEP_DURATION + 3 * SWEEP_STAGGER + 6
end

-- ─── D-Pad Ghost Arrow ────────────────────────────────────────

function AnimManager.addDpadGhost(dx, dy)
    dpadGhost = {dx=dx, dy=dy, timer=DPAD_GHOST_DURATION}
end

--- Draw a fading directional arrow overlaid on the board.
function AnimManager.drawDpadGhost(boardCX, boardCY)
    if not dpadGhost or dpadGhost.timer <= 0 then return end
    local fade = dpadGhost.timer / DPAD_GHOST_DURATION
    local dx, dy = dpadGhost.dx, dpadGhost.dy
    local reach = 52 * fade
    local ax = boardCX + dx * reach
    local ay = boardCY + dy * reach
    local tailX = boardCX + dx * (reach * 0.35)
    local tailY = boardCY + dy * (reach * 0.35)
    gfx.setDitherPattern(math.max(0.05, fade * 0.65), gfx.image.kDitherTypeBayer4x4)
    gfx.setLineWidth(3)
    gfx.drawLine(math.floor(tailX), math.floor(tailY), math.floor(ax), math.floor(ay))
    local perpX = -dy * 9 * fade
    local perpY = dx * 9 * fade
    gfx.drawLine(math.floor(ax), math.floor(ay),
        math.floor(ax - dx*13*fade + perpX), math.floor(ay - dy*13*fade + perpY))
    gfx.drawLine(math.floor(ax), math.floor(ay),
        math.floor(ax - dx*13*fade - perpX), math.floor(ay - dy*13*fade - perpY))
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
end

-- ─── Energy Rings (crank fully charged) ──────────────────────

--- Spawn 3 expanding concentric rings from (cx,cy). Call once when fillPct hits 1.0.
function AnimManager.triggerEnergyRings(cx, cy)
    energyRings = {}
    for i = 1, 3 do
        table.insert(energyRings, {timer = -(i - 1) * 6, cx = cx, cy = cy})
    end
end

function AnimManager.clearEnergyRings()
    energyRings = {}
end

function AnimManager.drawEnergyRings()
    for _, er in ipairs(energyRings) do
        if er.timer > 0 then
            local t = er.timer / ENERGY_RING_DURATION
            local radius = math.max(1, math.floor(t * 30))
            local fade = 1.0 - t
            gfx.setLineWidth(1)
            if fade > 0.5 then
                gfx.setColor(gfx.kColorBlack)
            else
                gfx.setDitherPattern(math.max(0.05, fade * 1.8), gfx.image.kDitherTypeBayer4x4)
            end
            gfx.drawCircleAtPoint(math.floor(er.cx), math.floor(er.cy), radius)
        end
    end
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
end

-- ─── Iris Transition ─────────────────────────────────────────

--- Start an iris-out → callback → iris-in transition.
function AnimManager.startIris(callback)
    irisDir = 1  -- closing
    irisTimer = 0
    irisDuration = IRIS_DURATION
    irisCallback = callback
end

--- Draw the iris mask. Call at end of frame after all scene rendering.
function AnimManager.drawIris()
    if irisDir == 0 then return end

    local progress = irisTimer / irisDuration
    local maxRadius = 220  -- enough to cover 400x240 from center

    local radius
    if irisDir == 1 then
        -- Closing: large → small
        radius = maxRadius * (1 - progress)
    else
        -- Opening: small → large
        radius = maxRadius * progress
    end

    local r = math.max(1, math.floor(radius))

    -- Draw black mask with circular hole
    local img = gfx.image.new(400, 240, gfx.kColorBlack)
    gfx.pushContext(img)
        gfx.setColor(gfx.kColorClear)
        gfx.fillCircleAtPoint(200, 120, r)
    gfx.popContext()
    img:draw(0, 0)

    -- Dithered ripple ring just inside the iris edge
    if r > 8 then
        local ditherTypes = {
            gfx.image.kDitherTypeBayer4x4,
            gfx.image.kDitherTypeBayer8x8,
            gfx.image.kDitherTypeDiagonalLine,
        }
        local dt = ditherTypes[math.floor(progress * 6) % 3 + 1]
        gfx.setDitherPattern(0.4, dt)
        gfx.setLineWidth(3)
        gfx.drawCircleAtPoint(200, 120, r - 2)
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(1)
    end
end

function AnimManager.isTransitioning()
    return irisDir ~= 0 or tileWipePhase > 0
end

--- Tile wipe: neutral tile grows from center to fill screen, fires callback, then shrinks away.
function AnimManager.startTileWipe(callback)
    tileWipePhase = 1
    tileWipeTimer = 0
    tileWipeCallback = callback
end

function AnimManager.isTileWipeActive()
    return tileWipePhase > 0
end

--- Draw the tile wipe overlay. Call at end of frame.
function AnimManager.drawTileWipe(drawTileFn)
    if tileWipePhase == 0 then return end

    local cx, cy = 200, 120
    -- Max size needed to cover 400x240 from center: diagonal = ~450, use as full tile size
    local maxSize = 460
    local size

    if tileWipePhase == 1 then
        -- Ease-out quart grow
        local t = tileWipeTimer / TILE_WIPE_GROW
        local ease = 1 - (1 - t) * (1 - t) * (1 - t) * (1 - t)
        size = math.floor(50 + ease * (maxSize - 50))
    elseif tileWipePhase == 2 then
        size = maxSize
    else
        -- Ease-in shrink
        local t = tileWipeTimer / TILE_WIPE_SHRINK
        local ease = t * t * t * t
        size = math.floor(maxSize * (1 - ease))
    end

    if size < 4 then return end

    -- Draw rounded rect tile background covering the screen
    local px = cx - size / 2
    local py = cy - size / 2
    local r = math.max(4, math.floor(size * 0.06))
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(px, py, size, size, r)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(3)
    gfx.drawRoundRect(px, py, size, size, r)
    gfx.setLineWidth(2)

    -- Draw the neutral circle symbol, scaled to tile
    local cRad = math.max(2, math.floor(size * (7.0 / 24.0) * 0.5))
    gfx.setLineWidth(math.max(2, math.floor(3 * size / 50)))
    gfx.drawCircleAtPoint(cx, cy, cRad)
    gfx.setLineWidth(2)
end

-- ─── Reset ───────────────────────────────────────────────────

function AnimManager.clear()
    slides = {}
    shakeTimer = 0
    shakeOffX, shakeOffY = 0, 0
    flashes = {}
    scorePopTimer = 0
    particles = {}
    confetti = {}
    introTiles = {}
    irisTimer = 0
    irisDir = 0
    irisCallback = nil
    jackboxAnim = nil
    jackboxCooldown = 0
    spawnPops = {}
    neutralPops = {}
    ripples = {}
    clearSweep = {}
    sweepActive = false
    dpadGhost = nil
    energyRings = {}
    inputBlocked = false
end
