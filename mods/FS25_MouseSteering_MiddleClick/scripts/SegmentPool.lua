--[[
  SegmentPool.lua
  Manages rendering of a projected driving path as world-space lines.

  Two rendering backends, chosen automatically at loadMap time:

  (1) I3D mode — preferred.
      If FS25_AutoDrive is installed, we reuse its line asset by loading
      drawing/line.i3d from the AutoDrive mod directory. We clone a pool
      of N segment nodes under our own root (child of terrainRootNode)
      so no other system (e.g. ADDrawingManager) clears them.
      Each frame, applySegments() positions/rotates/scales the nodes to
      connect the given world-space points.

  (2) Debug mode — fallback.
      If AutoDrive isn't installed or asset loading fails, we drop back
      to drawDebugLine() calls emitted from drawFallback() every frame.
      This is the same strategy NaviHelper uses.

  See docs/learned.md "Route line rendering in FS25" / NaviHelper for the
  rationale behind this split.
]]

SegmentPool = {}

SegmentPool.MODE_I3D   = "i3d"
SegmentPool.MODE_DEBUG = "debug"
SegmentPool.MODE_OFF   = "off"

SegmentPool.MAX_SEGMENTS = 80  -- 40 per track × 2 tracks
SegmentPool.DEFAULT_COLOR = { 0.15, 0.85, 0.35, 1.0 }  -- green r,g,b,a
SegmentPool.SEGMENT_WIDTH = 0.12  -- visual width of the line (x/z scale applied to the clone)

-- Per-instance-style state lives on the module table.
SegmentPool.mode        = SegmentPool.MODE_OFF
SegmentPool.rootNode    = nil
SegmentPool.templateNode = nil
SegmentPool.nodes       = {}   -- pool of clone node IDs
SegmentPool.debugLines  = {}   -- array of {x1,y1,z1, x2,y2,z2} used in debug mode

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[MouseSteering][SegmentPool] " .. fmt, ...)
    end
end

