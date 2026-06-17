--[[
  GreyRouter.lua
  Map-agnostic road router: A* over a virtual grid in ENGINE world coordinates, where a
  cell is traversable iff the terrain there is "grey" (low colour saturation = paved road,
  village street, dirt field track, farmyard). Surface read via getTerrainAttributesAtWorldPos
  — no image, no calibration, no splines, works on every map. (This is what WayPointGPS does
  for maps without road material names.)

  Verified on Helden: roads/streets/tracks rgb≈0.284 grey (sat 0.00), fields brown (sat 0.76).
]]

GreyRouter = {}
GreyRouter.LOG_PREFIX = "[NaviHelper/Grey]"
GreyRouter.cell = 3.0        -- m, grid cell size (fine -> junctions/narrow streets resolve)
GreyRouter.maxSnap = 70.0    -- m, snap start/dest to nearest grey cell within this
GreyRouter.satMax = 0.20     -- grey = saturation below this
GreyRouter.brightMin = 0.08
GreyRouter.brightMax = 0.78
GreyRouter.maxIters = 120000 -- A* safety cap (finer grid -> more cells)
GreyRouter.maxOffroad = 4    -- cells of non-grey the path may bridge (gate/seam ~12m)
GreyRouter.offroadPenalty = 6 -- cost multiplier for non-grey cells (prefer grey strongly)
GreyRouter._grey = {}        -- cell "cx:cz" -> bool (terrain is static; cache for the session)
GreyRouter._cacheCount = 0
GreyRouter._waterY = nil      -- discovered water level (terrain below this = underwater)

local function log(fmt, ...)
    if Logging and Logging.info then Logging.info(GreyRouter.LOG_PREFIX .. " " .. fmt, ...) end
end

function GreyRouter.reset()
    GreyRouter._grey = {}
    GreyRouter._cacheCount = 0
    GreyRouter._waterY = nil
end

local function terrainHeight(x, z)
    local m = g_currentMission
    if getTerrainHeightAtWorldPos ~= nil and m ~= nil and m.terrainRootNode ~= nil then
        local ok, h = pcall(getTerrainHeightAtWorldPos, m.terrainRootNode, x, 0, z)
        if ok and h ~= nil then return h end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Drivability by terrain COLOUR + SHAPE (faithful port of WayPointGPS's
-- classifyRouteGraphRoadCellStrict). On maps like Helden the road shares its terrain
-- MATERIAL (mat 7) and base colour with the surrounding open ground, so neither
-- materialId nor a bare colour test can separate road from meadow. WPGPS's trick: a
-- road cell is road-coloured AND part of a CONTINUOUS coloured run (a lane), not an
-- isolated patch -> kills meadow/yard/schlieren false positives. Plus explicit WATER
-- rejection (blue colour / water plane) -> kills the lake.
-- ---------------------------------------------------------------------------

local function colorStats(r, g, b)
    local mx = math.max(r, math.max(g, b))
    local mn = math.min(r, math.min(g, b))
    local bright = (r + g + b) / 3
    local sat = (mx > 0.001) and ((mx - mn) / mx) or 0
    return bright, sat
end

-- grey asphalt/concrete: low saturation, neutral hue. Floor 0.12 (Helden roads ~0.284).
local function isGreyColor(r, g, b)
    local bright, sat = colorStats(r, g, b)
    local greenish = g > r * 1.10 and g > b * 1.10
    local bluish = b > r * 1.10 and b > g * 1.05
    local redish = r > g * 1.22 and r > b * 1.22
    return bright > 0.12 and bright < 0.86 and sat < 0.24 and not greenish and not bluish and not redish
end

