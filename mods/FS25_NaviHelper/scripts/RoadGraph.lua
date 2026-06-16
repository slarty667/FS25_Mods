--[[
  RoadGraph.lua
  NaviHelper Vanilla-Spline-Router — R1: build an undirected, weighted node graph from
  the map's built-in AI road network (g_currentMission.aiSystem.roadSplines), with
  junction welding. No routing yet (A* comes in R2); this phase builds the graph and
  exposes it for a debug overlay so the network can be verified visually.

  Design notes (from the plan + Stage-4 critique):
  - Time-budgeted build: a few splines per update tick, never a synchronous freeze.
  - Junction welding via a spatial hash with a small tolerance in X/Z and a separate
    hard Y limit, so bridges/underpasses that cross in plan view but differ in height
    are NOT merged.
  - Undirected graph (direction is irrelevant for showing a route to a human driver;
    directed/dual-road handling is deferred to R4 autonomous driving).
]]

RoadGraph = {}
RoadGraph.LOG_PREFIX = "[NaviHelper/RoadGraph]"

-- Tuning.
RoadGraph.sampleSpacing = 8.0   -- m between sampled nodes along a spline
RoadGraph.weldTol = 1.5         -- m: merge nodes closer than this in X/Z (junctions)
RoadGraph.weldYTol = 2.5        -- m: but only if their height differs by less (no bridge merge)
RoadGraph.cellSize = 8.0        -- m: spatial-hash cell (>= weldTol)
RoadGraph.splinesPerTick = 4    -- build throughput per update call

-- State.
RoadGraph.ready = false
RoadGraph.debugDraw = false
RoadGraph.nodes = nil           -- { i = {x,y,z} }
RoadGraph.adj = nil             -- { i = { {to=j, cost=d}, ... } }
RoadGraph._grid = nil           -- spatial hash: "cx:cz" -> { nodeId, ... }
RoadGraph._queue = nil          -- splines left to process
RoadGraph._qi = 0               -- queue index
RoadGraph._initDone = false
RoadGraph._stats = nil

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info(RoadGraph.LOG_PREFIX .. " " .. fmt, ...)
    end
end

local function cellId(self, x, z)
    return math.floor(x / self.cellSize) .. ":" .. math.floor(z / self.cellSize)
end

-- Find an existing node within weldTol of (x,y,z), searching the 3x3 neighbour cells.
function RoadGraph:_findWeldNode(x, y, z)
    local cs = self.cellSize
    local cx, cz = math.floor(x / cs), math.floor(z / cs)
    local best, bestD2 = nil, self.weldTol * self.weldTol
    for dx = -1, 1 do
        for dz = -1, 1 do
            local bucket = self._grid[(cx + dx) .. ":" .. (cz + dz)]
            if bucket ~= nil then
                for _, id in ipairs(bucket) do
                    local n = self.nodes[id]
                    if math.abs(n.y - y) <= self.weldYTol then
                        local ddx, ddz = n.x - x, n.z - z
                        local d2 = ddx * ddx + ddz * ddz
                        if d2 <= bestD2 then best, bestD2 = id, d2 end
                    end
                end
            end
        end
    end
    return best
end

-- Add a node (welding onto an existing one if within tolerance). Returns node id.
function RoadGraph:_addNode(x, y, z)
    local existing = self:_findWeldNode(x, y, z)
    if existing ~= nil then return existing end
    local id = #self.nodes + 1
    self.nodes[id] = { x = x, y = y, z = z }
    self.adj[id] = {}
    local key = cellId(self, x, z)
    local b = self._grid[key]
    if b == nil then b = {}; self._grid[key] = b end
    b[#b + 1] = id
    return id
end

function RoadGraph:_addEdge(a, b)
    if a == b then return end
    local na, nb = self.nodes[a], self.nodes[b]
    local dx, dy, dz = na.x - nb.x, na.y - nb.y, na.z - nb.z
    local cost = math.sqrt(dx * dx + dy * dy + dz * dz)
    for _, e in ipairs(self.adj[a]) do if e.to == b then return end end  -- no dup
    self.adj[a][#self.adj[a] + 1] = { to = b, cost = cost }
    self.adj[b][#self.adj[b] + 1] = { to = a, cost = cost }
end

-- Sample one spline into welded nodes + connecting edges.
function RoadGraph:_processSpline(spline)
    if getSplineLength == nil or getSplinePosition == nil then return end
    local length = getSplineLength(spline)
    if length == nil or length <= 0 then return end
    local samples = math.max(1, math.ceil(length / self.sampleSpacing))
    local prevId = nil
    for i = 0, samples do
        local t = i / samples
        local x, y, z = getSplinePosition(spline, t)
        if x ~= nil then
            local id = self:_addNode(x, y, z)
            if prevId ~= nil then self:_addEdge(prevId, id) end
            prevId = id
        end
    end
end

local function collectSplines()
    local mission = g_currentMission
    if mission == nil or mission.aiSystem == nil then return nil end
    local splines = mission.aiSystem.roadSplines
    if splines == nil then return nil end
    local list = {}
    for _, s in pairs(splines) do list[#list + 1] = s end
    return list
end

function RoadGraph:_init()
    self._initDone = true
    self.nodes, self.adj, self._grid = {}, {}, {}
    self._queue = collectSplines()
    self._qi = 0
    if self._queue == nil or #self._queue == 0 then
        self.ready = true
        log("no roadSplines — graph empty (router will fall back)")
        return
    end
    log("build start: %d splines (spacing=%.0fm weldTol=%.1fm)", #self._queue, self.sampleSpacing, self.weldTol)
end

function RoadGraph:_finalize()
    self.ready = true
    local edgeCount, junctionCount = 0, 0
    for i = 1, #self.nodes do
        local deg = #self.adj[i]
        edgeCount = edgeCount + deg
        if deg >= 3 then junctionCount = junctionCount + 1 end
    end
    edgeCount = edgeCount / 2  -- undirected counted twice
    self._stats = { nodes = #self.nodes, edges = edgeCount, junctions = junctionCount }
    log("build done: %d Knoten, %d Kanten, %d Kreuzungen (Grad>=3)",
        #self.nodes, edgeCount, junctionCount)
end

-- Time-budgeted build: process a few splines per call. Safe to call every frame.
function RoadGraph:stepBuild()
    if self.ready then return end
    if not self._initDone then self:_init() end
    if self.ready then return end
    local done = 0
    while self._qi < #self._queue and done < self.splinesPerTick do
        self._qi = self._qi + 1
        self:_processSpline(self._queue[self._qi])
        done = done + 1
    end
    if self._qi >= #self._queue then self:_finalize() end
end

function RoadGraph:statsString()
    if not self.ready then return "RoadGraph: baut noch…" end
    local s = self._stats or { nodes = 0, edges = 0, junctions = 0 }
    return string.format("RoadGraph: %d Knoten, %d Kanten, %d Kreuzungen — debugDraw=%s",
        s.nodes, s.edges, s.junctions, tostring(self.debugDraw))
end

-- Console command: toggle the debug overlay (and report stats).
function RoadGraph:consoleGraph()
    self.debugDraw = not self.debugDraw
    log("debugDraw = %s", tostring(self.debugDraw))
    return self:statsString()
end

if addConsoleCommand ~= nil then
    addConsoleCommand("nhGraph", "NaviHelper R1: RoadGraph-Debug-Overlay an/aus + Stats", "consoleGraph", RoadGraph)
end
