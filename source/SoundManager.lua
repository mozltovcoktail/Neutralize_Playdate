-- SoundManager.lua — Audio manager for Neutralize on Playdate
-- Uses playdate.sound.sampleplayer for pre-loaded WAV SFX.
-- Uses playdate.sound.fileplayer for streaming background music.

SoundManager = {}
SoundManager.__index = SoundManager

local players = {}       -- name → sampleplayer
local sfxEnabled   = true
local musicEnabled = true

-- Music state
local musicPlayer = nil  -- fileplayer for BGM
local musicVolume = 0.35 -- matches web AudioConfig.masterMusicVolume

-- Celebration music (one per level, 3 tracks)
local celebrationPlayers = {}
local celebrationVolume  = 0.45
local NUM_CELEBRATION_TRACKS = 3

-- Per-track volume multipliers (matches web AudioConfig.volumes)
local volumes = {
    move            = 1.0,
    shake           = 0.65,
    neutralize      = 0.65,
    button          = 0.72,
    menu            = 0.30,
    restart         = 0.32,
    merge           = 0.80,
    mergePartial    = 0.85,
    reroll_plus_1   = 0.55,
    reroll_plus_2   = 0.55,
    reroll_plus_3   = 0.55,
    reroll_minus_1  = 0.60,
    reroll_minus_2  = 0.60,
    reroll_minus_3  = 0.60,
}

-- All SFX file basenames (without .wav extension, stored in sfx/ folder)
local sfxNames = {
    "move", "shake", "neutralize", "button", "menu", "restart",
    "merge", "mergePartial",
    "reroll_plus_1", "reroll_plus_2", "reroll_plus_3",
    "reroll_minus_1", "reroll_minus_2", "reroll_minus_3",
}

function SoundManager.init()
    -- Load SFX (sampleplayer — fully in memory, instant playback)
    for _, name in ipairs(sfxNames) do
        local path = "sfx/" .. name
        local player = playdate.sound.sampleplayer.new(path)
        if player then
            player:setVolume(volumes[name] or 1.0)
            players[name] = player
        else
            print("[SoundManager] Failed to load: " .. path)
        end
    end

    -- Load BGM (fileplayer — streams from disk, ideal for long tracks)
    musicPlayer = playdate.sound.fileplayer.new("music/bgm")
    if musicPlayer then
        musicPlayer:setVolume(musicVolume)
        musicPlayer:setStopOnUnderrun(false) -- keep playing if SFX causes a brief stall
    else
        print("[SoundManager] Failed to load music/bgm")
    end

    -- Load celebration tracks (one per level)
    for i = 1, NUM_CELEBRATION_TRACKS do
        local path = "music/celebration_" .. i
        local p = playdate.sound.fileplayer.new(path)
        if p then
            p:setVolume(celebrationVolume)
            p:setStopOnUnderrun(false)
            celebrationPlayers[i] = p
        else
            print("[SoundManager] Failed to load " .. path)
        end
    end
end

function SoundManager.play(name)
    if not sfxEnabled then return end
    local player = players[name]
    if player then
        player:play()
    end
end

-- ── Granular toggles ─────────────────────────────────────────

function SoundManager.setSfxEnabled(on)
    sfxEnabled = on
    if not on then
        for _, player in pairs(players) do player:stop() end
    end
end

function SoundManager.setMusicEnabled(on)
    musicEnabled = on
    if not on then
        if musicPlayer and musicPlayer:isPlaying() then
            musicPlayer:pause()
        end
    else
        if musicPlayer and not musicPlayer:isPlaying() then
            musicPlayer:play(0)
        end
    end
end

function SoundManager.isSfxEnabled()   return sfxEnabled   end
function SoundManager.isMusicEnabled() return musicEnabled end

--- Start the background music loop. Gapless via fileplayer repeat count 0.
function SoundManager.playBGM()
    if not musicPlayer then return end
    if musicPlayer:isPlaying() then return end -- already playing
    if not musicEnabled then return end
    -- 0 = loop forever (gapless — fileplayer handles seamless looping natively)
    musicPlayer:play(0)
