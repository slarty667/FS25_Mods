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
GreyRouter.cell = 5.0        -- m, grid cell size
GreyRouter.maxSnap = 70.0    -- m, snap start/dest to nearest grey cell within this
GreyRouter.satMax = 0.20     -- grey = saturation below this
GreyRouter.brightMin = 0.08
GreyRouter.brightMax = 0.78
GreyRouter.maxIters = 40000  -- A* safety cap
GreyRouter._grey = {}        -- cell "cx:cz" -> bool (terrain is static; cache for the session)
GreyRouter._cacheCount = 0

local function log(fmt, ...)
    if Logging and Logging.info then Logging.info(GreyRouter.LOG_PREFIX .. " " .. fmt, ...) end
end

function GreyRouter.reset()
    GreyRouter._grey = {}
    GreyRouter._cacheCount = 0
end

local function terrainHeight(x, z)
    local m = g_currentMission
    if getTerrainHeightAtWorldPos ~= nil and m ~= nil and m.terrainRootNode ~= nil then
        local ok, h = pcall(getTerrainHeightAtWorldPos, m.terrainRootNode, x, 0, z)
        if ok and h ~= nil then return h end
    end
    return 0
end

-- Is the terrain at world (wx,wz) grey (low saturation = drivable path)?
local function isGreyAt(wx, wz)
    local m = g_currentMission
    if m == nil or m.terrainRootNode == nil or getTerrainAttributesAtWorldPos == nil then return false end
    local wy = terrainHeight(wx, wz)
    local ok, r, g, b = pcall(getTerrainAttributesAtWorldPos, m.terrainRootNode, wx, wy, wz, true, true, true, true, false)
    if not ok or r == nil then return false end
    local mx = math.max(r, math.max(g, b))
    local mn = math.min(r, math.min(g, b))
    local sat = (mx > 0.001) and ((mx - mn) / mx) or 0
    local bright = (r + g + b) / 3
    return sat < GreyRouter.satMax and bright > GreyRouter.brightMin and bright < GreyRouter.brightMax
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
    local function heur(cx, cz) local dx, dz = cx - dcx, cz - dcz; return math.sqrt(dx * dx + dz * dz) * cell end
    local startKey = scx .. ":" .. scz
    local g = { [startKey] = 0 }
    local came = {}
    local closed = {}
    local open = {}
    heapPush(open, { f = heur(scx, scz), key = startKey, cx = scx, cz = scz })
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
                        local nk = nx .. ":" .. nz
                        if not closed[nk] and GreyRouter.cellGrey(nx, nz) then
                            local step = (dx == 0 or dz == 0) and cell or (cell * 1.41421)
                            local tentative = g[cur.key] + step
                            if tentative < (g[nk] or 1e18) then
                                g[nk] = tentative
                                came[nk] = { key = cur.key, cx = cur.cx, cz = cur.cz }
                                heapPush(open, { f = tentative + heur(nx, nz), key = nk, cx = nx, cz = nz })
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, iters
end

-- Public: world path (list of {x,y,z}) following grey terrain from start to dest, or nil.
function GreyRouter.findPath(sx, sz, dx, dz)
    if g_currentMission == nil or getTerrainAttributesAtWorldPos == nil then return nil end
    local scx, scz = GreyRouter.findNearestGreyCell(sx, sz)
    local dcx, dcz = GreyRouter.findNearestGreyCell(dx, dz)
    if scx == nil or dcx == nil then
        log("findPath: kein grauer Start/Ziel-Snap (s=%s d=%s)", tostring(scx ~= nil), tostring(dcx ~= nil))
        return nil
    end
    local cells, iters = GreyRouter.astar(scx, scz, dcx, dcz)
    if cells == nil then
        log("findPath: A* kein Pfad (%d iters)", iters)
        return nil
    end
    local cell = GreyRouter.cell
    local out = { { x = sx, y = terrainHeight(sx, sz), z = sz } }
    local function push(x, z)
        local last = out[#out]
        if last and math.abs(last.x - x) < 0.5 and math.abs(last.z - z) < 0.5 then return end
        out[#out + 1] = { x = x, y = terrainHeight(x, z), z = z }
    end
    for _, c in ipairs(cells) do push((c[1] + 0.5) * cell, (c[2] + 0.5) * cell) end
    push(dx, dz)
    log("findPath: %d Zellen, %d iters, %d Punkte", #cells, iters, #out)
    return out
end
