function math.rad(deg) return deg * math.pi / 180 end
local orbitBlend = 0.0
local orbitAngle = 0
local orbitVelocity = 0
local orbitHeroCX = 200
local orbitHeroCY = 50
local orbitRadius = 90
local crankDelta = -50 -- crank backward fast

-- AnimManager.setCrankOrbit
orbitHeroCX = 200
orbitHeroCY = 50
orbitVelocity = orbitVelocity + crankDelta * 0.2
orbitVelocity = math.max(-30, math.min(30, orbitVelocity))

if math.abs(crankDelta) > 0.5 then
    orbitBlend = math.min(1.0, orbitBlend + 0.08)
else
    orbitBlend = math.max(0.0, orbitBlend - 0.015)
end

-- AnimManager.update()
orbitAngle = orbitAngle + orbitVelocity
orbitVelocity = orbitVelocity * 0.94

local floaters = {
    { baseX = 100, baseY = 100, phaseX = 0, phaseY = 0, rateX = 0.02, rateY = 0.02, hoverDist = 10, x = 0, y = 0, size = 12 }
}

for i, f in ipairs(floaters) do
    f.phaseX = f.phaseX + f.rateX * (1 - orbitBlend)
    f.phaseY = f.phaseY + f.rateY * (1 - orbitBlend)
    local homeX = f.baseX + math.sin(f.phaseX) * f.hoverDist
    local homeY = f.baseY + math.cos(f.phaseY) * f.hoverDist

    local n = #floaters
    local anglePerTile = 360.0 / n
    local tileAngleRad = math.rad(orbitAngle + (i - 1) * anglePerTile)
    local orbitX = orbitHeroCX + math.cos(tileAngleRad) * orbitRadius - f.size / 2
    local orbitY = orbitHeroCY + math.sin(tileAngleRad) * orbitRadius - f.size / 2
    
    f.x = homeX * (1 - orbitBlend) + orbitX * orbitBlend
    f.y = homeY * (1 - orbitBlend) + orbitY * orbitBlend
    print("f.x: " .. f.x .. " f.y: " .. f.y)
end