-- tan/beige dirt+gravel lane (narrow window so ripe crops/field fill don't qualify)
local function isTanColor(r, g, b)
    local bright, sat = colorStats(r, g, b)
    local greenish = g > r * 1.08 and g > b * 1.18
    local bluish = b > r * 1.08 and b > g * 1.08
    return bright > 0.28 and bright < 0.78 and sat >= 0.08 and sat < 0.42
        and r >= g * 0.88 and r > b * 1.12 and g > b * 1.06 and not greenish and not bluish
end

-- blue/cyan water colour (port of WPGPS.isBlueWaterColor) -> the lake bed reads blue.
local function isWaterColor(r, g, b)
    local bright, sat = colorStats(r, g, b)
    local blueDominant = b > r * 1.18 and b > g * 1.04
    local cyanWater = b > r * 1.10 and g > r * 1.08 and b >= g * 0.92
    local notGrey = sat > 0.12
    local notGreen = not (g > b * 1.10 and g > r * 1.20)
    return bright > 0.18 and bright < 0.92 and notGrey and notGreen and (blueDominant or cyanWater)
end

-- terrain colour at a world position -> r,g,b or nil
local function surfaceColorAt(wx, wz)
    local m = g_currentMission
    if m == nil or m.terrainRootNode == nil or getTerrainAttributesAtWorldPos == nil then return nil end
    local wy = terrainHeight(wx, wz)
    local ok, r, g, b = pcall(getTerrainAttributesAtWorldPos, m.terrainRootNode, wx, wy, wz, true, true, true, true, false)
    if ok and r ~= nil then return r, g, b end
    return nil
end

-- forward decl (defined below)
local isFieldAt

-- Discover the water level once (terrain below it = lake/river bed -> never driveable).
local function waterLevel()
    if GreyRouter._waterY ~= nil then return GreyRouter._waterY end
    local m = g_currentMission
    local y = nil
    if m ~= nil then
        if type(m.waterY) == "number" then y = m.waterY
        elseif m.environmentAreaSystem ~= nil and type(m.environmentAreaSystem.waterYValue) == "number" then
            y = m.environmentAreaSystem.waterYValue
        elseif m.environment ~= nil and type(m.environment.waterLevel) == "number" then
            y = m.environment.waterLevel
        end
    end
    GreyRouter._waterY = y or -1e9   -- sentinel: "unknown" => never excludes by height
    if y ~= nil then log("waterLevel = %.2f", y) end
    return GreyRouter._waterY
end

-- Is this position cultivable field ground? Used to reject field tramlines/interiors
-- that happen to read as tan, so we don't route across fields. (Ported from WayPointGPS.)
-- (Assigns the forward-declared upvalue so the helpers above can call it.)
function isFieldAt(wx, wz)
    local m = g_currentMission
    if m == nil then return false end
    local wy = terrainHeight(wx, wz)
    if FSDensityMapUtil ~= nil and type(FSDensityMapUtil.getFieldDataAtWorldPosition) == "function" then
        local ok, onField = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, wx, wy, wz)
        if ok and onField ~= nil then return onField == true end
    end
    if m.terrainDetailId ~= nil and getDensityAtWorldPos ~= nil then
        local ok, bits = pcall(getDensityAtWorldPos, m.terrainDetailId, wx, wy, wz)
        if ok and bits ~= nil then return bits ~= 0 end
    end
    return false
end

-- Water at a world position: blue/cyan terrain colour, an engine water-plane query,
-- or terrain below the discovered water level. (Port of WPGPS.isWaterAtWorldPos.)
local function isWaterAt(wx, wz)
    local r, g, b = surfaceColorAt(wx, wz)
    if r ~= nil and isWaterColor(r, g, b) then return true end
    local y = terrainHeight(wx, wz)
    local globals = { "getWaterYAtWorldPos", "getWaterYAtWorldPosition", "getWaterHeightAtWorldPos", "getWaterHeightAtWorldPosition" }
    for _, fnName in ipairs(globals) do
        local fn = _G[fnName]
        if type(fn) == "function" then
            local ok, wy = pcall(fn, wx, y + 3.0, wz)
            if ok and type(wy) == "number" and wy > -1000 and math.abs(wy - y) < 8.0 then return true end
        end
    end
    if y < waterLevel() - 0.05 then return true end
    return false
end

-- road-coloured (grey or tan) at a position, ignoring shape -> used by continuity scan
local function isRoadColorAt(wx, wz)
    local r, g, b = surfaceColorAt(wx, wz)
    if r == nil then return false end
    return isGreyColor(r, g, b) or isTanColor(r, g, b)
end

-- A lone road-coloured pixel can be a yard, a field edge, or a lighting "schliere".
-- Require a continuous road-coloured run on at least one axis (8 & 16 m out, both
-- sides) -> only real lanes qualify. (Port of WPGPS.hasVisualRoadContinuity.)
local function hasContinuity(wx, wz)
    local d1, d2 = 8.0, 16.0
    local ns = 0
    if isRoadColorAt(wx, wz + d1) and not isFieldAt(wx, wz + d1) then ns = ns + 1 end
    if isRoadColorAt(wx, wz - d1) and not isFieldAt(wx, wz - d1) then ns = ns + 1 end
    if isRoadColorAt(wx, wz + d2) and not isFieldAt(wx, wz + d2) then ns = ns + 1 end
    if isRoadColorAt(wx, wz - d2) and not isFieldAt(wx, wz - d2) then ns = ns + 1 end
    local ew = 0
    if isRoadColorAt(wx + d1, wz) and not isFieldAt(wx + d1, wz) then ew = ew + 1 end
    if isRoadColorAt(wx - d1, wz) and not isFieldAt(wx - d1, wz) then ew = ew + 1 end
    if isRoadColorAt(wx + d2, wz) and not isFieldAt(wx + d2, wz) then ew = ew + 1 end
    if isRoadColorAt(wx - d2, wz) and not isFieldAt(wx - d2, wz) then ew = ew + 1 end
    return ns >= 2 or ew >= 2
