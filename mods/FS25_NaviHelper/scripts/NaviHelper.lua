--[[
  NaviHelper.lua
  FS25 manual driving navigation: shows arrow + distance to destination.
  Primary UX: Set destination in AutoDrive UI; NaviHelper shows nav aid to that target
  (drive manually or let AutoDrive drive). Fallback: own target via map click / test key.
]]

NaviHelper = {}
NaviHelper.MOD_NAME = "FS25_NaviHelper"
NaviHelper.LOG_PREFIX = "[NaviHelper]"

-- Capture the mod directory AT FILE LOAD TIME. g_currentModDirectory is only valid
-- while the script is being sourced; in the loadMap callback it is already nil, which
-- left NaviHelper.modDirectory empty and broke the map-dot overlay asset load.
NaviHelper.modDirectory = g_currentModDirectory
NaviHelper.modName = g_currentModName

-- State: nav aid is OFF until user presses Alt+N (toggle). Then show arrow if target exists, else show notification.
NaviHelper.uiVisible = true
NaviHelper.navAidOn = false   -- User activates with Alt+N; if no target we show ingame message
NaviHelper.pathDirty = true
NaviHelper.DRIFT_THRESHOLD_SQ = 50 * 50  -- recalc route only after vehicle drifts this far (squared meters)
NaviHelper.lastRouteUpdateTime = 0
NaviHelper.routeUpdateInterval = 2000  -- ms: at most once every 2 seconds
NaviHelper.lastEffectiveTarget = nil  -- cache last effective target to avoid recalculating every frame
NaviHelper.lastEffectiveTargetTime = 0
NaviHelper.effectiveTargetCacheTime = 4000  -- ms: 4s when we have a path; shorter when no path so we retry sooner
NaviHelper.effectiveTargetCacheTimeNoPath = 600  -- ms: when no path and no sticky path, retry path calc
-- Sticky route (like real navi): keep showing last route for a while after leaving it, recalc only after grace or when far off.
NaviHelper.stickyPathGracePeriodMs = 45000   -- 45s: keep showing last path before recalculating
NaviHelper.stickyPathMaxDistance = 120       -- m: if vehicle is farther from path, recalc immediately
NaviHelper.lastValidPath = nil
NaviHelper.lastValidPathTime = 0
NaviHelper.lastValidDestName = nil
NaviHelper.lastValidTargetX = nil
NaviHelper.lastValidTargetZ = nil
NaviHelper.distanceCacheTime = 500  -- ms: 0.5s recalc for distance/turn
NaviHelper.lastDistanceUpdateTime = 0
NaviHelper.cachedDistNext = nil
NaviHelper.cachedDistTotal = nil
NaviHelper.cachedTurnDist = nil
NaviHelper.cachedTurnDir = nil
NaviHelper.cachedPointX = nil
NaviHelper.cachedPointZ = nil
NaviHelper.lastDrawnPathHash = nil  -- hash of last drawn path to detect changes
NaviHelper.lastDrawnPathIdx = nil
NaviHelper.arrowOverlayId = nil
-- Arrow position: normalized screen (0–1). GDN origin = bottom-left. 0.5 = center X; 0.12 = lower area (above speedometer).
NaviHelper.arrowSize = 0.04
NaviHelper.hudCenterX = 0.5
NaviHelper.hudCenterY = 0.12
-- Vehicle to draw for (controlledVehicle is nil in draw context in FS25; we store it when user presses Alt+N).
NaviHelper.drawVehicle = nil
-- Per-vehicle cache for manual target (targetX, targetZ, pathNodes) so switching vehicles shows the right path or none.
NaviHelper.vehicleTargets = {}
-- Route line config (color RGB 0-1, thickness = scale factor, max segments to draw).
NaviHelper.routeLineColorR = 0.2
NaviHelper.routeLineColorG = 0.8
NaviHelper.routeLineColorB = 0.2
NaviHelper.routeLineThickness = 1.2  -- scale factor for line thickness (1.0 = default, higher = thicker, uses AutoDrive's I3D system)
NaviHelper.routeLineMaxSegments = 50  -- segments to draw (was 20 for perf test; 50 for better visibility)
-- Set false to disable route line on ground (use if ADDrawingManager causes 4 FPS / accumulation).
NaviHelper.drawRouteOnGround = true
-- Route line I3D: when available we use AutoDrive's drawing/line.i3d (our scene, so it is not cleared).
NaviHelper.AUTODRIVE_MOD_NAME = "FS25_AutoDrive"
NaviHelper.routeLineRootNode = nil
NaviHelper.routeLineSegmentNodes = nil   -- table of cloned line nodes (max routeLineMaxSegments)
NaviHelper.routeLineSharedI3D = nil     -- keep reference so shared I3D is not released
NaviHelper.routeLineUseI3D = false      -- true when AutoDrive line.i3d was loaded successfully

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info(NaviHelper.LOG_PREFIX .. " " .. fmt, ...)
    end
end

local function logError(fmt, ...)
    if Logging and Logging.error then
        Logging.error(NaviHelper.LOG_PREFIX .. " " .. fmt, ...)
    end
end

local function logDevError(fmt, ...)
    if Logging and Logging.devError then
        Logging.devError(NaviHelper.LOG_PREFIX .. " " .. fmt, ...)
    end
end

-- Localized text with a hard fallback. Robust against a missing key: g_i18n:getText
-- returns "Missing 'KEY' in ..." for unknown keys, so we check hasText first and also
-- guard against that prefix — the fallback must never show the raw engine string.
local function tr(key, fallback)
    if g_i18n and g_i18n.getText then
        if g_i18n.hasText and not g_i18n:hasText(key) then
            return fallback
        end
        local text = g_i18n:getText(key)
        if text == nil or text == "" or text:sub(1, 8) == "Missing " then
            return fallback
        end
        return text
    end
    return fallback
end

-- Stable key for per-vehicle storage (rootNode is entity id).
-- Defined here (before first use) so onClearTarget/onSetTargetAhead/ingameMapMouseEvent can call it.
local function vehicleKey(vehicle)
    if not vehicle or not vehicle.rootNode then return nil end
    return tostring(vehicle.rootNode)
end

function NaviHelper:loadMap(name)
    -- Load persisted tuning values (modSettings/FS25_NaviHelper.xml) and apply them.
    if NaviHelperSettings and NaviHelperSettings.loadFromXML then
        NaviHelperSettings:loadFromXML()
        for _, k in ipairs(NaviHelperSettings:keys()) do
            if NaviHelperSettings[k] ~= nil then NaviHelper[k] = NaviHelperSettings[k] end
        end
    end
    log("loaded drawRouteOnGround=%s effectiveTargetCache=%dms distanceCache=%dms",
        tostring(NaviHelper.drawRouteOnGround),
        NaviHelper.effectiveTargetCacheTime or 0, NaviHelper.distanceCacheTime or 500)
    NaviHelper.modDirectory = NaviHelper.modDirectory or g_currentModDirectory
    if not NaviHelper.modDirectory and g_modManager then
        local m = g_modManager:getModByName(NaviHelper.MOD_NAME)
        if m and m.directory then NaviHelper.modDirectory = m.directory end
    end
    if NaviHelperAD and NaviHelperAD.isAvailable and NaviHelperAD.isAvailable() then
        log("AutoDrive detected, version: %s", tostring(NaviHelperAD.getVersion and NaviHelperAD.getVersion() or "?"))
    else
        log("AutoDrive not found; using air-line fallback only.")
    end

    -- Try to load AutoDrive's line.i3d for route line (our scene node, so it won't be cleared by their manager).
    NaviHelper:tryLoadAutoDriveRouteLineI3D()

    -- Load the pre-baked road graph for this map (if a processed-map file exists).
    if RoadGraphFile and RoadGraphFile.load then pcall(RoadGraphFile.load) end
    -- Reset the grey-terrain router cache for the new map.
    if GreyRouter and GreyRouter.reset then pcall(GreyRouter.reset) end

    -- Hook the in-game map frame's click callback. It hands us WORLD coordinates
    -- directly (frame, element, worldX, worldZ) — robust, unlike a self-rolled
    -- screen->world conversion. Ctrl+click = add point, Shift+click = remove last.
    if InGameMenuMapFrame ~= nil and InGameMenuMapFrame.onClickMap ~= nil and not NaviHelper._mapClickHooked then
        InGameMenuMapFrame.onClickMap = Utils.appendedFunction(InGameMenuMapFrame.onClickMap, NaviHelper.onMapClick)
        NaviHelper._mapClickHooked = true
        log("map click hook installed (InGameMenuMapFrame.onClickMap)")
    end

    -- Draw route dots on the open map (the "Böbbel").
    if InGameMenu ~= nil and InGameMenu.draw ~= nil and not NaviHelper._menuDrawHooked then
        InGameMenu.draw = Utils.appendedFunction(InGameMenu.draw, NaviHelper.drawMenuMap)
        NaviHelper._menuDrawHooked = true
        log("menu map draw hook installed (InGameMenu.draw)")
    end

    -- Action events are registered by NaviHelperVehicle specialization (VEHICLE category).
