-- VFXConfig.lua — Central tuning knobs for all visual polish effects.
-- Every effect can be toggled on/off and has tunable parameters.
-- Adjust values here without touching rendering code.

VFXConfig = {}

--------------------------------------------------------------
-- MASTER TOGGLE (kill switch for all VFX polish)
--------------------------------------------------------------
VFXConfig.enabled = true

--------------------------------------------------------------
-- 1. TILE DITHER BORDERS — embossed edge around every tile
--------------------------------------------------------------
VFXConfig.tileDitherBorder = {
    enabled   = true,
    width     = 2,          -- pixels of dither border inside tile edge
    density   = 0.35,       -- dither alpha (0=white, 1=black); 0.35 = subtle
    ditherType = "Bayer8x8", -- "Bayer8x8" | "Bayer4x4" | "DiagonalLine"
    -- Only applied to positive and neutral tiles (negative tiles are already black)
    applyToPositive = true,
    applyToNegative = false,  -- negative tiles already have black bg, border would be invisible
    applyToNeutral  = false,
}

--------------------------------------------------------------
-- 2. SYMBOL SCALE BY MAGNITUDE — bigger symbols for higher values
--------------------------------------------------------------
VFXConfig.symbolScale = {
    enabled = true,
    scales  = {
        [1] = 1.0,
        [2] = 1.10,
        [3] = 1.20,
        [4] = 1.30,
    },
}

--------------------------------------------------------------
-- 3. BOARD FRAME — dither border around the play area
--------------------------------------------------------------
VFXConfig.boardFrame = {
    enabled      = false,
    width        = 2,       -- border thickness in pixels
    density      = 0.4,     -- dither alpha
    ditherType   = "Bayer8x8",
    padding      = 1,       -- gap between frame and board edge
    innerShadow  = true,    -- 1px darker dither line inside the frame
    innerDensity = 0.55,    -- density of inner shadow line
}

--------------------------------------------------------------
-- 4. SIDEBAR DITHER BACKGROUND — subtle texture behind UI panels
--------------------------------------------------------------
VFXConfig.sidebarBg = {
    enabled    = false,
    density    = 0.12,      -- very light dither; just enough texture to separate
    ditherType = "Bayer8x8",
}

--------------------------------------------------------------
-- 5. NEUTRALIZE SCREEN SHAKE — board jolts on neutralize events
--------------------------------------------------------------
VFXConfig.neutralizeShake = {
    enabled   = true,
    intensity = 3,    -- max pixel displacement
    frames    = 4,    -- how long the shake lasts
    -- Scales with tile magnitude: ±1 = 1x, ±2 = 1.3x, ±3 = 1.6x, ±4 = 2x
    scaleWithMagnitude = true,
}

--------------------------------------------------------------
-- 6. INVALID MOVE SHAKE — shake on failed swipe (already exists; configurable)
--------------------------------------------------------------
VFXConfig.invalidMoveShake = {
    enabled   = true,
    intensity = 2,
    frames    = 6,
}

--------------------------------------------------------------
-- 7. FLOATING "+1" SCORE LABEL — rises from board center on neutralize
--------------------------------------------------------------
VFXConfig.floatingScore = {
    enabled  = true,
    duration = 24,    -- frames to live
    riseSpeed = 1.2,  -- pixels per frame upward
    startY   = 120,   -- initial Y (board center)
    centerX  = 200,   -- X position (board center)
}

--------------------------------------------------------------
-- 8. MERGE/NEUTRALIZE POP — tiles briefly scale up then back
--------------------------------------------------------------
VFXConfig.mergePop = {
    enabled     = true,
    maxScale    = 1.15,   -- overshoot scale factor
    duration    = 8,      -- frames for full pop cycle
}

--------------------------------------------------------------
-- 9. NEXT TILE PREVIEW ENHANCEMENTS
--------------------------------------------------------------
VFXConfig.nextTilePreview = {
    -- Dither shadow underneath preview tile
    shadow = {
        enabled    = true,
        offsetX    = 2,
        offsetY    = 2,
        density    = 0.35,
        ditherType = "Bayer8x8",
    },
    -- Gentle idle bob (up/down drift)
    bob = {
        enabled   = true,
        amplitude = 1.5,    -- pixels of vertical movement
        speed     = 2.0,    -- oscillation speed multiplier
    },
    -- Scale multiplier for the preview tile
    sizeMultiplier = 1.0,   -- 1.0 = same as board tiles; 1.3 = 30% larger
}