end

-- A narrow lane running between field edges on both sides (port of
-- WPGPS.hasNarrowCorridorShape) -> extra acceptance for tan dirt field tracks.
local SIDE_SAMPLE, FORWARD_SAMPLE, FAR_SIDE_SAMPLE = 14.0, 18.0, 30.0
local function hasCorridor(wx, wz)
    local f, s, fs = FORWARD_SAMPLE, SIDE_SAMPLE, FAR_SIDE_SAMPLE
    local nsF, nsB = not isFieldAt(wx, wz + f), not isFieldAt(wx, wz - f)
    local nsEdges = 0
    if isFieldAt(wx + s, wz) then nsEdges = nsEdges + 1 end
    if isFieldAt(wx - s, wz) then nsEdges = nsEdges + 1 end
    if isFieldAt(wx + fs, wz) then nsEdges = nsEdges + 1 end
    if isFieldAt(wx - fs, wz) then nsEdges = nsEdges + 1 end
    local ewF, ewB = not isFieldAt(wx + f, wz), not isFieldAt(wx - f, wz)
    local ewEdges = 0
    if isFieldAt(wx, wz + s) then ewEdges = ewEdges + 1 end
    if isFieldAt(wx, wz - s) then ewEdges = ewEdges + 1 end
    if isFieldAt(wx, wz + fs) then ewEdges = ewEdges + 1 end
    if isFieldAt(wx, wz - fs) then ewEdges = ewEdges + 1 end
    return (nsF and nsB and nsEdges >= 2) or (ewF and ewB and ewEdges >= 2)
end

-- Driveable lane test (WPGPS classifyRouteGraphRoadCellStrict, distilled to a bool):
-- not water, not field, and (grey + continuity) or (tan + (continuity or corridor)).
local function isGreyAt(wx, wz)
    local r, g, b = surfaceColorAt(wx, wz)
    if r == nil then return false end
    if isWaterAt(wx, wz) then return false end
    if isFieldAt(wx, wz) then return false end
    if isGreyColor(r, g, b) and hasContinuity(wx, wz) then return true end
    if isTanColor(r, g, b) and (hasContinuity(wx, wz) or hasCorridor(wx, wz)) then return true end
    return false
end

-- Is cell (cx,cz) drivable? Grey if a path TOUCHES the cell — sample centre + 4 inner
-- points so thin/diagonal roads dilate into a connected chain of cells. Cached.
function GreyRouter.cellGrey(cx, cz)
    local key = cx .. ":" .. cz
    local c = GreyRouter._grey[key]
    if c ~= nil then return c end
    local cs = GreyRouter.cell
    local wx, wz = (cx + 0.5) * cs, (cz + 0.5) * cs
    local off = cs * 0.45
    local grey = isGreyAt(wx, wz)
        or isGreyAt(wx - off, wz) or isGreyAt(wx + off, wz)
        or isGreyAt(wx, wz - off) or isGreyAt(wx, wz + off)
    GreyRouter._grey[key] = grey
    GreyRouter._cacheCount = GreyRouter._cacheCount + 1
    return grey
end

function GreyRouter.findNearestGreyCell(x, z)
    local cell = GreyRouter.cell
    local scx, scz = math.floor(x / cell), math.floor(z / cell)
    if GreyRouter.cellGrey(scx, scz) then return scx, scz end
    local maxRing = math.ceil(GreyRouter.maxSnap / cell)
    for ring = 1, maxRing do
        for dx = -ring, ring do
            for dz = -ring, ring do
                if math.abs(dx) == ring or math.abs(dz) == ring then
                    if GreyRouter.cellGrey(scx + dx, scz + dz) then return scx + dx, scz + dz end
                end
            end
        end
    end
    return nil
end

-- binary min-heap on .f
local function heapPush(h, item)
    h[#h + 1] = item
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]; i = p
    end
end
local function heapPop(h)
    local top = h[1]
    local n = #h
    h[1] = h[n]; h[n] = nil; n = n - 1
    local i = 1
    while true do
        local l, r, s = 2 * i, 2 * i + 1, i
        if l <= n and h[l].f < h[s].f then s = l end
        if r <= n and h[r].f < h[s].f then s = r end
        if s == i then break end
        h[i], h[s] = h[s], h[i]; i = s
    end
    return top
end

