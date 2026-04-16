-- GameEngine.lua — Full game logic, mirrors src/game.js
import "GameState"

TOTAL_LEVELS = 4

GameEngine = {}
GameEngine.__index = GameEngine

function GameEngine.new()
    local self = setmetatable({}, GameEngine)
    self.state = GameState.new()
    self:updateSpawnProbabilities()
    self:spawnInitialTiles()
    self.state.nextTileValue = self:chooseNextTileValue()
    return self
end

-- ─── Grid Queries ─────────────────────────────────────

function GameEngine:getNeutralCount()
    local count = 0
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            if self.state.grid[r][c] == 0 then count = count + 1 end
        end
    end
    return count
end

function GameEngine:getPositiveCount()
    local count = 0
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            local v = self.state.grid[r][c]
            if type(v) == "number" and v > 0 then count = count + 1 end
        end
    end
    return count
end

function GameEngine:getNegativeCount()
    local count = 0
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            local v = self.state.grid[r][c]
            if type(v) == "number" and v < 0 then count = count + 1 end
        end
    end
    return count
end

function GameEngine:getEmptyCells()
    local cells = {}
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            if self.state.grid[r][c] == nil then
                table.insert(cells, {r=r, c=c})
            end
        end
    end
    return cells
end

function GameEngine:isCompletelyBlocked(row, col)
    if self.state.grid[row][col] ~= nil then return true end
    local blockCount = 0
    local totalAdj = 0
    local dirs = {{-1,0},{1,0},{0,-1},{0,1}}
    for _, d in ipairs(dirs) do
        local nr, nc = row + d[1], col + d[2]
        totalAdj = totalAdj + 1
        if nr < 1 or nr > GRID_SIZE or nc < 1 or nc > GRID_SIZE then
            blockCount = blockCount + 1 -- edge = blocked
        elseif self.state.grid[nr][nc] == 0 then
            blockCount = blockCount + 1 -- neutral = blocked
        end
    end
    return blockCount == totalAdj
end

-- ─── Tile Creation ────────────────────────────────────