end

--- Stop the background music.
function SoundManager.stopBGM()
    if musicPlayer and musicPlayer:isPlaying() then
        musicPlayer:stop()
    end
end

--- Check if music is currently playing.
function SoundManager.isMusicPlaying()
    return musicPlayer ~= nil and musicPlayer:isPlaying()
end

--- Play the celebration track for the given level (1-indexed, wraps).
function SoundManager.playCelebration(level)
    if not musicEnabled then return end
    -- Stop any already-playing celebration track
    SoundManager.stopCelebration()
    local idx = ((level - 1) % NUM_CELEBRATION_TRACKS) + 1
    local p = celebrationPlayers[idx]
    if p then
        p:play(1) -- play once (no loop)
    end
end

--- Stop all celebration tracks.
function SoundManager.stopCelebration()
    for _, p in ipairs(celebrationPlayers) do
        if p:isPlaying() then p:stop() end
    end
end

--- Check if any celebration track is currently playing.
function SoundManager.isCelebrationPlaying()
    for _, p in ipairs(celebrationPlayers) do
        if p:isPlaying() then return true end
    end
    return false
end

--- Play the appropriate reroll SFX based on the new tile value.
-- Crank tick: short percussive click generated via synth
local crankTickSynth = nil

function SoundManager.playCrankTick()
    if not sfxEnabled then return end
    if not crankTickSynth then
        crankTickSynth = playdate.sound.synth.new(playdate.sound.kWaveSquare)
        crankTickSynth:setVolume(0.15)
        crankTickSynth:setADSR(0.001, 0.02, 0, 0.01)
    end
    crankTickSynth:playNote("C7", 0.15, 0.03)
end

-- ── Shepard tone for celebration crank ──────────────────────
-- Three sine oscillators one octave apart, all rising together.
-- The lowest fades in, highest fades out — endless-rise illusion.
local shepardSynths   = nil
local shepardPhase    = 0.0   -- 0..1, drives pitch position in the octave
local SHEPARD_OCTAVE_LOW  = 220   -- A3
local SHEPARD_OCTAVE_HIGH = 880   -- A5 (two octaves up)

local function initShepard()
    if shepardSynths then return end
    shepardSynths = {}
    for i = 1, 3 do
        local s = playdate.sound.synth.new(playdate.sound.kWaveSine)
        s:setADSR(0.01, 0, 1.0, 0.05)
        table.insert(shepardSynths, s)
    end
end

function SoundManager.updateShepardCrank(crankDelta)
    if not sfxEnabled then return end
    initShepard()

    -- Advance phase by crank speed (clamp to avoid runaway)
    local speed = math.min(math.abs(crankDelta) / 90.0, 0.04)
    shepardPhase = (shepardPhase + speed) % 1.0

    -- Three voices spaced 1/3 of an octave apart in phase
    for i, s in ipairs(shepardSynths) do
        local voicePhase = (shepardPhase + (i - 1) / 3.0) % 1.0
        -- Frequency: interpolate across one octave
        local freq = SHEPARD_OCTAVE_LOW * (2 ^ voicePhase)
        -- Volume envelope: loudest at mid-phase, silent at edges (crossfade)
        local vol = math.sin(voicePhase * math.pi) * 0.28
        s:setVolume(vol)
        s:playNote(freq, vol, 0.08)
    end
end

function SoundManager.stopShepard()
    if not shepardSynths then return end
    for _, s in ipairs(shepardSynths) do
        s:stop()
    end
end

function SoundManager.playReroll(tileValue)
    if tileValue >= 3 then SoundManager.play("reroll_plus_3")
    elseif tileValue == 2 then SoundManager.play("reroll_plus_2")
    elseif tileValue == 1 then SoundManager.play("reroll_plus_1")
    elseif tileValue <= -3 then SoundManager.play("reroll_minus_3")
    elseif tileValue == -2 then SoundManager.play("reroll_minus_2")
    elseif tileValue == -1 then SoundManager.play("reroll_minus_1")
    else SoundManager.play("button")
    end
end
