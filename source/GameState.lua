-- GameState.lua — Pure data container, mirrors src/state.js
GRID_SIZE = 6
MAX_TILES = GRID_SIZE * GRID_SIZE -- 36

GameState = {}
GameState.__index = GameState

function GameState.new()
    local self = setmetatable({}, GameState)
    self:reset()
    return self
end

function GameState:reset()
    self.grid = {}
    for r = 1, GRID_SIZE do
        self.grid[r] = {}
        for c = 1, GRID_SIZE do
            self.grid[r][c] = nil
        end
    end
    self.score = 0
    self.level = 1
    self.moveCounter = 0
    self.sessionNeutralized = 0
    self.sessionMerged = 0
    self.lastMoveDir = nil -- {dx, dy}
    self.nextTileValue = 1
    self.isGameOver = false
    self.isSpecialSequenceActive = false

    -- Reroll system
    self.maxRerolls = 8
    self.currentRerolls = self.maxRerolls

    -- Timer tracking
    self.levelStartTime = playdate.getSecondsSinceEpoch()
    self.totalStartTime = self.levelStartTime

    -- Spawn probabilities (matches game.js updateSpawnProbabilities)
    self.posTileProb = 0.5
    self.negTileProb = 0.5
    self.dblPosProb = 0
    self.dblNegProb = 0
    self.triPosProb = 0
    self.triNegProb = 0
    self.quadPosProb = 0
    self.quadNegProb = 0

    -- Recent spawn tracking for anti-streak weighting
    self.recentSpawns = {} -- list of 0 (positive) or 1 (negative)
    self.maxRecentSpawns = 3
    self.boardStateInfluence = 0.5
    self.recentSpawnInfluence = 0.5
end

-- Serialize for playdate.datastore
function GameState:toTable()
    return {
        grid = self.grid,
        score = self.score,
        level = self.level,
        moveCounter = self.moveCounter,
        sessionNeutralized = self.sessionNeutralized,
        sessionMerged = self.sessionMerged,
        lastMoveDir = self.lastMoveDir,
        nextTileValue = self.nextTileValue,
        isGameOver = self.isGameOver,
        isSpecialSequenceActive = self.isSpecialSequenceActive,
        currentRerolls = self.currentRerolls,
        posTileProb = self.posTileProb,
        negTileProb = self.negTileProb,
        dblPosProb = self.dblPosProb,
        dblNegProb = self.dblNegProb,
        triPosProb = self.triPosProb,
        triNegProb = self.triNegProb,
        quadPosProb = self.quadPosProb,
        quadNegProb = self.quadNegProb,
        recentSpawns = self.recentSpawns,
        levelStartTime = self.levelStartTime,
        totalStartTime = self.totalStartTime,
    }
end

function GameState:fromTable(data)
    if not data then return end
    self.grid = data.grid or self.grid
    self.score = data.score or 0
    self.level = data.level or 1
    self.moveCounter = data.moveCounter or 0
    self.sessionNeutralized = data.sessionNeutralized or 0
    self.sessionMerged = data.sessionMerged or 0
    self.lastMoveDir = data.lastMoveDir
    self.nextTileValue = data.nextTileValue or 1
    self.isGameOver = data.isGameOver or false
    self.isSpecialSequenceActive = data.isSpecialSequenceActive or false
    self.currentRerolls = data.currentRerolls or self.maxRerolls
    self.posTileProb = data.posTileProb or 0.5
    self.negTileProb = data.negTileProb or 0.5
    self.dblPosProb = data.dblPosProb or 0
    self.dblNegProb = data.dblNegProb or 0
    self.triPosProb = data.triPosProb or 0
    self.triNegProb = data.triNegProb or 0
    self.quadPosProb = data.quadPosProb or 0
    self.quadNegProb = data.quadNegProb or 0
    self.recentSpawns = data.recentSpawns or {}
    self.levelStartTime = data.levelStartTime or playdate.getSecondsSinceEpoch()
    self.totalStartTime = data.totalStartTime or self.levelStartTime
end