function GameEngine:spawnInitialTiles()
    -- All levels: one neutral in a random center cell
    local central = {{r=3,c=3},{r=3,c=4},{r=4,c=3},{r=4,c=4}}
    local cell = central[math.random(1, #central)]
    self.state.grid[cell.r][cell.c] = 0 -- neutral

    if self.state.level == 1 then
        -- Level 1: two random-sign ±1 tiles
        local sign1 = math.random() > 0.5 and 1 or -1
        local sign2 = math.random() > 0.5 and 1 or -1
        self:spawnRandomTile(sign1)
        self:spawnRandomTile(sign2)
    elseif self.state.level == 2 then
        self:spawnRandomTile(2)
        self:spawnRandomTile(-2)
    elseif self.state.level == 3 then
        self:spawnRandomTile(3)
        self:spawnRandomTile(-3)
    else -- level >= 4
        self:spawnRandomTile(4)
        self:spawnRandomTile(-4)
    end
end

function GameEngine:spawnRandomTile(value)
    local empties = self:getEmptyCells()
    if #empties > 0 then
        local spot = empties[math.random(1, #empties)]
        self.state.grid[spot.r][spot.c] = value
    end
end

-- ─── Directional Spawning (matches game.js spawnDirectionalTile) ──

function GameEngine:findEmptyCellsFromEdge(edgeType, startIndex)
    local step = (startIndex == 1) and 1 or -1
    local i = startIndex
    while i >= 1 and i <= GRID_SIZE do
        local cells = {}
        if edgeType == "row" then
            for c = 1, GRID_SIZE do
                if self.state.grid[i][c] == nil and not self:isCompletelyBlocked(i, c) then
                    table.insert(cells, {r=i, c=c})
                end
            end
        else -- "col"
            for r = 1, GRID_SIZE do
                if self.state.grid[r][i] == nil and not self:isCompletelyBlocked(r, i) then
                    table.insert(cells, {r=r, c=i})
                end
            end
        end
        if #cells > 0 then return cells end
        i = i + step
    end
    return {}
end

function GameEngine:spawnDirectionalTile()
    local neutralCount = self:getNeutralCount()
    if neutralCount >= MAX_TILES - 1 then return end

    local value = self.state.nextTileValue
    local available = {}

    if self.state.lastMoveDir then
        local dx, dy = self.state.lastMoveDir.dx, self.state.lastMoveDir.dy
        -- Spawn on the OPPOSITE edge from swipe direction
        if dx == 1 then available = self:findEmptyCellsFromEdge("col", 1) end       -- swipe right → left edge
        if dx == -1 then available = self:findEmptyCellsFromEdge("col", GRID_SIZE) end -- swipe left → right edge
        if dy == 1 then available = self:findEmptyCellsFromEdge("row", 1) end       -- swipe down → top edge
        if dy == -1 then available = self:findEmptyCellsFromEdge("row", GRID_SIZE) end -- swipe up → bottom edge
    end

    -- Fallback: any empty non-blocked cell
    if #available == 0 then
        local empties = self:getEmptyCells()
        for _, cell in ipairs(empties) do
            if not self:isCompletelyBlocked(cell.r, cell.c) then
                table.insert(available, cell)
            end
        end
    end

    if #available > 0 then
        local spot = available[math.random(1, #available)]
        self.state.grid[spot.r][spot.c] = value
        return spot.r, spot.c
    end
    return nil, nil
end

-- ─── Spawn Probabilities (matches game.js) ────────────

function GameEngine:updateSpawnProbabilities()
    local s = self.state
    if s.level == 1 then
        s.dblPosProb = 0; s.dblNegProb = 0
        s.triPosProb = 0; s.triNegProb = 0
        s.quadPosProb = 0; s.quadNegProb = 0
    elseif s.level == 2 then
        s.dblPosProb = 0.1; s.dblNegProb = 0.1
        s.triPosProb = 0;   s.triNegProb = 0
        s.quadPosProb = 0;  s.quadNegProb = 0
    elseif s.level == 3 then
        s.dblPosProb = 0.1;  s.dblNegProb = 0.1
        s.triPosProb = 0.05; s.triNegProb = 0.05
        s.quadPosProb = 0;   s.quadNegProb = 0
    else -- level >= 4
        s.dblPosProb = 0.15; s.dblNegProb = 0.15
        s.triPosProb = 0.10; s.triNegProb = 0.10
        s.quadPosProb = 0.05; s.quadNegProb = 0.05
    end
end

function GameEngine:adjustByBoardState(baseProb, tileValue)
    local posCount = self:getPositiveCount()
    local negCount = self:getNegativeCount()
    local total = posCount + negCount
    if total == 0 then return baseProb end
    local proportion = tileValue > 0 and (posCount / total) or (negCount / total)
    local factor = (1.0 - proportion) ^ 3
    return baseProb * (1.0 + (factor - 1.0) * self.state.boardStateInfluence)
end

function GameEngine:adjustByRecentSpawns(baseProb, tileValue)
    local targetType = tileValue > 0 and 0 or 1
    local recentCount = 0
    for _, s in ipairs(self.state.recentSpawns) do
        if s == targetType then recentCount = recentCount + 1 end
    end
    if self.state.maxRecentSpawns <= 0 then return baseProb end
    local proportion = recentCount / self.state.maxRecentSpawns
    local factor = 1.0 - proportion
    return baseProb * (1.0 + (factor - 1.0) * self.state.recentSpawnInfluence)
end

-- Used for determining the next standard tile, taking into account board state and recent spawns
function GameEngine:chooseNextTileValue()
    local s = self.state
    local probs = {}

    local function addTile(value, baseProb)
        if baseProb <= 0 then return end
        local boardAdj = self:adjustByBoardState(baseProb, value)
        local recentAdj = self:adjustByRecentSpawns(boardAdj, value)
        table.insert(probs, {value=value, prob=recentAdj})
    end

    addTile(1, s.posTileProb)
    addTile(-1, s.negTileProb)
    addTile(2, s.dblPosProb)
    addTile(-2, s.dblNegProb)
    addTile(3, s.triPosProb)
    addTile(-3, s.triNegProb)
    addTile(4, s.quadPosProb)
    addTile(-4, s.quadNegProb)

    local total = 0
    for _, t in ipairs(probs) do total = total + t.prob end
    if total == 0 then
        s.nextTileValue = math.random() > 0.5 and 1 or -1
        return s.nextTileValue
    end

    local rand = math.random() * total
    local cumulative = 0
    for _, t in ipairs(probs) do
        cumulative = cumulative + t.prob
        if rand <= cumulative then
            s.nextTileValue = t.value
            break
        end
    end

    -- Track recent spawn ONLY for normal sequence
    table.insert(s.recentSpawns, s.nextTileValue > 0 and 0 or 1)
    if #s.recentSpawns > s.maxRecentSpawns then
        table.remove(s.recentSpawns, 1)
    end

    return s.nextTileValue
end

-- Used for reroll/shuffle functionality, biases toward opposite sign if desiredValue is set
function GameEngine:chooseRandomTileValue(desiredValue)
    local s = self.state
    local probs = {}

    local function addTile(value, baseProb)
        if baseProb <= 0 then return end
        -- Enforce desired sign if specified
        if desiredValue ~= nil then
            if (value > 0) ~= (desiredValue > 0) then return end
        end
        local boardAdj = self:adjustByBoardState(baseProb, value)
        table.insert(probs, {value=value, prob=boardAdj})
    end

    addTile(1, s.posTileProb)
    addTile(-1, s.negTileProb)
    addTile(2, s.dblPosProb)
    addTile(-2, s.dblNegProb)
    addTile(3, s.triPosProb)
    addTile(-3, s.triNegProb)
    addTile(4, s.quadPosProb)
    addTile(-4, s.quadNegProb)

    local total = 0
    for _, t in ipairs(probs) do total = total + t.prob end
    if total == 0 or #probs == 0 then return math.random() > 0.5 and 1 or -1 end

    local rand = math.random() * total
    local cumulative = 0
    for _, t in ipairs(probs) do
        cumulative = cumulative + t.prob
        if rand <= cumulative then return t.value end
    end
    return probs[1].value
end

-- ─── Game Over Detection ──────────────────────────────

function GameEngine:canAnyMove()
    local dirs = {{dx=0,dy=-1},{dx=0,dy=1},{dx=-1,dy=0},{dx=1,dy=0}}
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            local v = self.state.grid[r][c]
            if v ~= nil and v ~= 0 then -- has a non-neutral tile
                for _, d in ipairs(dirs) do
                    local nr, nc = r + d.dy, c + d.dx
                    if nr >= 1 and nr <= GRID_SIZE and nc >= 1 and nc <= GRID_SIZE then
                        local nv = self.state.grid[nr][nc]
                        if nv == nil then return true end -- empty cell
                        if type(nv) == "number" and nv ~= 0 and nv * v < 0 then return true end -- opposite sign
                    end
                end
            end
        end
    end
    return false
end

-- ─── Movement (Two-pass, matches game.js) ─────────────

function GameEngine:swipe(dx, dy)
    local s = self.state
    if s.isGameOver or s.isSpecialSequenceActive then return {moved=false, neutralized=0, merged=0, anims={}} end

    local moved = false
    local neutralized = 0  -- count of perfect neutralizations (result == 0)
    local merged = 0       -- count of partial merges (result ~= 0)
    local anims = {}       -- animation descriptors for the renderer

    -- Determine traversal order (process tiles farthest in move direction first)
    local rows = {1,2,3,4,5,6}
    local cols = {1,2,3,4,5,6}
    if dy > 0 then rows = {6,5,4,3,2,1} end
    if dx > 0 then cols = {6,5,4,3,2,1} end

    -- Pass 1: Identify cells involved in neutralizations
    local reserved = {}
    for _, r in ipairs(rows) do
        for _, c in ipairs(cols) do
            local v = s.grid[r][c]
            if v ~= nil and v ~= 0 then
                local nr, nc = r + dy, c + dx
                if nr >= 1 and nr <= GRID_SIZE and nc >= 1 and nc <= GRID_SIZE then
                    local tv = s.grid[nr][nc]
                    if type(tv) == "number" and tv ~= 0 and v * tv < 0 then
                        reserved[r .. "," .. c] = true
                        reserved[nr .. "," .. nc] = true
                    end
                end
            end
        end
    end

    -- Pass 2: Move all tiles one step
    for _, r in ipairs(rows) do
        for _, c in ipairs(cols) do
            local v = s.grid[r][c]
            if v == nil or v == 0 then goto continue end -- skip empty/neutral

            local nr, nc = r + dy, c + dx
            if nr < 1 or nr > GRID_SIZE or nc < 1 or nc > GRID_SIZE then goto continue end

            local tv = s.grid[nr][nc]
            local targetWillBeCleared = reserved[nr .. "," .. nc]
            local canMerge = type(tv) == "number" and tv ~= 0 and v * tv < 0

            if tv == nil then
                -- Move into empty cell
                s.grid[nr][nc] = v
                s.grid[r][c] = nil
                moved = true
                table.insert(anims, {type="slide", fromR=r, fromC=c, toR=nr, toC=nc})
            elseif canMerge then
                -- Opposite signs → merge
                local result = v + tv
                s.grid[r][c] = nil
                if result == 0 then
                    s.grid[nr][nc] = 0 -- neutral
                    s.score = s.score + 1
                    neutralized = neutralized + 1
                    table.insert(anims, {type="slide", fromR=r, fromC=c, toR=nr, toC=nc})
                    table.insert(anims, {type="neutralize", r=nr, c=nc})
                else
                    s.grid[nr][nc] = result
                    merged = merged + 1
                    table.insert(anims, {type="slide", fromR=r, fromC=c, toR=nr, toC=nc})
                    table.insert(anims, {type="merge", r=nr, c=nc})
                end
                moved = true
            elseif targetWillBeCleared and tv ~= nil then
                -- Target is being neutralized this turn — move into freed space
                s.grid[nr][nc] = v
                s.grid[r][c] = nil
                moved = true
                table.insert(anims, {type="slide", fromR=r, fromC=c, toR=nr, toC=nc})
            end

            ::continue::
        end
    end

    if moved then
        s.moveCounter = s.moveCounter + 1
        s.sessionNeutralized = s.sessionNeutralized + neutralized
        s.sessionMerged = s.sessionMerged + merged
        s.lastMoveDir = {dx=dx, dy=dy}

        -- Win when 35+ neutral tiles on the board (don't spawn a 36th)
        local neutralCount = self:getNeutralCount()
        if neutralCount >= MAX_TILES - 1 and not s.isSpecialSequenceActive then
            s.isSpecialSequenceActive = true
        else
            -- Spawn new tile using directional logic
            local spawnR, spawnC = self:spawnDirectionalTile()
            if spawnR then
                table.insert(anims, {type="spawn", r=spawnR, c=spawnC})
            end
            s.nextTileValue = self:chooseNextTileValue()

            if not self:canAnyMove() then
                s.isGameOver = true
            end
        end
    else
        -- No move was made
        if not self:canAnyMove() then
            s.isGameOver = true
        end
    end

    return {moved=moved, neutralized=neutralized, merged=merged, anims=anims}
end

-- ─── Level System ─────────────────────────────────────

function GameEngine:advanceLevel()
    local s = self.state
    if s.level >= TOTAL_LEVELS then
        -- Final level complete — stay in special sequence for UI to handle
        s.isSpecialSequenceActive = false
        return
    end

    -- Clear the board
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            s.grid[r][c] = nil
        end
    end
    s.level = s.level + 1
    s.levelStartTime = playdate.getSecondsSinceEpoch()
    self:updateSpawnProbabilities()
    self:spawnInitialTiles()
    s.nextTileValue = self:chooseNextTileValue()
    s.isSpecialSequenceActive = false
    s.moveCounter = 0
end

-- Reset for new game (keeps stats tracking external)
function GameEngine:restart()
    self.state:reset()
    self:updateSpawnProbabilities()
    self:spawnInitialTiles()
    self.state.nextTileValue = self:chooseNextTileValue()
end
