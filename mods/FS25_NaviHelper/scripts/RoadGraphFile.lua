--[[
  RoadGraphFile.lua
  Loads a pre-baked road graph for the current map (extracted offline from the map's
  overview image by tools/roadgraph/extract.py) and runs A* over it. This is the
  "processed map" path: the graph IS the roads, so routing follows real roads with
  full coverage (village, field tracks) — no AutoDrive course needed.

  Data file: roadgraphs/<MapTitle>.lua  (sets global NaviHelperRoadData = {terrain, nodes, edges}).
]]

RoadGraphFile = {}
RoadGraphFile.LOG_PREFIX = "[NaviHelper/RGF]"
RoadGraphFile.ready = false
RoadGraphFile.mapKey = nil
RoadGraphFile.nodes = nil      -- { i = {x,z} }
RoadGraphFile.adj = nil        -- { i = { {to=j, cost=d, e=k}, ... } }
RoadGraphFile.edges = nil      -- { k = {a,b,len,pts={x,z,...}} }
RoadGraphFile._grid = nil      -- spatial hash "cx:cz" -> { nodeId }
RoadGraphFile.cellSize = 32
RoadGraphFile.maxSnap = 80     -- m: if nearest node is farther, no road path

local function log(fmt, ...)
    if Logging and Logging.info then Logging.info(RoadGraphFile.LOG_PREFIX .. " " .. fmt, ...) end
end

local function mapKeyFromTitle()
    local m = g_currentMission
    local title = (m and m.missionInfo and m.missionInfo.mapTitle) or (m and m.mapTitle) or nil
    if title == nil then return nil end
    return (tostring(title):gsub("%s+", "_"))
end