function GreyRouter.astar(scx, scz, dcx, dcz)
    local cell = GreyRouter.cell
    local maxOff, offPen = GreyRouter.maxOffroad, GreyRouter.offroadPenalty
    local function heur(cx, cz) local dx, dz = cx - dcx, cz - dcz; return math.sqrt(dx * dx + dz * dz) * cell end
    -- state = cell + how many non-grey cells in a row we've crossed (so gaps stay bounded)
    local function K(cx, cz, run) return cx .. ":" .. cz .. ":" .. run end
    local startKey = K(scx, scz, 0)
    local g = { [startKey] = 0 }
    local came = {}
    local closed = {}
    local open = {}
    heapPush(open, { f = heur(scx, scz), key = startKey, cx = scx, cz = scz, run = 0 })
    local iters = 0
    while #open > 0 and iters < GreyRouter.maxIters do
        iters = iters + 1
        local cur = heapPop(open)
        if cur.cx == dcx and cur.cz == dcz then
            local path = { { cur.cx, cur.cz } }
            local pk = came[cur.key]
            while pk ~= nil do
                path[#path + 1] = { pk.cx, pk.cz }
                pk = came[pk.key]
            end
            local rev = {}
            for i = #path, 1, -1 do rev[#rev + 1] = path[i] end
            return rev, iters
        end
        if not closed[cur.key] then
            closed[cur.key] = true
            for dx = -1, 1 do
                for dz = -1, 1 do
                    if not (dx == 0 and dz == 0) then
                        local nx, nz = cur.cx + dx, cur.cz + dz
                        local grey = GreyRouter.cellGrey(nx, nz)
                        local newrun = grey and 0 or (cur.run + 1)
                        if newrun <= maxOff then
                            local base = (dx == 0 or dz == 0) and cell or (cell * 1.41421)
                            local stepCost = grey and base or (base * offPen)
                            local nk = K(nx, nz, newrun)
                            if not closed[nk] then
                                local tentative = g[cur.key] + stepCost
                                if tentative < (g[nk] or 1e18) then
                                    g[nk] = tentative
                                    came[nk] = { key = cur.key, cx = cur.cx, cz = cur.cz }
                                    heapPush(open, { f = tentative + heur(nx, nz), key = nk, cx = nx, cz = nz, run = newrun })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, iters
end

-- Line-of-sight: does the straight line (x1,z1)->(x2,z2) stay on drivable (grey) cells?
local function losGrey(x1, z1, x2, z2)
    local cell = GreyRouter.cell
    local d = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
    local steps = math.max(1, math.floor(d / (cell * 0.6)))
    for i = 0, steps do
        local t = i / steps
        local x, z = x1 + (x2 - x1) * t, z1 + (z2 - z1) * t
        if not GreyRouter.cellGrey(math.floor(x / cell), math.floor(z / cell)) then return false end
    end
    return true
end

-- String-pulling: greedily skip to the farthest still-visible point -> straight, smooth path.
local function smooth(pts)
    if #pts <= 2 then return pts end
    local out = { pts[1] }
    local i = 1
    while i < #pts do
        local j = #pts
        while j > i + 1 do
            if losGrey(pts[i].x, pts[i].z, pts[j].x, pts[j].z) then break end
            j = j - 1
        end
        out[#out + 1] = pts[j]
        i = j
    end
    return out
end

-- Public: world path (list of {x,y,z}) following grey terrain from start to dest, or nil.
function GreyRouter.findPath(sx, sz, dx, dz)
    if g_currentMission == nil or getTerrainAttributesAtWorldPos == nil then return nil end
    local scx, scz = GreyRouter.findNearestGreyCell(sx, sz)
    local dcx, dcz = GreyRouter.findNearestGreyCell(dx, dz)
    if scx == nil or dcx == nil then
        local function colAt(x, z)
            local m = g_currentMission
            local ok, r, g, b = pcall(getTerrainAttributesAtWorldPos, m.terrainRootNode, x, terrainHeight(x, z), z, true, true, true, true, false)
            if ok and r ~= nil then return r, g, b end
            return -1, -1, -1
        end
        local sr, sg, sb = colAt(sx, sz)
        local dr, dg, db = colAt(dx, dz)
        log("findPath: kein Snap (s=%s d=%s) | start rgb=%.3f,%.3f,%.3f dest rgb=%.3f,%.3f,%.3f",
            tostring(scx ~= nil), tostring(dcx ~= nil), sr, sg, sb, dr, dg, db)
        return nil
    end
    local cells, iters = GreyRouter.astar(scx, scz, dcx, dcz)
    if cells == nil then
        log("findPath: A* kein Pfad (%d iters)", iters)
        return nil
    end
    local cell = GreyRouter.cell
    local raw = { { x = sx, z = sz } }
    for _, c in ipairs(cells) do raw[#raw + 1] = { x = (c[1] + 0.5) * cell, z = (c[2] + 0.5) * cell } end
    raw[#raw + 1] = { x = dx, z = dz }
    local sm = smooth(raw)
    local out = {}
    for _, p in ipairs(sm) do out[#out + 1] = { x = p.x, y = terrainHeight(p.x, p.z), z = p.z } end
    log("findPath: %d Zellen -> %d geglaettet, %d iters", #cells, #out, iters)
    return out
end