end

-- Load AutoDrive's drawing/line.i3d and create a segment pool for our route line (our scene, so nothing clears it).
function NaviHelper:tryLoadAutoDriveRouteLineI3D()
    if not g_modManager or not g_currentMission or not g_currentMission.terrainRootNode then return end
    if NaviHelper.routeLineRootNode then return end -- already loaded

    local adMod = g_modManager:getModByName(NaviHelper.AUTODRIVE_MOD_NAME)
    if not adMod or not adMod.directory then
        log("AutoDrive mod not found; route line will use drawDebugLine.")
        return
    end

    local path = Utils.getFilename("drawing/line.i3d", adMod.directory)
    if not path or path == "" then return end

    local node, sharedI3D = nil, nil
    local ok, err = pcall(function()
        node, sharedI3D = loadSharedI3DFile(path)
    end)
    if not ok or not node then
        if err then log("Could not load AutoDrive line.i3d: %s", tostring(err)) end
        return
    end

    -- Keep shared I3D referenced so it is not released.
    NaviHelper.routeLineSharedI3D = sharedI3D

    -- Create our root and attach to terrain so nothing else clears our nodes.
    local root = createTransformGroup("NaviHelperRouteLineRoot")
    if not root then
        if releaseSharedI3DFile then releaseSharedI3DFile(sharedI3D) end
        NaviHelper.routeLineSharedI3D = nil
        return
    end
    link(g_currentMission.terrainRootNode, root)
    NaviHelper.routeLineRootNode = root

    -- Segment template: use root of line.i3d (usually one mesh child). Clone it N times.
    local numSegments = math.max(1, NaviHelper.routeLineMaxSegments or 20)
    local segments = {}
    for i = 1, numSegments do
        local cloneNode = clone(node)
        if cloneNode then
            link(root, cloneNode)
            segments[i] = cloneNode
        end
    end

    NaviHelper.routeLineSegmentNodes = segments
    NaviHelper.routeLineUseI3D = (#segments > 0)
    if NaviHelper.routeLineUseI3D then
        log("Using AutoDrive line.i3d for route line (%d segments).", #segments)
    end
end

-- Show ingame notification (top-right). INGAME_NOTIFICATION_OK = green/success style.
local function showIngameNotification(text)
    if not g_currentMission or type(g_currentMission.addIngameNotification) ~= "function" then return end
    local ok, err = pcall(function()
        local notifType = (FSBaseMission and FSBaseMission.INGAME_NOTIFICATION_OK) or 0
        g_currentMission:addIngameNotification(notifType, text or "NaviHelper")
    end)
    if not ok then logError("addIngameNotification: %s", tostring(err)) end
end

function NaviHelper:onToggleUI(vehicle)
    NaviHelper.navAidOn = not NaviHelper.navAidOn
    -- Store vehicle for drawing (g_currentMission.controlledVehicle is nil in draw context in FS25).
    if NaviHelper.navAidOn then
        NaviHelper.drawVehicle = vehicle or NaviHelper.lastActiveVehicle
    else
        NaviHelper.drawVehicle = nil
    end
    log("NaviHelper nav aid %s", NaviHelper.navAidOn and "ON" or "OFF")
    if NaviHelper.navAidOn then
        NaviHelper._destinationReachedNotifShown = false
        local effX, effZ
        local ok, err = pcall(function()
            effX, effZ = self:getEffectiveTarget(vehicle)
        end)
        if not ok and logError then
            logError("getEffectiveTarget: %s", tostring(err))
        end
        if not effX or not effZ then
            local adAvail = NaviHelperAD and NaviHelperAD.isAvailable and NaviHelperAD.isAvailable()
            local msg
            if g_i18n and g_i18n.getText then
                msg = adAvail and g_i18n:getText("NAVIHELPER_MSG_SELECT_TARGET_IN_AD") or g_i18n:getText("NAVIHELPER_MSG_NEED_AUTODRIVE")
            else
                msg = adAvail and "NaviHelper: Bitte in AutoDrive ein Ziel wählen." or "NaviHelper: AutoDrive wird benötigt."
            end
            showIngameNotification(msg)
        end
    end
end

-- Invalidate caches after a route change so it shows immediately (the ~4s
-- effective-target cache would otherwise make a fresh click feel dead).
function NaviHelper:invalidateRouteCaches()
    NaviHelper.pathDirty = true
    NaviHelper.lastEffectiveTarget = nil
    NaviHelper.lastDistanceUpdateTime = 0
    NaviHelper.lastValidPath = nil
    NaviHelper.lastValidTargetX = nil
    NaviHelper.lastValidTargetZ = nil
end

-- Per-vehicle manual route slot. route = ordered list of {x,z}; last element is
-- the destination (1st click), earlier elements are intermediate waypoints.
function NaviHelper:routeSlot(vehicle, create)
    local key = vehicle and vehicleKey(vehicle)
    if not key then return nil, nil end
    if not NaviHelper.vehicleTargets then NaviHelper.vehicleTargets = {} end
    local slot = NaviHelper.vehicleTargets[key]
    if not slot and create then
        slot = { route = {}, pathNodes = nil, currentPathIndex = 1 }
        NaviHelper.vehicleTargets[key] = slot
    end
    return slot, key
end

function NaviHelper:onClearTarget(vehicle)
    vehicle = vehicle or NaviHelper.drawVehicle or (g_currentMission and g_currentMission.controlledVehicle)
    local key = vehicle and vehicleKey(vehicle)
    if key and NaviHelper.vehicleTargets then
        NaviHelper.vehicleTargets[key] = nil
    end
    self:invalidateRouteCaches()
    log("Route cleared")
end

-- No map-selection mode anymore: points are set with Ctrl+click directly in the
-- big map. The bound key just shows a hint.
function NaviHelper:onMapSelectionMode()
    local msg = (g_i18n and g_i18n.getText and g_i18n:getText("NAVIHELPER_MSG_MAP_HINT"))
        or "NaviHelper: In der Karte Strg+Klick = Punkt setzen, Umschalt+Klick = letzten löschen."
    showIngameNotification(msg)
end

function NaviHelper:onSetTargetAhead(vehicle)
    local v = vehicle or NaviHelper.drawVehicle or (g_currentMission and g_currentMission.controlledVehicle)
    if v and v.components and v.components[1] and v.components[1].node then
        local x, _, z = getWorldTranslation(v.components[1].node)
        local heading = self:getVehicleHeadingY(v)
        local dist = 80
        local tx = x + math.sin(-heading) * dist
        local tz = z + math.cos(-heading) * dist
        local slot = self:routeSlot(v, true)
        if slot then
            slot.route = { { x = tx, z = tz } }   -- single destination
            slot.pathNodes = nil
        end
        self:invalidateRouteCaches()
        log("Target set ahead: %.1f, %.1f", tx, tz)
    end
end

function NaviHelper:deleteMap()
    -- Persist current tuning values (copy back from NaviHelper in case they changed at runtime).
    if NaviHelperSettings and NaviHelperSettings.saveToXML then
        for _, k in ipairs(NaviHelperSettings:keys()) do
            if NaviHelper[k] ~= nil then NaviHelperSettings[k] = NaviHelper[k] end
        end
        NaviHelperSettings:saveToXML()
    end
    -- The onClickMap / InGameMenu.draw hooks are appended once (guarded); nothing to undo.
    if NaviHelper.dotOverlayId ~= nil and delete ~= nil then
        delete(NaviHelper.dotOverlayId)
    end
    NaviHelper.dotOverlayId = nil
    NaviHelper.arrowOverlayId = nil
    -- Release route line I3D (AutoDrive asset).
    if NaviHelper.routeLineSharedI3D and releaseSharedI3DFile then
        releaseSharedI3DFile(NaviHelper.routeLineSharedI3D)
    end
    NaviHelper.routeLineSharedI3D = nil
    NaviHelper.routeLineSegmentNodes = nil
    NaviHelper.routeLineRootNode = nil
    NaviHelper.routeLineUseI3D = false
end

-- Modifier helpers: prefer the flag tracked in keyEvent, fall back to the raw
-- key state (mirrors WayPointGPS — isKeyPressed alone can miss during the click).
local function isCtrlDown()
    if NaviHelper.ctrlDown then return true end
    return Input ~= nil and Input.isKeyPressed ~= nil
        and (Input.isKeyPressed(Input.KEY_lctrl) or Input.isKeyPressed(Input.KEY_rctrl))
end

local function isShiftDown()
    if NaviHelper.shiftDown then return true end
    return Input ~= nil and Input.isKeyPressed ~= nil
        and (Input.isKeyPressed(Input.KEY_lshift) or Input.isKeyPressed(Input.KEY_rshift))
end

-- Keep the destination mirrored to slot.targetX/targetZ so the existing
-- distance/reached code (which still reads targetX/targetZ) keeps working.
function NaviHelper:syncDestShim(slot)
    local n = (slot.route and #slot.route) or 0
    if n > 0 then
        slot.targetX, slot.targetZ = slot.route[n].x, slot.route[n].z
    else
        slot.targetX, slot.targetZ = nil, nil
    end
end

-- Appended to InGameMenuMapFrame.onClickMap: it hands us world coordinates
-- directly. Ctrl+click adds a point, Shift+click removes the most recent one.
-- Plain clicks are ignored so normal map use is unaffected.
function NaviHelper.onMapClick(frame, element, worldX, worldZ)
    if g_inGameMenu == nil or not g_inGameMenu.isOpen then return end
    if worldX == nil or worldZ == nil then return end
    local ctrl, shift = isCtrlDown(), isShiftDown()
    if not (ctrl or shift) then return end

    -- Debounce: the callback can fire more than once for a single physical click.
    local now = (g_currentMission and g_currentMission.time) or 0
    if NaviHelper._lastMapClickTime and (now - NaviHelper._lastMapClickTime) < 250 then return end
    NaviHelper._lastMapClickTime = now

    local v = NaviHelper.drawVehicle or NaviHelper.lastActiveVehicle
        or (g_currentMission and g_currentMission.controlledVehicle)
    if v == nil then
        log("map click ignored: no active vehicle")
        return
    end

    if shift then
        local slot = NaviHelper:routeSlot(v, false)
        if slot and slot.route and #slot.route > 0 then
            table.remove(slot.route)                  -- drop most recent point (LIFO)
            if #slot.route == 0 then
                NaviHelper:onClearTarget(v)
                log("map: last point removed, route empty")
                return
            end
            NaviHelper:syncDestShim(slot)
            NaviHelper:invalidateRouteCaches()
            log("map: removed last point (%d left)", #slot.route)
        end
        return
    end

    -- Ctrl: add a point. 1st click = destination (driven last); each further click
    -- = an intermediate waypoint inserted BEFORE the destination, so drive order is
    -- vehicle -> waypoints (in click order) -> destination.
    local slot = NaviHelper:routeSlot(v, true)
    local p = { x = worldX, z = worldZ }
    if #slot.route == 0 then
        slot.route[1] = p
    else
        table.insert(slot.route, #slot.route, p)
    end
    NaviHelper:syncDestShim(slot)
    NaviHelper:invalidateRouteCaches()
    -- Setting a route turns the nav aid on for this vehicle, so closing the map
    -- immediately shows the arrow + ground route line (no extra Alt+N needed).
    NaviHelper.navAidOn = true
    NaviHelper.drawVehicle = v
    log("map: point added at %.1f, %.1f (route now %d pts)", worldX, worldZ, #slot.route)
end

-- World -> screen position on the open fullscreen map (inverse of the onClickMap
-- transform; same formula WayPointGPS uses for its map markers).
local function menuMapElement()
    if g_inGameMenu == nil then return nil end
    return g_inGameMenu.baseIngameMap or g_inGameMenu.ingameMap
end

-- True only while the fullscreen MAP page is the visible one. Uses the page frame's
-- own visibility (getIsVisible walks the parent chain), which is reliable across
-- builds — unlike comparing page names/objects. Without this, dots would paint over
-- every ESC sub-page (calendar, prices, ...).
local function isMenuMapPageActive()
    if g_inGameMenu == nil or not g_inGameMenu.isOpen then return false end
    local page = g_inGameMenu.pageMapOverview or g_inGameMenu.pageMap
    if page ~= nil and page.getIsVisible ~= nil then
        local ok, vis = pcall(page.getIsVisible, page)
        if ok then return vis == true end
    end
    local map = menuMapElement()
    if map ~= nil and map.getIsVisible ~= nil then
        local ok, vis = pcall(map.getIsVisible, map)
        if ok then return vis == true end
    end
    return false
end

local function worldToMenuMapPos(wx, wz)
    local map = menuMapElement()
    if map == nil then return nil, nil end
    local layout = map.fullScreenLayout or map.layout
    if layout == nil or layout.getMapObjectPosition == nil then return nil, nil end
    if map.worldCenterOffsetX == nil or map.worldSizeX == nil
        or map.worldCenterOffsetZ == nil or map.worldSizeZ == nil then return nil, nil end
    local mapX = (wx + map.worldCenterOffsetX) / map.worldSizeX * 0.5 + 0.25
    local mapZ = (wz + map.worldCenterOffsetZ) / map.worldSizeZ * 0.5 + 0.25
    if mapX < 0.25 or mapX > 0.75 or mapZ < 0.25 or mapZ > 0.75 then return nil, nil end
    local ok, sx, sy = pcall(layout.getMapObjectPosition, layout, mapX, mapZ, 0, 0, 0, true)
    if ok and sx ~= nil then return sx, sy end
    return nil, nil
end

-- Draw a dotted breadcrumb along a whole screen-space polyline. Arc-length stepping
-- drops a dot every `spacing` regardless of node density, so it works both for a dense
-- AD road path (many close nodes) and a sparse straight fallback (few far points).
local function drawPolylineBreadcrumb(overlayId, pts, aspect)
    if pts == nil or #pts == 0 then return end
    local spacing = 0.009
    local w = 0.0045
    local h = w * aspect
    setOverlayColor(overlayId, 0.27, 0.77, 0.37, 0.7)
    local function dot(x, y) renderOverlay(overlayId, x - w * 0.5, y - h * 0.5, w, h) end
    dot(pts[1][1], pts[1][2])
    local acc = 0
    for i = 1, #pts - 1 do
        local x1, y1 = pts[i][1], pts[i][2]
        local x2, y2 = pts[i + 1][1], pts[i + 1][2]
        local sdx, sdy = x2 - x1, y2 - y1
        local seglen = math.sqrt(sdx * sdx + sdy * sdy)
        if seglen > 0 then
            local pos = spacing - acc
            while pos < seglen do
                local t = pos / seglen
                dot(x1 + sdx * t, y1 + sdy * t)
                pos = pos + spacing
            end
            acc = (acc + seglen) % spacing
        end
    end
end

-- Throttled diagnostic: log at most a few times so we can see why dots don't show
-- without spamming (drawMenuMap runs every frame).
local function mapDiag(fmt, ...)
    NaviHelper._mapDiagCount = (NaviHelper._mapDiagCount or 0)
    if NaviHelper._mapDiagCount >= 8 then return end
    NaviHelper._mapDiagCount = NaviHelper._mapDiagCount + 1
    log("drawMenuMap diag: " .. fmt, ...)
end

-- R1 debug overlay: project every RoadGraph node onto the open map. Normal nodes
-- small cyan, junctions (degree>=3) larger amber. Nodes only — the road lines are
-- implied by node density; this is enough to verify coverage + junction welding.
function NaviHelper._drawRoadGraph(aspect)
    local id = NaviHelper.dotOverlayId
    local nodes, adj = RoadGraph.nodes, RoadGraph.adj
    local w = 0.0035
    local h = w * aspect
    local jw = 0.007
    local jh = jw * aspect
    for i = 1, #nodes do
        local nd = nodes[i]
        local sx, sy = worldToMenuMapPos(nd.x, nd.z)
        if sx ~= nil then
            local deg = (adj[i] ~= nil) and #adj[i] or 0
            if deg >= 3 then
                setOverlayColor(id, 1.0, 0.62, 0.0, 0.95)
                renderOverlay(id, sx - jw * 0.5, sy - jh * 0.5, jw, jh)
            else
                setOverlayColor(id, 0.20, 0.75, 0.95, 0.8)
                renderOverlay(id, sx - w * 0.5, sy - h * 0.5, w, h)
            end
        end
    end
    setOverlayColor(id, 1, 1, 1, 1)
end

-- ---- G1: drivability heatmap (verify the getIsPositionReachable oracle) ----------
NaviHelper.reachMapOn = false
NaviHelper.reachCells = nil   -- cached list of reachable {x,z} world points

local function terrainHeight(x, z)
    local m = g_currentMission
    if getTerrainHeightAtWorldPos ~= nil and m ~= nil and m.terrainRootNode ~= nil then
        local ok, h = pcall(getTerrainHeightAtWorldPos, m.terrainRootNode, x, 0, z)
        if ok and h ~= nil then return h end
    end
    return 0
end

-- Drivability oracle: AISystem:getIsPositionReachable(x, y, z) (cheap; ~0.0004 ms).
function NaviHelper.isReachable(x, z)
    local ai = g_currentMission and g_currentMission.aiSystem
    if ai == nil or ai.getIsPositionReachable == nil then return false end
    local ok, val = pcall(ai.getIsPositionReachable, ai, x, terrainHeight(x, z), z)
    return ok and (val == true or (type(val) == "number" and val ~= 0))
end

-- Sample the whole map once. Store EVERY cell with its reachable flag so the overlay
-- can show green (reachable) vs red (not) — to judge how well the oracle discriminates.
function NaviHelper.buildReachMap(spacing)
    spacing = spacing or 24
    local m = g_currentMission
    local ts = (m and m.terrainSize) or 2048
    local half = ts / 2
    local cells, total, reach = {}, 0, 0
    local x = -half
    while x <= half do
        local z = -half
        while z <= half do
            total = total + 1
            local ok = NaviHelper.isReachable(x, z)
            if ok then reach = reach + 1 end
            cells[#cells + 1] = { x, z, ok }
            z = z + spacing
        end
        x = x + spacing
    end
    NaviHelper.reachCells = cells
    log("reach heatmap: %d/%d reachable (%.0f%%) @ %.0fm spacing", reach, total,
        (total > 0 and reach / total * 100 or 0), spacing)
end

function NaviHelper._drawReachMap(aspect)
    local cells = NaviHelper.reachCells
    if cells == nil then return end
    local id = NaviHelper.dotOverlayId
    local w = 0.004
    local h = w * aspect
    for i = 1, #cells do
        local c = cells[i]
        local sx, sy = worldToMenuMapPos(c[1], c[2])
        if sx ~= nil then
            if c[3] then
                setOverlayColor(id, 0.27, 0.77, 0.37, 0.5)   -- reachable = green
            else
                setOverlayColor(id, 0.95, 0.20, 0.20, 0.9)   -- not reachable = red
            end
            renderOverlay(id, sx - w * 0.5, sy - h * 0.5, w, h)
        end
    end
    setOverlayColor(id, 1, 1, 1, 1)
end

function NaviHelper:consoleReachMap()
    NaviHelper.reachMapOn = not NaviHelper.reachMapOn
    if NaviHelper.reachMapOn and NaviHelper.reachCells == nil then
        NaviHelper.buildReachMap(24)
    end
    return "reach heatmap " .. (NaviHelper.reachMapOn and "AN" or "aus")
        .. (NaviHelper.reachCells and (" (" .. #NaviHelper.reachCells .. " Punkte)") or "")
end

if addConsoleCommand ~= nil then
    addConsoleCommand("nhReachMap", "NaviHelper G1: Befahrbarkeits-Heatmap an/aus", "consoleReachMap", NaviHelper)
end

-- ---- POC-H: draw the loaded pre-baked road graph on the map (orientation check) ----
NaviHelper.roadFileOn = false

function NaviHelper._drawRoadFile(aspect)
    if RoadGraphFile == nil or not RoadGraphFile.ready or RoadGraphFile.edges == nil then return end
    local id = NaviHelper.dotOverlayId
    local w = 0.0035
    local h = w * aspect
    setOverlayColor(id, 0.20, 0.75, 0.95, 0.8)
    for k = 1, #RoadGraphFile.edges do
        local pts = RoadGraphFile.edges[k].pts
        for i = 1, #pts, 2 do
            local sx, sy = worldToMenuMapPos(pts[i], pts[i + 1])
            if sx ~= nil then renderOverlay(id, sx - w * 0.5, sy - h * 0.5, w, h) end
        end
    end

    setOverlayColor(id, 1, 1, 1, 1)
end

function NaviHelper:consoleRoadFile()
    NaviHelper.roadFileOn = not NaviHelper.roadFileOn
    local n = (RoadGraphFile and RoadGraphFile.nodes) and #RoadGraphFile.nodes or 0
    return "road graph overlay " .. (NaviHelper.roadFileOn and "AN" or "aus")
        .. " (map=" .. tostring(RoadGraphFile and RoadGraphFile.mapKey) .. ", " .. n .. " Knoten)"
end

if addConsoleCommand ~= nil then
    addConsoleCommand("nhRoadFile", "NaviHelper POC-H: geladenen Straßengraph auf Karte zeichnen", "consoleRoadFile", NaviHelper)
end

-- Log the map's world<->image projection params (needed to re-export the road graph
-- with the correct overview-pixel->world mapping). Open the map first.
function NaviHelper:consoleMapInfo()
    local map = menuMapElement()
    local m = g_currentMission
    if map == nil then return "Karte zuerst oeffnen (ESC-Map), dann nhMapInfo" end
    local s = string.format("MAPINFO offsetX=%s offsetZ=%s sizeX=%s sizeZ=%s terrain=%s title=%s",
        tostring(map.worldCenterOffsetX), tostring(map.worldCenterOffsetZ),
        tostring(map.worldSizeX), tostring(map.worldSizeZ),
        tostring(m and m.terrainSize),
        tostring((m and m.missionInfo and m.missionInfo.mapTitle) or (m and m.mapTitle)))
    log("%s", s)
    return s
end

if addConsoleCommand ~= nil then
    addConsoleCommand("nhMapInfo", "NaviHelper: Karten-Projektionsparameter loggen", "consoleMapInfo", NaviHelper)
end

-- Appended to InGameMenu.draw: draw the route points as dots on the open map.
-- Destination (last point) green, intermediate waypoints orange. pcall-wrapped so
-- a draw error can never take down the whole in-game menu.
function NaviHelper.drawMenuMap()
    local ok, err = pcall(NaviHelper._drawMenuMapInner)
    if not ok then mapDiag("ERROR %s", tostring(err)) end
end

function NaviHelper._drawMenuMapInner()
    if g_inGameMenu == nil or not g_inGameMenu.isOpen then return end
    if not isMenuMapPageActive() then return end  -- only on the map page, not calendar/prices/etc.

    -- Overlay (lazy create). Shared by the route dots and the R1 graph debug overlay.
    if NaviHelper.dotOverlayId == nil and createImageOverlay ~= nil and NaviHelper.modDirectory then
        NaviHelper.dotOverlayId = createImageOverlay(NaviHelper.modDirectory .. "textures/dot.png")
    end
    if NaviHelper.dotOverlayId == nil then return end

    local aspect = g_screenAspectRatio or (16 / 9)

    -- R1 debug overlay: draw the whole RoadGraph (toggle with console command "nhGraph").
    if RoadGraph ~= nil and RoadGraph.debugDraw and RoadGraph.ready and RoadGraph.nodes ~= nil then
        NaviHelper._drawRoadGraph(aspect)
    end

    -- G1 debug overlay: drivability heatmap (toggle with console command "nhReachMap").
    if NaviHelper.reachMapOn and NaviHelper.reachCells ~= nil then
        NaviHelper._drawReachMap(aspect)
    end

    -- POC-H overlay: pre-baked road graph (toggle with console command "nhRoadFile").
    if NaviHelper.roadFileOn then
        NaviHelper._drawRoadFile(aspect)
    end

    local v = NaviHelper.drawVehicle or NaviHelper.lastActiveVehicle
        or (g_currentMission and g_currentMission.controlledVehicle)
    if v == nil then return end
    local key = vehicleKey(v)
    local slot = key and NaviHelper.vehicleTargets and NaviHelper.vehicleTargets[key]
    if not slot or not slot.route or #slot.route == 0 then return end

    local n = #slot.route

    -- Route line: follow the actual computed path (road-routed via AutoDrive where the
    -- AD network covers it), falling back to a straight vehicle->waypoints->dest line
    -- when no path has been built yet.
    local worldLine = {}
    if slot.pathNodes ~= nil and #slot.pathNodes >= 2 then
        for i = 1, #slot.pathNodes do
            worldLine[#worldLine + 1] = { slot.pathNodes[i].x, slot.pathNodes[i].z }
        end
    else
        local vx, _, vz = NaviHelper:getVehiclePosition(v)
        if vx and vz then worldLine[#worldLine + 1] = { vx, vz } end
        for i = 1, n do worldLine[#worldLine + 1] = { slot.route[i].x, slot.route[i].z } end
    end
    local screenLine = {}
    for i = 1, #worldLine do
        local sx, sy = worldToMenuMapPos(worldLine[i][1], worldLine[i][2])
        if sx then screenLine[#screenLine + 1] = { sx, sy } end
    end
    drawPolylineBreadcrumb(NaviHelper.dotOverlayId, screenLine, aspect)

    local converted = 0
    for i = 1, n do
        local p = slot.route[i]
        local sx, sy = worldToMenuMapPos(p.x, p.z)
        if sx ~= nil then
            converted = converted + 1
            local isDest = (i == n)
            local w = isDest and 0.013 or 0.010
            local h = w * aspect
            local ow = w + 0.004
            local oh = ow * aspect
            setOverlayColor(NaviHelper.dotOverlayId, 0, 0, 0, 0.9)
            renderOverlay(NaviHelper.dotOverlayId, sx - ow * 0.5, sy - oh * 0.5, ow, oh)
            if isDest then
                setOverlayColor(NaviHelper.dotOverlayId, 0.27, 0.77, 0.37, 1)
            else
                setOverlayColor(NaviHelper.dotOverlayId, 1.0, 0.62, 0.0, 1)
            end
            renderOverlay(NaviHelper.dotOverlayId, sx - w * 0.5, sy - h * 0.5, w, h)
        end
    end
    setOverlayColor(NaviHelper.dotOverlayId, 1, 1, 1, 1)
    mapDiag("rendered %d/%d points (first world=%.1f,%.1f)", converted, n,
        slot.route[1].x, slot.route[1].z)
end

-- Mac: Option+M often sends unicode 0xB5 (µ) instead of KEY_M+modifier, so action binding never fires
local UNICODE_MAC_OPTION_M = 0xB5  -- µ (Option+M on many Mac layouts)
local keyEventLogged = false

function NaviHelper:keyEvent(unicode, sym, modifier, isDown)
    -- Track Ctrl/Shift state as a fallback for the onClickMap handler (Input.isKeyPressed
    -- can be unreliable inside that callback). Tracked on both down and up.
    if Input ~= nil then
        if sym == Input.KEY_lctrl or sym == Input.KEY_rctrl then NaviHelper.ctrlDown = isDown end
        if sym == Input.KEY_lshift or sym == Input.KEY_rshift then NaviHelper.shiftDown = isDown end
    end

    if not isDown then return end
    -- Only react when in vehicle (same as action events)
    if not g_currentMission or not g_currentMission.controlledVehicle then return end

    if not keyEventLogged then
        keyEventLogged = true
        log("keyEvent received in vehicle (sym=%s unicode=%s) - NaviHelper keys active", tostring(sym), tostring(unicode))
    end

    local mod = modifier or 0
    local alt = bit32.band(mod, Input.MOD_LALT or 0) ~= 0 or bit32.band(mod, Input.MOD_RALT or 0) ~= 0
    local ctrl = bit32.band(mod, Input.MOD_LCTRL or 0) ~= 0

    -- Mac Option+M fallback: often arrives as unicode µ (0xB5) without modifier
    if unicode == UNICODE_MAC_OPTION_M then
        NaviHelper:onMapSelectionMode()
        return
    end

    -- Fallback when action events are not used
    if alt and sym == Input.KEY_N then
        NaviHelper:onToggleUI()
        return
    end
    if ctrl and sym == Input.KEY_N then
        NaviHelper:onClearTarget()
        return
    end
    if alt and sym == Input.KEY_M then
        NaviHelper:onMapSelectionMode()
        return
    end
    if alt and sym == Input.KEY_T then
        NaviHelper:onSetTargetAhead()
        return
    end

    -- F-key fallbacks (work when Option+letter is consumed by Mac as special char)
    local f9, f10, f11, f12 = Input.KEY_f9, Input.KEY_f10, Input.KEY_f11, Input.KEY_f12
    if f9 and sym == f9 then NaviHelper:onMapSelectionMode(); return end
    if f10 and sym == f10 then NaviHelper:onToggleUI(); return end
    if f11 and sym == f11 then NaviHelper:onClearTarget(); return end
    if f12 and sym == f12 then NaviHelper:onSetTargetAhead(); return end
end

function NaviHelper:getVehiclePosition(vehicle)
    local v = vehicle or NaviHelper.drawVehicle or (g_currentMission and g_currentMission.controlledVehicle)
    if not v or not v.components or not v.components[1] then return nil, nil, nil end
    local node = v.components[1].node
    if not node then return nil, nil, nil end
    local x, y, z = getWorldTranslation(node)
    return x, y, z
end

function NaviHelper:getVehicleHeadingY(vehicle)
    local v = vehicle or NaviHelper.drawVehicle or (g_currentMission and g_currentMission.controlledVehicle)
    if not v or not v.components or not v.components[1] then return 0 end
    local node = v.components[1].node
    local rx, ry, rz = getWorldRotation(node)
    if rx and ry and rz then
        return ry
    end
    if localDirectionToWorld and v.localDirectionToWorld then
        local dx, _, dz = v:localDirectionToWorld(0, 0, 1, node)
        if dx and dz then
            return math.atan2(-dx, dz)
        end
    end
    return 0
end

-- Find next turn in path: returns distance (m), direction ("links", "rechts", "geradeaus"), or nil if no significant turn.
function NaviHelper:findNextTurn(path, pathIdx, vehicle)
    if not path or #path < 3 then return nil, nil end
    local vx, _, vz = self:getVehiclePosition(vehicle)
    if not vx or not vz then return nil, nil end
    
    -- Get vehicle heading to determine which nodes are "ahead".
    local headingY = self:getVehicleHeadingY(vehicle)
    local headingX = math.sin(headingY)
    local headingZ = math.cos(headingY)
    
    -- Find the path node that is ahead of the vehicle (not behind).
    -- We look for the node where the vector from vehicle to node is in the forward direction.
    local startIdx = 1
    local bestForwardDist = -math.huge
    
    -- Use pathIdx as starting point if provided, otherwise start from beginning.
    local searchStart = pathIdx or 1
    for i = searchStart, math.min(#path, searchStart + 30) do  -- reduced from 50 to 30 for larger maps
        local node = path[i]
        if node and node.x and node.z then
            -- Vector from vehicle to node.
            local dx = node.x - vx
            local dz = node.z - vz
            local distSq = dx * dx + dz * dz
            
            -- Dot product with heading: positive = ahead, negative = behind.
            local forwardComponent = dx * headingX + dz * headingZ
            
            -- Prefer nodes that are ahead (forwardComponent > 0) and not too far.
            -- If multiple nodes are ahead, prefer the closest one.
            if forwardComponent > -5.0 then  -- allow small tolerance for nodes slightly behind
                -- Score: prioritize forward direction, then distance.
                local score = forwardComponent - math.sqrt(distSq) * 0.1
                if score > bestForwardDist then
                    bestForwardDist = score
                    startIdx = i
                end
            end
        end
    end
    
    -- Ensure we're not going backwards: if we found a node behind us, use pathIdx or start from 1.
    if startIdx < (pathIdx or 1) then
        startIdx = pathIdx or 1
    end
    
    -- Only announce "Abbiegen" for real turns (e.g. intersections), not road curves or path noise.
    -- Sharp turns (e.g. > 45°) are always announced (Y-junction, intersection). Medium angles use "sustained curve" filter.
    local minTurnAngle = math.rad(25)
    local minSegmentLen = 3
    local sharpTurnAngle = math.rad(45)   -- above this always announce (real junction); below use sustained-curve filter
    local minSegmentLenSharp = 1         -- at junctions waypoints can be close; require only 1m for sharp turns
    local curveAngleThreshold = math.rad(15)
    local lookAhead = 25

    for i = startIdx, math.min(startIdx + lookAhead, #path - 2) do
        local a = path[i]
        local b = path[i + 1]
        local c = path[i + 2]
        if a and b and c and a.x and a.z and b.x and b.z and c.x and c.z then
            local dx1, dz1 = b.x - a.x, b.z - a.z
            local dx2, dz2 = c.x - b.x, c.z - b.z
            local len1 = math.sqrt(dx1 * dx1 + dz1 * dz1)
            local len2 = math.sqrt(dx2 * dx2 + dz2 * dz2)
            if len1 < minSegmentLenSharp or len2 < minSegmentLenSharp then
                -- skip degenerate segments
            else
                dx1, dz1 = dx1 / len1, dz1 / len1
                dx2, dz2 = dx2 / len2, dz2 / len2
                local dot = math.max(-1, math.min(1, dx1 * dx2 + dz1 * dz2))
                local angle = math.acos(dot)
                local crossZ = dx1 * dz2 - dz1 * dx2
                local lenOk = len1 >= minSegmentLen and len2 >= minSegmentLen
                if not lenOk then lenOk = (angle > sharpTurnAngle) end

                if lenOk and angle > minTurnAngle then
                    local isSharp = (angle > sharpTurnAngle)
                    -- Sharp turn (e.g. Y-junction): always announce. Otherwise check sustained curve (road bend).
                    local isSustainedCurve = false
                    if not isSharp and i + 3 <= #path then
                        local d = path[i + 3]
                        if d and d.x and d.z then
                            local dx3 = d.x - c.x
                            local dz3 = d.z - c.z
                            local len3 = math.sqrt(dx3 * dx3 + dz3 * dz3)
                            if len3 >= minSegmentLen then
                                dx3, dz3 = dx3 / len3, dz3 / len3
                                local dot2 = dx2 * dx3 + dz2 * dz3
                                dot2 = math.max(-1, math.min(1, dot2))
                                local angle2 = math.acos(dot2)
                                local crossZ2 = dx2 * dz3 - dz2 * dx3
                                if angle2 > curveAngleThreshold and (crossZ2 * crossZ > 0) then
                                    isSustainedCurve = true
                                end
                            end
                        end
                    end

                    if not isSustainedCurve then
                        local direction = (crossZ > 0) and tr("NAVIHELPER_DIR_RIGHT", "rechts") or tr("NAVIHELPER_DIR_LEFT", "links")
                        local turnPoint = b
                    if turnPoint and turnPoint.x and turnPoint.z then
                        -- Check if turn point is ahead of us (not behind).
                        local dx = turnPoint.x - vx
                        local dz = turnPoint.z - vz
                        local forwardComponent = dx * headingX + dz * headingZ
                        
                        if forwardComponent > -2.0 then  -- turn must be ahead (or very close)
                            -- Calculate driving distance: distance from vehicle to startIdx node + sum of segments to turn point.
                            local distToTurn = 0
                            
                            -- Distance from vehicle to startIdx node (first segment).
                            local startNode = path[startIdx]
                            if startNode and startNode.x and startNode.z then
                                distToTurn = distToTurn + MathUtil.vector2Length(startNode.x - vx, startNode.z - vz)
                            end
                            
                            -- Sum segments from startIdx to turn point (b).
                            for j = startIdx, i do
                                if j < #path then
                                    local p1 = path[j]
                                    local p2 = path[j + 1]
                                    if p1 and p2 and p1.x and p1.z and p2.x and p2.z then
                                        distToTurn = distToTurn + MathUtil.vector2Length(p2.x - p1.x, p2.z - p1.z)
                                    end
                                end
                            end
                            
                            if distToTurn < 5000 then
                                return distToTurn, direction
                            end
                        end
                    end
                    end
                end
            end
        end
    end
    return nil, nil
end

-- Minimum distance from point (px, pz) to path (list of segments). Used to decide if we're still "near" the route.
local function distanceFromPointToPath(px, pz, path)
    if not path or #path < 2 then return math.huge end
    local minDistSq = math.huge
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        if a and b and a.x and a.z and b.x and b.z then
            local vx = b.x - a.x
            local vz = b.z - a.z
            local lenSq = vx * vx + vz * vz
            local t
            if lenSq < 1e-12 then
                t = 0
            else
                t = ((px - a.x) * vx + (pz - a.z) * vz) / lenSq
                t = math.max(0, math.min(1, t))
            end
            local projX = a.x + t * vx
            local projZ = a.z + t * vz
            local d2 = (px - projX) * (px - projX) + (pz - projZ) * (pz - projZ)
            if d2 < minDistSq then minDistSq = d2 end
        end
    end
    return math.sqrt(minDistSq)
end

-- Effective target: from AutoDrive (active path or selected firstMarker) when available, else our own target.
-- When route is left, keep showing last path for stickyPathGracePeriodMs (like real navi) unless vehicle is > stickyPathMaxDistance m off.
-- Returns targetX, targetZ, pathNodes (table or nil), currentPathIndex, destName (e.g. "Gesteinbrecher").
function NaviHelper:getEffectiveTarget(vehicle)
    vehicle = vehicle or (g_currentMission and g_currentMission.controlledVehicle)
    if vehicle == nil then return nil, nil, nil, nil, nil end

    -- Priority 1: a manual map route always wins when set (this reverses the old
    -- behaviour where AutoDrive was checked first). route[#route] is the destination.
    do
        local mkey = vehicleKey(vehicle)
        local slot = mkey and NaviHelper.vehicleTargets and NaviHelper.vehicleTargets[mkey]
        if slot and slot.route and #slot.route > 0 then
            local dest = slot.route[#slot.route]
            return dest.x, dest.z, slot.pathNodes, slot.currentPathIndex or 1, nil
        end
    end

    -- Priority 2: AutoDrive destination (fallback when no manual route is set).
    if NaviHelperAD then
        local x, z, name
        -- Prefer selected destination (firstMarker from UI) so "Hof 1" etc. is used before route is started.
        if NaviHelperAD.getSelectedDestinationFromVehicle then
            x, z, name = NaviHelperAD.getSelectedDestinationFromVehicle(vehicle)
        end
        if (not x or not z) and NaviHelperAD.getCurrentDestinationFromVehicle then
            x, z, name = NaviHelperAD.getCurrentDestinationFromVehicle(vehicle)
        end
        if x and z then
            local currentTime = g_currentMission and g_currentMission.time or 0
            local vx, _, vz = self:getVehiclePosition(vehicle)

            -- If AutoDrive is actively driving, use its current path.
            local wayPoints, idx
            if NaviHelperAD.getCurrentPathFromVehicle then
                wayPoints, idx = NaviHelperAD.getCurrentPathFromVehicle(vehicle)
            end
            if wayPoints and idx and type(idx) == "number" then
                local path = {}
                for i = idx, #wayPoints do
                    local wp = wayPoints[i]
                    if wp and wp.x and wp.z then path[#path + 1] = { x = wp.x, y = wp.y or 0, z = wp.z } end
                end
                if #path > 0 then
                    NaviHelper.lastValidPath = path
                    NaviHelper.lastValidPathTime = currentTime
                    NaviHelper.lastValidDestName = name
                    NaviHelper.lastValidTargetX = x
                    NaviHelper.lastValidTargetZ = z
                    return x, z, path, idx, name
                end
            end

            -- No current path (e.g. left route). Like real navi: keep showing last route for a while unless we're far off.
            local graceMs = NaviHelper.stickyPathGracePeriodMs or 45000
            local maxDist = NaviHelper.stickyPathMaxDistance or 120
            local sameTarget = NaviHelper.lastValidTargetX and NaviHelper.lastValidTargetZ
                and math.abs(x - NaviHelper.lastValidTargetX) < 1 and math.abs(z - NaviHelper.lastValidTargetZ) < 1
            if sameTarget and NaviHelper.lastValidPath and #NaviHelper.lastValidPath > 1
                and (currentTime - NaviHelper.lastValidPathTime) < graceMs and vx and vz then
                local distToPath = distanceFromPointToPath(vx, vz, NaviHelper.lastValidPath)
                if distToPath < maxDist then
                    return x, z, NaviHelper.lastValidPath, 1, name
                end
            end

            -- Grace expired or too far off: compute new route from current position.
            if vx and vz and NaviHelperAD.getPathFromToWorld then
                local computedPath = NaviHelperAD.getPathFromToWorld(vx, vz, x, z)
                if computedPath and #computedPath > 0 then
                    NaviHelper.lastValidPath = computedPath
                    NaviHelper.lastValidPathTime = currentTime
                    NaviHelper.lastValidDestName = name
                    NaviHelper.lastValidTargetX = x
                    NaviHelper.lastValidTargetZ = z
                    return x, z, computedPath, 1, name
                end
            end
            return x, z, nil, nil, name
        end
    end
    return nil, nil, nil, nil, nil
end

-- Build a polyline through vehicle -> route waypoints -> destination.
-- Hybrid: each segment is routed via AutoDrive roads when available, else a
-- straight line. Segment ends are de-duplicated so the line is continuous.
function NaviHelper:buildRoutePath(route, vx, vz)
    if not route or #route == 0 then return nil end

    -- Drive sequence: current vehicle position, then every route point in order.
    local seq = { { x = vx, z = vz } }
    for i = 1, #route do seq[#seq + 1] = { x = route[i].x, z = route[i].z } end

    local nodes = {}
    local greyRouted, roadRouted, adRouted, straightSegs = 0, 0, 0, 0
    local function push(p)
        local last = nodes[#nodes]
        if last and math.abs(last.x - p.x) < 0.5 and math.abs(last.z - p.z) < 0.5 then return end
        nodes[#nodes + 1] = p
    end

    for i = 1, #seq - 1 do
        local a, b = seq[i], seq[i + 1]
        local seg
        -- Priority 1: grey-terrain grid router — roads/streets/tracks on ANY map, no calibration.
        if GreyRouter and GreyRouter.findPath then
            local ok, path = pcall(GreyRouter.findPath, a.x, a.z, b.x, b.z)
            if ok and path and #path > 0 then seg = path; greyRouted = greyRouted + 1 end
        end
        -- Priority 2: pre-baked road graph (processed map), if present.
        if seg == nil and RoadGraphFile and RoadGraphFile.ready and RoadGraphFile.findPath then
            local ok, path = pcall(RoadGraphFile.findPath, a.x, a.z, b.x, b.z)
            if ok and path and #path > 0 then seg = path; roadRouted = roadRouted + 1 end
        end
        -- Priority 3: AutoDrive (optional).
        if seg == nil and NaviHelperAD and NaviHelperAD.getPathFromToWorld then
            local ok, path = pcall(NaviHelperAD.getPathFromToWorld, a.x, a.z, b.x, b.z)
            if ok and path and #path > 0 then seg = path; adRouted = adRouted + 1 end
        end
        if seg then
            for _, wp in ipairs(seg) do push({ x = wp.x, y = wp.y or 0, z = wp.z }) end
        else
            push({ x = a.x, y = 0, z = a.z })
            push({ x = b.x, y = 0, z = b.z })
            straightSegs = straightSegs + 1
        end
    end

    log("Route built: %d nodes from %d segment(s) — %d grey-grid, %d road-graph, %d AD, %d straight",
        #nodes, #seq - 1, greyRouted, roadRouted, adRouted, straightSegs)
    -- Dump the route geometry every rebuild (buildRoutePath only runs on a real change,
    -- not per frame) so we can plot the ACTUAL route the player drove against the overview.
    do
        local parts = {}
        for i = 1, #nodes do parts[#parts + 1] = string.format("%.0f,%.0f", nodes[i].x, nodes[i].z) end
        log("ROUTEDUMP %s", table.concat(parts, " "))
    end
    return (#nodes > 0) and nodes or nil
end

-- Recompute the manual route polyline if dirty or the vehicle has drifted.
function NaviHelper:updateRoute()
    local vehicle = NaviHelper.drawVehicle or NaviHelper.lastActiveVehicle
        or (g_currentMission and g_currentMission.controlledVehicle)
    if not vehicle then return end

    local key = vehicleKey(vehicle)
    local slot = key and NaviHelper.vehicleTargets and NaviHelper.vehicleTargets[key]
    if not slot or not slot.route or #slot.route == 0 then return end

    local currentTime = g_currentMission and g_currentMission.time or 0
    if currentTime - NaviHelper.lastRouteUpdateTime < NaviHelper.routeUpdateInterval then
        return
    end
    NaviHelper.lastRouteUpdateTime = currentTime

    local vx, _, vz = self:getVehiclePosition(vehicle)
    if not vx or not vz then return end

    if NaviHelper.pathDirty then
        slot.pathNodes = self:buildRoutePath(slot.route, vx, vz)
        slot.currentPathIndex = 1
        NaviHelper.pathDirty = false
        slot.lastVehicleX = vx
        slot.lastVehicleZ = vz
        return
    end

    if slot.pathNodes and slot.currentPathIndex then
        local dx = vx - (slot.lastVehicleX or vx)
        local dz = vz - (slot.lastVehicleZ or vz)
        if dx * dx + dz * dz > NaviHelper.DRIFT_THRESHOLD_SQ then
            NaviHelper.pathDirty = true
            slot.lastVehicleX = vx
            slot.lastVehicleZ = vz
        end
    end
end

function NaviHelper:update(dt)
    if RoadStats and RoadStats.maybeAutoLog then pcall(RoadStats.maybeAutoLog) end
    if RoadGraph and RoadGraph.stepBuild and not RoadGraph.ready then pcall(function() RoadGraph:stepBuild() end) end
    -- VTRACK: log vehicle position while driving on roads, for offline overview<->world
    -- calibration (fit the transform so the driven track lands on the overview roads).
    pcall(function()
        local v = (g_currentMission and g_currentMission.controlledVehicle)
            or NaviHelper.lastActiveVehicle
        if v == nil or v.rootNode == nil then return end
        local t = g_currentMission.time or 0
        if NaviHelper._vtrackAt == nil then NaviHelper._vtrackAt = 0 end
        if t - NaviHelper._vtrackAt < 1500 then return end
        local x, _, z = getWorldTranslation(v.rootNode)
        if NaviHelper._vtrackLast then
            local dx, dz = x - NaviHelper._vtrackLast[1], z - NaviHelper._vtrackLast[2]
            if dx * dx + dz * dz < 9 then return end  -- moved < 3m -> skip (parked)
        end
        NaviHelper._vtrackAt = t
        NaviHelper._vtrackLast = { x, z }
        -- sample ground material + COLOR under the tyres (road detection: grey=road).
        local mid, cr, cg, cb = "?", -1, -1, -1
        if getTerrainAttributesAtWorldPos ~= nil and g_currentMission.terrainRootNode ~= nil then
            local ty = 0
            if getTerrainHeightAtWorldPos ~= nil then
                local okh, h = pcall(getTerrainHeightAtWorldPos, g_currentMission.terrainRootNode, x, 0, z)
                if okh and h then ty = h end
            end
            local ok, r, g, b, _, materialId = pcall(getTerrainAttributesAtWorldPos,
                g_currentMission.terrainRootNode, x, ty, z, true, true, true, true, false)
            if ok then
                if materialId ~= nil then mid = tostring(materialId) end
                cr, cg, cb = r or -1, g or -1, b or -1
            end
        end
        log("VTRACK %.1f %.1f mat=%s rgb=%.3f,%.3f,%.3f", x, z, mid, cr, cg, cb)
    end)
    local ok, err = pcall(function()
        local v = NaviHelper.drawVehicle or NaviHelper.lastActiveVehicle
            or (g_currentMission and g_currentMission.controlledVehicle)
        if not v then return end
        self:updateRoute()
    end)
    if not ok then
        logError("update: %s", tostring(err))
    end
end

-- Compute navigation data (effective target, distances, next turn) with caching.
-- Returns a table with the values draw needs, or nil when there is nothing to show.
function NaviHelper:computeNavData(vehicle, currentTime)
    -- Effective target (cached to avoid expensive route calculation every frame).
    local effX, effZ, effPath, effPathIdx, destName
    if NaviHelper.lastEffectiveTarget and (currentTime - NaviHelper.lastEffectiveTargetTime) < NaviHelper.effectiveTargetCacheTime then
        effX, effZ, effPath, effPathIdx, destName = unpack(NaviHelper.lastEffectiveTarget)
    else
        effX, effZ, effPath, effPathIdx, destName = self:getEffectiveTarget(vehicle)
        NaviHelper.lastEffectiveTarget = {effX, effZ, effPath, effPathIdx, destName}
        NaviHelper.lastEffectiveTargetTime = currentTime
        -- No path (e.g. drifted off route): retry path calc sooner.
        if not effPath or #effPath == 0 then
            local noPathCache = NaviHelper.effectiveTargetCacheTimeNoPath or 600
            NaviHelper.lastEffectiveTargetTime = currentTime - (NaviHelper.effectiveTargetCacheTime or 4000) + noPathCache
        end
        NaviHelper.lastDistanceUpdateTime = 0  -- force distance recalc when target/path changes
    end
    if not effX or not effZ then return nil end

    local vx, _, vz = self:getVehiclePosition(vehicle)
    if not vx or not vz then return nil end

    local pointX, pointZ = effX, effZ
    local distNext, distTotal, turnDist, turnDir
    local cacheValid = (currentTime - NaviHelper.lastDistanceUpdateTime) < (NaviHelper.distanceCacheTime or 500)
    if cacheValid and NaviHelper.cachedDistTotal then
        distNext = NaviHelper.cachedDistNext
        distTotal = NaviHelper.cachedDistTotal
        turnDist = NaviHelper.cachedTurnDist
        turnDir = NaviHelper.cachedTurnDir
        pointX = NaviHelper.cachedPointX or effX
        pointZ = NaviHelper.cachedPointZ or effZ
    elseif effPath and #effPath > 0 then
        local nextNode = effPath[2] or effPath[1]
        pointX, pointZ = nextNode.x, nextNode.z
        distNext = MathUtil.vector2Length(nextNode.x - vx, nextNode.z - vz)

        -- First node ahead of the vehicle (start of the remaining route).
        local currentPathIdx = effPathIdx or 1
        local headingY = self:getVehicleHeadingY(vehicle)
        local headingX, headingZ = math.sin(headingY), math.cos(headingY)
        local startIdx = currentPathIdx
        for i = currentPathIdx, math.min(#effPath, currentPathIdx + 40) do
            local node = effPath[i]
            if node and node.x and node.z then
                if (node.x - vx) * headingX + (node.z - vz) * headingZ > -8.0 then
                    startIdx = i
                    break
                end
            end
        end

        -- Exact driving distance (full path sum). Runs only every distanceCacheTime, so no segment cap.
        distTotal = 0
        local startNode = effPath[startIdx]
        if startNode and startNode.x and startNode.z then
            distTotal = distTotal + MathUtil.vector2Length(startNode.x - vx, startNode.z - vz)
        end
        for i = startIdx, #effPath - 1 do
            local p1, p2 = effPath[i], effPath[i + 1]
            if p1 and p2 and p1.x and p1.z and p2.x and p2.z then
                distTotal = distTotal + MathUtil.vector2Length(p2.x - p1.x, p2.z - p1.z)
            end
        end

        turnDist, turnDir = self:findNextTurn(effPath, effPathIdx, vehicle)

        NaviHelper.lastDistanceUpdateTime = currentTime
        NaviHelper.cachedDistNext = distNext
        NaviHelper.cachedDistTotal = distTotal
        NaviHelper.cachedTurnDist = turnDist
        NaviHelper.cachedTurnDir = turnDir
        NaviHelper.cachedPointX = pointX
        NaviHelper.cachedPointZ = pointZ
    else
        distNext = MathUtil.vector2Length(effX - vx, effZ - vz)
        distTotal = distNext
        NaviHelper.lastDistanceUpdateTime = currentTime
        NaviHelper.cachedDistNext = distNext
        NaviHelper.cachedDistTotal = distTotal
        NaviHelper.cachedTurnDist = nil
        NaviHelper.cachedTurnDir = nil
        NaviHelper.cachedPointX = effX
        NaviHelper.cachedPointZ = effZ
    end

    return {
        effPath = effPath, effPathIdx = effPathIdx, destName = destName,
        vx = vx, vz = vz, distTotal = distTotal,
        turnDist = turnDist, turnDir = turnDir,
    }
end

-- Pick the path index to start drawing the route line from: the first node ahead of the
-- vehicle (relaxed tolerance so the line stays visible beside the path), else the closest node.
function NaviHelper:routeLineStartIndex(pathToDraw, effPathIdx, vx, vz, vehicle)
    local startIdx = 1
    if effPathIdx and effPathIdx > 1 then startIdx = math.max(1, effPathIdx - 1) end
    if not (vx and vz) then return startIdx end

    local headingY = self:getVehicleHeadingY(vehicle)
    local headingX, headingZ = math.sin(headingY), math.cos(headingY)
    local pathIdx = effPathIdx or 1
    for i = math.max(1, pathIdx - 1), math.min(#pathToDraw, pathIdx + 60) do
        local node = pathToDraw[i]
        if node and node.x and node.z then
            if (node.x - vx) * headingX + (node.z - vz) * headingZ > -50 then
                return math.max(1, i - 2)
            end
        end
    end
    -- Far off path: anchor at the closest node so the line stays visible.
    local bestI, bestDistSq = 1, 1e10
    for i = 1, math.min(#pathToDraw, pathIdx + 80) do
        local node = pathToDraw[i]
        if node and node.x and node.z then
            local d2 = (node.x - vx) * (node.x - vx) + (node.z - vz) * (node.z - vz)
            if d2 < bestDistSq then bestDistSq = d2; bestI = i end
        end
    end
    return math.max(1, bestI - 2)
end

-- Draw the route line on the ground (AutoDrive's I3D segments, or a drawDebugLine fallback).
function NaviHelper:drawRouteLine(vehicle, pathToDraw, effPathIdx, vx, vz)
    if not NaviHelper.drawRouteOnGround then return end

    local haveSegments = NaviHelper.routeLineUseI3D and NaviHelper.routeLineSegmentNodes
    if not pathToDraw or #pathToDraw <= 1 then
        -- Hide all segments when there is no path.
        if haveSegments then
            pcall(function()
                for _, seg in ipairs(NaviHelper.routeLineSegmentNodes) do
                    if setVisibility then setVisibility(seg, false) end
                end
            end)
        end
        return
    end

    local startIdx = self:routeLineStartIndex(pathToDraw, effPathIdx, vx, vz, vehicle)
    local endIdx = math.min(startIdx + NaviHelper.routeLineMaxSegments, #pathToDraw - 1)
    local numSegmentsToShow = endIdx - startIdx + 1

    if haveSegments and NaviHelper.routeLineRootNode and setWorldTranslation and setWorldRotation and setScale then
        -- AutoDrive's line.i3d segments (our scene, so they stay visible).
        pcall(function()
            for k, seg in ipairs(NaviHelper.routeLineSegmentNodes) do
                local a = (k <= numSegmentsToShow) and pathToDraw[startIdx + k - 1] or nil
                local b_ = (k <= numSegmentsToShow) and pathToDraw[startIdx + k] or nil
                if a and b_ and a.x and a.z and b_.x and b_.z then
                    local y0, y1 = a.y or 0, b_.y or 0
                    if (y0 == 0 or y1 == 0) and g_terrainNode and getTerrainHeightAtWorldPos then
                        if y0 == 0 then y0 = getTerrainHeightAtWorldPos(g_terrainNode, a.x, 0, a.z) or 0 end
                        if y1 == 0 then y1 = getTerrainHeightAtWorldPos(g_terrainNode, b_.x, 0, b_.z) or 0 end
                    end
                    y0, y1 = y0 + 0.2, y1 + 0.2
                    local dx, dz = b_.x - a.x, b_.z - a.z
                    local len = math.sqrt(dx * dx + dz * dz)
                    if len < 0.01 then len = 1 end
                    setWorldTranslation(seg, (a.x + b_.x) * 0.5, (y0 + y1) * 0.5, (a.z + b_.z) * 0.5)
                    setWorldRotation(seg, 0, math.atan2(dx, dz), 0)
                    setScale(seg, (NaviHelper.routeLineThickness or 1), 1, len)
                    if setVisibility then setVisibility(seg, true) end
                elseif setVisibility then
                    setVisibility(seg, false)
                end
            end
        end)
    elseif drawDebugLine then
        -- Fallback: no I3D segments / AutoDrive not available.
        pcall(function()
            local r, g, b = NaviHelper.routeLineColorR, NaviHelper.routeLineColorG, NaviHelper.routeLineColorB
            for i = startIdx, endIdx do
                local a, b_ = pathToDraw[i], pathToDraw[i + 1]
                if a and b_ and a.x and a.z and b_.x and b_.z then
                    local y0, y1 = a.y or 0, b_.y or 0
                    if (y0 == 0 or y1 == 0) and g_terrainNode and getTerrainHeightAtWorldPos then
                        if y0 == 0 then y0 = getTerrainHeightAtWorldPos(g_terrainNode, a.x, 0, a.z) or 0 end
                        if y1 == 0 then y1 = getTerrainHeightAtWorldPos(g_terrainNode, b_.x, 0, b_.z) or 0 end
                    end
                    y0, y1 = y0 + 0.2, y1 + 0.2
                    drawDebugLine(a.x, y0, a.z, r, g, b, b_.x, y1, b_.z, r, g, b, false)
                end
            end
        end)
    end
end

-- Draw the HUD text: destination name, next-turn instruction, total distance.
function NaviHelper:drawHud(distTotal, turnDist, turnDir, destName, effPath)
    -- Turn instruction: distance to next turn; if going straight, only show when very close (like a real navi).
    local turnStr
    if turnDist and turnDir and turnDist < 5000 then
        turnStr = string.format("%s %.0fm %s", tr("NAVIHELPER_HUD_IN", "in"), turnDist, turnDir)
    elseif effPath and #effPath > 2 and distTotal and distTotal < 50 then
        turnStr = string.format("%.0f m", distTotal)
    end
    local totalStr = (distTotal and distTotal < 1e6) and string.format("%.0f m", distTotal) or "-"

    local renderFn = renderText or renderTextOverlay
    if not renderFn then return end
    pcall(function()
        if setTextAlignment then
            setTextAlignment(RenderText and RenderText.ALIGN_CENTER or 1)
        end
        if setTextColor then setTextColor(1, 1, 1, 1) end
        local cx = NaviHelper.hudCenterX
        if destName and destName ~= "" then
            renderFn(cx, NaviHelper.hudCenterY + 0.04, 0.018, destName)
        end
        if turnStr then
            renderFn(cx, NaviHelper.hudCenterY + 0.02, 0.02, turnStr)
        end
        renderFn(cx, NaviHelper.hudCenterY, 0.018, tr("NAVIHELPER_HUD_TOTAL", "Total") .. ": " .. totalStr)
    end)
end

function NaviHelper:drawForVehicle(vehicle)
    if not vehicle then return end
    local currentTime = g_currentMission and g_currentMission.time or 0

    local nav = self:computeNavData(vehicle, currentTime)
    if not nav then return end

    -- Destination reached handling.
    local distTotal = nav.distTotal
    if distTotal and distTotal >= 3 then
        NaviHelper._destinationReachedNotifShown = false
    end
    if distTotal and distTotal < 3 then
        if not NaviHelper._destinationReachedNotifShown then
            NaviHelper._destinationReachedNotifShown = true
            local msg = (g_i18n and g_i18n.getText and g_i18n:getText("NAVIHELPER_MSG_DESTINATION_REACHED")) or "Ziel erreicht"
            showIngameNotification(msg)
        end
        if not nav.destName then
            local v = NaviHelper.drawVehicle
            local key = v and vehicleKey(v)
            if key and NaviHelper.vehicleTargets then NaviHelper.vehicleTargets[key] = nil end
        end
        return
    end

    self:drawRouteLine(vehicle, nav.effPath, nav.effPathIdx, nav.vx, nav.vz)
    self:drawHud(distTotal, nav.turnDist, nav.turnDir, nav.destName, nav.effPath)
end

function NaviHelper:draw()
    local controlled = g_currentMission and g_currentMission.controlledVehicle
    if NaviHelper.navAidOn and controlled and NaviHelper.drawVehicle and NaviHelper.drawVehicle ~= controlled then
        NaviHelper.drawVehicle = controlled
        NaviHelper.lastEffectiveTarget = nil
    end
    if not NaviHelper.navAidOn or not NaviHelper.drawVehicle then return end
    self:drawForVehicle(NaviHelper.drawVehicle)
end

addModEventListener(NaviHelper)