---------------------------------------------------------------------------
-- Init: try to load AutoDrive's line.i3d. If that fails, switch to debug mode.
---------------------------------------------------------------------------
function SegmentPool:init()
    if self.mode ~= SegmentPool.MODE_OFF then return end  -- already initialised

    local autoDriveMod = nil
    pcall(function()
        if g_modManager and g_modManager.getModByName then
            autoDriveMod = g_modManager:getModByName("FS25_AutoDrive")
        end
    end)

    if not autoDriveMod then
        log("mode=debug reason: g_modManager:getModByName('FS25_AutoDrive') returned nil")
        self.mode = SegmentPool.MODE_DEBUG
        return
    end
    if not autoDriveMod.directory then
        log("mode=debug reason: autoDriveMod has no .directory field (keys: %s)", tostring(autoDriveMod))
        self.mode = SegmentPool.MODE_DEBUG
        return
    end

    local assetPath = nil
    pcall(function()
        assetPath = Utils.getFilename("drawing/line.i3d", autoDriveMod.directory)
    end)
    if not assetPath then
        log("mode=debug reason: Utils.getFilename returned nil for drawing/line.i3d in %s", tostring(autoDriveMod.directory))
        self.mode = SegmentPool.MODE_DEBUG
        return
    end

    local setupOk, setupErr = pcall(function() self:_setupI3DMode(assetPath) end)
    if not setupOk then
        log("mode=debug reason: _setupI3DMode raised: %s", tostring(setupErr))
        self.mode = SegmentPool.MODE_DEBUG
        return
    end
    if not self.templateNode then
        log("mode=debug reason: _setupI3DMode completed but templateNode is still nil; assetPath=%s", tostring(assetPath))
        self.mode = SegmentPool.MODE_DEBUG
        return
    end

    self.mode = SegmentPool.MODE_I3D
    log("mode=i3d, loaded template from %s, pool size=%d", assetPath, #self.nodes)
end

---Set up the i3d-based backend: load template, create pool of clones under our own root.
function SegmentPool:_setupI3DMode(assetPath)
    -- Load the shared i3d file (sync variant). Returns rootNode or 0 on error.
    local i3dNode = loadSharedI3DFile and loadSharedI3DFile(assetPath, false, false) or 0
    if not i3dNode or i3dNode == 0 then
        log("loadSharedI3DFile failed for %s", tostring(assetPath))
        return
    end

    -- AutoDrive's line.i3d convention: root has a child shape node at index 0.
    local template = nil
    pcall(function() template = getChildAt(i3dNode, 0) end)
    if not template or template == 0 then
        -- Try the root node itself.
        template = i3dNode
    end
    self.templateNode = template

    -- Create our own root under terrainRootNode so nothing else touches it.
    local parent = (g_currentMission and g_currentMission.terrainRootNode) or getRootNode()
    self.rootNode = createTransformGroup and createTransformGroup("MouseSteering_PathRoot") or nil
    if self.rootNode and parent and link then
        pcall(function() link(parent, self.rootNode) end)
    end

    -- Build the clone pool.
    self.nodes = {}
    for i = 1, SegmentPool.MAX_SEGMENTS do
        local cloneNode = nil
        pcall(function() cloneNode = clone(self.templateNode, true, false, false) end)
        if cloneNode and cloneNode ~= 0 then
            if self.rootNode and link then
                pcall(function() link(self.rootNode, cloneNode) end)
            end
            if setVisibility then pcall(function() setVisibility(cloneNode, false) end) end
            table.insert(self.nodes, cloneNode)
        end
    end
end

---------------------------------------------------------------------------
-- Apply: position segments between consecutive world-space points for each track.
-- Call once per frame from the indicator.
---------------------------------------------------------------------------
---@param leftWorld table array of {x,y,z} in world coordinates
---@param rightWorld table array of {x,y,z}
---@param color table|nil rgba, defaults to SegmentPool.DEFAULT_COLOR
function SegmentPool:applySegments(leftWorld, rightWorld, color)
    if self.mode == SegmentPool.MODE_OFF then return end
    color = color or SegmentPool.DEFAULT_COLOR

    if self.mode == SegmentPool.MODE_I3D then
        self:_applyI3D(leftWorld, rightWorld, color)
    else
        self:_applyDebug(leftWorld, rightWorld, color)
    end
end

---Apply multiple line groups (each with its own colour) sharing the pool.
---Each group: { left = <array>, right = <array>, color = {r,g,b,a} }.
---Used for the tractor path (green) + trailer path (yellow) combination.
---@param groups table array of groups
function SegmentPool:applySegmentGroups(groups)
    if self.mode == SegmentPool.MODE_OFF then return end
    if type(groups) ~= "table" or #groups == 0 then
        self:hideAll()
        return
    end

    if self.mode == SegmentPool.MODE_I3D then
        self:_applyI3DMulti(groups)
    else
        self:_applyDebugMulti(groups)
    end
end

function SegmentPool:_applyI3DMulti(groups)
    local used = 0
    local function placeTrack(pts, color)
        for i = 1, #pts - 1 do
            used = used + 1
            local node = self.nodes[used]
            if not node then return end
            local a, b = pts[i], pts[i + 1]
            local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
            local len = math.sqrt(dx * dx + dy * dy + dz * dz)
            if len < 1e-4 then
                if setVisibility then pcall(function() setVisibility(node, false) end) end
            else
                local mx, my, mz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
                local yaw = math.atan2(dx, dz)
                pcall(function() setTranslation(node, mx, my, mz) end)
                pcall(function() setRotation(node, 0, yaw, 0) end)
                pcall(function() setScale(node, SegmentPool.SEGMENT_WIDTH, 1.0, len) end)
                if setShaderParameter then
                    pcall(function() setShaderParameter(node, "colorScale", color[1], color[2], color[3], color[4], false) end)
                end
                if setVisibility then pcall(function() setVisibility(node, true) end) end
            end
        end
    end

    for _, g in ipairs(groups) do
        local c = g.color or SegmentPool.DEFAULT_COLOR
        if g.left and #g.left > 1 then placeTrack(g.left, c) end
        if g.right and #g.right > 1 then placeTrack(g.right, c) end
    end
    for i = used + 1, #self.nodes do
        if setVisibility then pcall(function() setVisibility(self.nodes[i], false) end) end
    end
end

function SegmentPool:_applyDebugMulti(groups)
    self.debugLines = {}
    self.debugMulti = true
    for _, g in ipairs(groups) do
        local c = g.color or SegmentPool.DEFAULT_COLOR
        local function collect(pts)
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                table.insert(self.debugLines, { a.x, a.y, a.z, b.x, b.y, b.z, c[1], c[2], c[3] })
            end
        end
        if g.left and #g.left > 1 then collect(g.left) end
        if g.right and #g.right > 1 then collect(g.right) end
    end
end

function SegmentPool:_applyI3D(leftWorld, rightWorld, color)
    local used = 0
    local function placeSegmentsOnTrack(pts)
        for i = 1, #pts - 1 do
            used = used + 1
            local node = self.nodes[used]
            if not node then return end
            local a, b = pts[i], pts[i + 1]
            local dx = b.x - a.x
            local dy = b.y - a.y
            local dz = b.z - a.z
            local len = math.sqrt(dx * dx + dy * dy + dz * dz)
            if len < 1e-4 then
                if setVisibility then pcall(function() setVisibility(node, false) end) end
            else
                -- Midpoint.
                local mx, my, mz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
                -- Yaw: rotation around Y axis so the segment faces a→b in the horizontal plane.
                local yaw = math.atan2(dx, dz)
                pcall(function() setTranslation(node, mx, my, mz) end)
                pcall(function() setRotation(node, 0, yaw, 0) end)
                -- AutoDrive's line.i3d is a 1m-long strip along Z — we scale Z to segment length,
                -- and scale X to get a visible width.
                pcall(function() setScale(node, SegmentPool.SEGMENT_WIDTH, 1.0, len) end)
                if setShaderParameter then
                    pcall(function() setShaderParameter(node, "colorScale", color[1], color[2], color[3], color[4], false) end)
                end
                if setVisibility then pcall(function() setVisibility(node, true) end) end
            end
        end
    end

    if leftWorld and #leftWorld > 1 then placeSegmentsOnTrack(leftWorld) end
    if rightWorld and #rightWorld > 1 then placeSegmentsOnTrack(rightWorld) end

    -- Hide any remaining nodes in the pool.
    for i = used + 1, #self.nodes do
        if setVisibility then pcall(function() setVisibility(self.nodes[i], false) end) end
    end
end

function SegmentPool:_applyDebug(leftWorld, rightWorld, color)
    -- Store segments; actual drawDebugLine calls happen in drawFallback() during draw phase.
    self.debugLines = {}
    self.debugColor = color
    self.debugMulti = false  -- must be explicitly cleared — otherwise a previous
                             -- multi-group frame leaves it true and drawFallback
                             -- picks the multi-drawer which reads seg[7..9] for colour,
                             -- but single-group segments have only six fields → crash.
    local function collect(pts)
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            table.insert(self.debugLines, { a.x, a.y, a.z, b.x, b.y, b.z })
        end
    end
    if leftWorld and #leftWorld > 1 then collect(leftWorld) end
    if rightWorld and #rightWorld > 1 then collect(rightWorld) end
end

---Called from MouseSteering:draw(). In i3d mode this is a no-op. In debug
---mode it emits a drawDebugLine call for each stored segment.
---Multi-group debug lines carry their color inline (positions 7..9 of each segment);
---single-group lines use self.debugColor.
function SegmentPool:drawFallback()
    if self.mode ~= SegmentPool.MODE_DEBUG then return end
    if not drawDebugLine then return end
    if self.debugMulti then
        for _, seg in ipairs(self.debugLines) do
            pcall(function()
                drawDebugLine(seg[1], seg[2], seg[3], seg[7], seg[8], seg[9],
                              seg[4], seg[5], seg[6], seg[7], seg[8], seg[9])
            end)
        end
    else
        local c = self.debugColor or SegmentPool.DEFAULT_COLOR
        for _, seg in ipairs(self.debugLines) do
            pcall(function()
                drawDebugLine(seg[1], seg[2], seg[3], c[1], c[2], c[3],
                              seg[4], seg[5], seg[6], c[1], c[2], c[3])
            end)
        end
    end
end

---Hide all segments (e.g. when the indicator turns off).
function SegmentPool:hideAll()
    if self.mode == SegmentPool.MODE_I3D then
        for _, node in ipairs(self.nodes) do
            if setVisibility then pcall(function() setVisibility(node, false) end) end
        end
    else
        self.debugLines = {}
    end
end

---Tear down: delete clones, unlink the root, clear state. Call from deleteMap/mod-unload.
function SegmentPool:shutdown()
    if self.mode == SegmentPool.MODE_I3D then
        for _, node in ipairs(self.nodes) do
            pcall(function() if delete then delete(node) end end)
        end
        self.nodes = {}
        if self.rootNode then
            pcall(function() if delete then delete(self.rootNode) end end)
            self.rootNode = nil
        end
        self.templateNode = nil
    end
    self.debugLines = {}
    self.mode = SegmentPool.MODE_OFF
    log("shutdown complete")
end