--------------------------------------------------------------
-- 10. SHUFFLE METER ANIMATED FILL — scanning dither pattern
--------------------------------------------------------------
VFXConfig.shuffleMeter = {
    animatedFill  = true,    -- dither sweep instead of solid fill
    invertOnFull  = true,    -- flash/invert when charge hits 100%
    invertFrames  = 4,       -- how many frames the invert lasts
}

--------------------------------------------------------------
-- 11. MODAL DIALOG SHADOW — dither drop-shadow on overlay boxes
--------------------------------------------------------------
VFXConfig.dialogShadow = {
    enabled    = true,
    offsetX    = 3,
    offsetY    = 3,
    density    = 0.4,
    ditherType = "Bayer8x8",
    cornerRadius = 8,        -- match the dialog's corner radius
}

--------------------------------------------------------------
-- 12. ACHIEVEMENT VISUAL ENHANCEMENTS
--------------------------------------------------------------
VFXConfig.achievements = {
    -- Locked achievements get a dither overlay (dimmed look)
    lockedOverlay = {
        enabled = true,
        density = 0.2,       -- subtle dim over locked row
    },
    -- Unlocked bullet uses filled square instead of circle
    unlockedStyle = "bullet", -- "bullet" (●/○) | "square" (■/□) | "check" (✓/—)
}

--------------------------------------------------------------
-- 13. TOAST BANNER ENHANCEMENTS
--------------------------------------------------------------
VFXConfig.toast = {
    -- Dither border on top edge of toast banner
    topBorder = {
        enabled = true,
        height  = 1,
        density = 0.5,
    },
}

--------------------------------------------------------------
-- 14. TITLE SCREEN FLOATER ENHANCEMENTS
--------------------------------------------------------------
VFXConfig.floaters = {
    -- Dither halo/glow around each floating tile
    glow = {
        enabled = false,     -- off by default; can look noisy
        radius  = 3,         -- pixels of glow around tile
        density = 0.15,
    },
}

--------------------------------------------------------------
-- 15. CONFETTI SPARKLE PARTICLES — tiny 1-2px dots mixed in
--------------------------------------------------------------
VFXConfig.confettiSparkle = {
    enabled = true,
    ratio   = 0.3,   -- 30% of confetti particles become sparkles
    minSize = 1,
    maxSize = 2,
}

--------------------------------------------------------------
-- 16. CELEBRATION IRIS RIPPLE — concentric rings inside iris
--------------------------------------------------------------
VFXConfig.irisRipple = {
    enabled   = true,
    ringCount = 3,         -- number of concentric rings
    ringGap   = 20,        -- pixels between rings
    density   = 0.3,       -- dither density of rings
}

--------------------------------------------------------------
-- 17. GAME OVER TYPED TEXT CURSOR
--------------------------------------------------------------
VFXConfig.typewriterCursor = {
    enabled     = true,
    blinkRate   = 8,   -- frames per blink cycle
    cursorChar  = "_",
}

--------------------------------------------------------------
-- 18. DAILY CHALLENGE BANNER — visual distinction for daily mode
--------------------------------------------------------------
VFXConfig.dailyBanner = {
    enabled = true,
    ditherBg = {
        enabled = true,
        density = 0.15,
        ditherType = "DiagonalLine",
    },
    -- Pulsing "DAILY" indicator during gameplay
    pulseIndicator = {
        enabled = true,
        speed = 3.0,
    },
}

--------------------------------------------------------------
-- HELPER: Get dither type constant from string name
--------------------------------------------------------------
function VFXConfig.getDitherType(name)
    local gfx = playdate.graphics
    local types = {
        Bayer8x8       = gfx.image.kDitherTypeBayer8x8,
        Bayer4x4       = gfx.image.kDitherTypeBayer4x4,
        DiagonalLine   = gfx.image.kDitherTypeDiagonalLine,
        VerticalLine   = gfx.image.kDitherTypeVerticalLine,
        HorizontalLine = gfx.image.kDitherTypeHorizontalLine,
    }
    return types[name] or gfx.image.kDitherTypeBayer8x8
end