function RoadGraphFile.load()
    RoadGraphFile.ready = false
    local key = mapKeyFromTitle()
    RoadGraphFile.mapKey = key
    if key == nil or NaviHelper == nil or NaviHelper.modDirectory == nil then
        log("load skipped (key=%s modDir=%s)", tostring(key), tostring(NaviHelper and NaviHelper.modDirectory))
        return
    end
    local path = Utils.getFilename("roadgraphs/" .. key .. ".lua", NaviHelper.modDirectory)
    if fileExists == nil or not fileExists(path) then
        log("no road graph file for map '%s' (%s) — using fallback routing", tostring(key), tostring(path))
        return
    end
    NaviHelperRoadData = nil
    local ok = pcall(source, path)
    local data = NaviHelperRoadData
    NaviHelperRoadData = nil
    if not ok or type(data) ~= "table" or type(data.nodes) ~= "table" then
        log("road graph file load failed for '%s' (ok=%s)", tostring(key), tostring(ok))
        return
    end

    -- Build runtime structures.
    RoadGraphFile.nodes = data.nodes
    RoadGraphFile.edges = data.edges or {}
    RoadGraphFile.adj = {}
    for i = 1, #data.nodes do RoadGraphFile.adj[i] = {} end
    for k = 1, #RoadGraphFile.edges do
        local e = RoadGraphFile.edges[k]
        if e.a and e.b and RoadGraphFile.adj[e.a] and RoadGraphFile.adj[e.b] then
            local cost = e.len or 1
            table.insert(RoadGraphFile.adj[e.a], { to = e.b, cost = cost, e = k })
            table.insert(RoadGraphFile.adj[e.b], { to = e.a, cost = cost, e = k })
        end
    end
    -- Spatial hash for nearest-node lookup.
    RoadGraphFile._grid = {}
    local cs = RoadGraphFile.cellSize
    for i = 1, #data.nodes do
        local n = data.nodes[i]
        local kk = math.floor(n.x / cs) .. ":" .. math.floor(n.z / cs)
        local b = RoadGraphFile._grid[kk]
        if b == nil then b = {}; RoadGraphFile._grid[kk] = b end
        b[#b + 1] = i
    end
    RoadGraphFile.ready = true
    log("loaded '%s': %d Knoten, %d Kanten", key, #data.nodes, #RoadGraphFile.edges)
end

function RoadGraphFile.findNearestNode(x, z)
    if not RoadGraphFile.ready then return nil end
    local cs = RoadGraphFile.cellSize
    local cx, cz = math.floor(x / cs), math.floor(z / cs)
    local best, bestD2 = nil, RoadGraphFile.maxSnap * RoadGraphFile.maxSnap
    local ring = 0
    local maxRing = math.ceil(RoadGraphFile.maxSnap / cs) + 1
    while ring <= maxRing do
        for dx = -ring, ring do
            for dz = -ring, ring do
                if math.abs(dx) == ring or math.abs(dz) == ring then
                    local b = RoadGraphFile._grid[(cx + dx) .. ":" .. (cz + dz)]
                    if b ~= nil then
                        for _, id in ipairs(b) do
                            local n = RoadGraphFile.nodes[id]
                            local ddx, ddz = n.x - x, n.z - z
                            local d2 = ddx * ddx + ddz * ddz
                            if d2 < bestD2 then best, bestD2 = id, d2 end
                        end
                    end
                end
            end
        end
        if best ~= nil and ring >= 1 then break end  -- found something, one extra ring already covered
        ring = ring + 1
    end
    return best
end

local function dist(nodes, a, b)
    local na, nb = nodes[a], nodes[b]
    return math.sqrt((na.x - nb.x)^2 + (na.z - nb.z)^2)
end

-- A* over the node graph. Returns a list of node ids start..goal, or nil.
function RoadGraphFile.astar(startId, goalId)
    local nodes, adj = RoadGraphFile.nodes, RoadGraphFile.adj
    if startId == goalId then return { startId } end
    local came, g, open, openCount = {}, {}, {}, 0
    g[startId] = 0
    open[startId] = g[startId] + dist(nodes, startId, goalId)
    openCount = 1
    while openCount > 0 do
        -- pop lowest f (linear scan; graph is small)
        local cur, curF = nil, math.huge
        for id, f in pairs(open) do if f < curF then cur, curF = id, f end end
        if cur == goalId then
            local path, n = {}, cur
            while n ~= nil do table.insert(path, 1, n); n = came[n] end
            return path
        end
        open[cur] = nil; openCount = openCount - 1
        for _, e in ipairs(adj[cur]) do
            local tentative = g[cur] + e.cost
            if g[e.to] == nil or tentative < g[e.to] then
                came[e.to] = cur
                g[e.to] = tentative
                if open[e.to] == nil then openCount = openCount + 1 end
                open[e.to] = tentative + dist(nodes, e.to, goalId)
            end
        end
    end
    return nil
end

-- Find the edge connecting nodes u,v and return its pts oriented u->v.
local function edgePtsOriented(u, v)
    for _, e in ipairs(RoadGraphFile.adj[u]) do
        if e.to == v then
            local ed = RoadGraphFile.edges[e.e]
            local pts, out = ed.pts, {}
            for i = 1, #pts, 2 do out[#out + 1] = { pts[i], pts[i + 1] } end
            if ed.a ~= u then  -- stored a->b is v->u, reverse
                local rev = {}
                for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
                out = rev
            end
            return out
        end
    end
    return nil
end

-- Public: world path from (sx,sz) to (dx,dz) following roads, or nil if no road path.
function RoadGraphFile.findPath(sx, sz, dx, dz)
    if not RoadGraphFile.ready then return nil end
    local sNode = RoadGraphFile.findNearestNode(sx, sz)
    local dNode = RoadGraphFile.findNearestNode(dx, dz)
    if sNode == nil or dNode == nil then return nil end
    local nodePath = RoadGraphFile.astar(sNode, dNode)
    if nodePath == nil then return nil end

    local out = { { x = sx, y = 0, z = sz } }
    local function push(x, z)
        local last = out[#out]
        if last and math.abs(last.x - x) < 0.5 and math.abs(last.z - z) < 0.5 then return end
        out[#out + 1] = { x = x, y = 0, z = z }
    end
    for i = 1, #nodePath - 1 do
        local seg = edgePtsOriented(nodePath[i], nodePath[i + 1])
        if seg ~= nil then
            for _, p in ipairs(seg) do push(p[1], p[2]) end
        else
            local n = RoadGraphFile.nodes[nodePath[i + 1]]
            push(n.x, n.z)
        end
    end
    push(dx, dz)
    return out
end
