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
NaviHelper.routeUpdateInterval = 400   -- ms: route check cadence (fast off-route reaction, car-navi feel)
NaviHelper.offRouteThreshold = 25      -- m: vehicle farther than this from the route line -> reroute
NaviHelper.offRouteConfirm = 2         -- consecutive off-route checks before rerouting (~0.8s at 400ms; avoids spurious)
NaviHelper._offRouteCount = 0
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
-- Route-line look. With our lineShader: diffuse *= rgb (lit by the world, occluded by objects)
-- and emissive = rgb*a. Keep it a thin, calm painted stripe — not a glowing carpet:
--  * thickness ~0.4 = a narrow stripe that sits in the track (1.0+ looks like a 2 m ribbon)
--  * alpha low so it reads at dusk but never blooms to white where segments overlap
NaviHelper.routeLineColorR = 0.10
NaviHelper.routeLineColorG = 0.42
NaviHelper.routeLineColorB = 0.20
NaviHelper.routeLineColorA = 0.25  -- emissive strength (rgb*a); low = calm, no white bloom
NaviHelper.routeLineThickness = 0.40  -- width scale; lower = thinner stripe
NaviHelper.routeLineMaxSegments = 50  -- segments to draw (was 20 for perf test; 50 for better visibility)
-- Set false to disable route line on ground (use if ADDrawingManager causes 4 FPS / accumulation).
NaviHelper.drawRouteOnGround = true
NaviHelper.drawRouteOnMinimap = true   -- breadcrumb the route on the small HUD minimap (bottom-left)
-- Route line I3D: when available we use AutoDrive's drawing/line.i3d (our scene, so it is not cleared).
NaviHelper.AUTODRIVE_MOD_NAME = "FS25_AutoDrive"
NaviHelper.routeLineRootNode = nil
NaviHelper.routeLineSegmentNodes = nil   -- table of cloned line nodes (max routeLineMaxSegments)
NaviHelper.routeLineSharedI3D = nil     -- keep reference so shared I3D is not released
NaviHelper.routeLineUseI3D = false      -- true when our own line.i3d was loaded successfully

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
-- Defined here (before first use) so onClearTarget/onRouteToADDest/ingameMapMouseEvent can call it.
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

    -- Load our own line.i3d for the route line (our scene node under terrainRootNode).
    NaviHelper:tryLoadRouteLineI3D()

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

-- Load our OWN drawing/line.i3d (depth-tested, colourable lineShader) and create a segment pool
-- for the route line (our scene node under terrainRootNode, so nothing else clears it).
function NaviHelper:tryLoadRouteLineI3D()
    if not g_currentMission or not g_currentMission.terrainRootNode then return end
    if NaviHelper.routeLineRootNode then return end -- already loaded

    local dir = NaviHelper.modDirectory
    if not dir or dir == "" then
        log("mod directory unknown; route line will use drawDebugLine.")
        return
    end

    local path = Utils.getFilename("drawing/line.i3d", dir)
    if not path or path == "" then return end

    local node, sharedI3D = nil, nil
    local ok, err = pcall(function()
        node, sharedI3D = loadSharedI3DFile(path)
    end)
    if not ok or not node then
        log("route line.i3d load failed (ok=%s node=%s err=%s path=%s)",
            tostring(ok), tostring(node ~= nil), tostring(err), tostring(path))
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

    -- Segment template: the FIRST CHILD of the i3d root is the line mesh. Cloning the root group
    -- (with default args) yields nothing — mirror HoldToSteer's SegmentPool: getChildAt(node, 0)
    -- and clone(template, true, false, false).
    local template = node
    pcall(function() local c = getChildAt(node, 0); if c and c ~= 0 then template = c end end)

    local numSegments = math.max(1, NaviHelper.routeLineMaxSegments or 20)
    local segments = {}
    for i = 1, numSegments do
        local cloneNode
        pcall(function() cloneNode = clone(template, true, false, false) end)
        if cloneNode and cloneNode ~= 0 then
            link(root, cloneNode)
            segments[i] = cloneNode
        end
    end

    NaviHelper.routeLineSegmentNodes = segments
    NaviHelper.routeLineUseI3D = (#segments > 0)
    if NaviHelper.routeLineUseI3D then
        log("Using own line.i3d for route line (%d segments).", #segments)
    else
        log("route line.i3d loaded but produced 0 segments (template=%s)", tostring(template))
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
    -- The HUD is immediate-mode (vanishes when draw stops), but the ground route line uses
    -- persistent I3D segment nodes whose visibility is only reset inside drawRouteLine. After a
    -- clear, drawForVehicle no longer runs, so hide the segments here or they linger on the ground.
    self:hideRouteLine()
    log("Route cleared")
end

-- No map-selection mode anymore: points are set with Ctrl+click directly in the
-- big map. The bound key just shows a hint.
function NaviHelper:onMapSelectionMode()
    local msg = (g_i18n and g_i18n.getText and g_i18n:getText("NAVIHELPER_MSG_MAP_HINT"))
        or "NaviHelper: In der Karte Strg+Klick = Punkt setzen, Umschalt+Klick = letzten löschen."
    showIngameNotification(msg)
end

-- Action (Alt+T / F12): TOGGLE navigation to the destination currently selected in AutoDrive.
-- Lets you use AD's named-marker picker (Hof 49, F28, sell points, ...) instead of hunting on the
-- map — but only when YOU press the key, so a stale AD destination never shows up on its own.
-- Pressing again while a route is active switches navigation OFF (e.g. you cut into the field early
-- and don't want the leftover arrow + distance hanging around).
function NaviHelper:onRouteToADDest(vehicle)
    local v = vehicle or NaviHelper.drawVehicle or NaviHelper.lastActiveVehicle
        or (g_currentMission and g_currentMission.controlledVehicle)
    if v == nil then return end

    -- Toggle off: this vehicle already has an active route -> clear it and stop drawing.
    local existing = self:routeSlot(v, false)
    if NaviHelper.navAidOn and existing and existing.route and #existing.route > 0 then
        self:onClearTarget(v)
        NaviHelper.navAidOn = false
        log("nav toggled OFF (Alt+T)")
        return
    end

    if NaviHelperAD == nil then return end

    local x, z, name
    if NaviHelperAD.getSelectedDestinationFromVehicle then
        x, z, name = NaviHelperAD.getSelectedDestinationFromVehicle(v)
    end
    if (not x or not z) and NaviHelperAD.getCurrentDestinationFromVehicle then
        x, z, name = NaviHelperAD.getCurrentDestinationFromVehicle(v)
    end
    if not x or not z then
        if showIngameNotification then
            showIngameNotification(tr("NAVIHELPER_MSG_NO_AD_DEST", "Kein AutoDrive-Ziel ausgewaehlt"))
        end
        log("route to AD dest: no destination selected")
        return
    end

    local slot = self:routeSlot(v, true)
    if slot then
        slot.route = { { x = x, z = z } }
        slot.pathNodes = nil
        slot.destName = name
        slot.currentPathIndex = 1
    end
    NaviHelper.navAidOn = true
    NaviHelper.drawVehicle = v
    self:invalidateRouteCaches()
    log("route to AD dest '%s' at %.1f,%.1f", tostring(name), x, z)
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

    -- Target the vehicle the player is CURRENTLY in (not whichever was used last). Prefer the
    -- live controlledVehicle, then the tracked active vehicle; drawVehicle is only a last resort.
    local v = (g_currentMission and g_currentMission.controlledVehicle)
        or NaviHelper.lastActiveVehicle or NaviHelper.drawVehicle
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

-- Screen-space rect the menu-map dots must stay inside. The route overlay is NOT auto-clipped by
-- the FS25 menu map, so without this the dots paint over the left filter panel / side HUD. Prefer
-- the map element's reported bounds; when it reports a full-screen backing (xMin ~0), guard the
-- left edge so dots don't bleed onto the panel. (Approach borrowed from WayPointGPS.)
local function menuMapClipRect()
    local xMin, yMin, xMax, yMax
    local function absorb(element)
        if element == nil or element.layout == nil then return end
        local layout = element.layout
        if layout.absPosition == nil or layout.absSize == nil then return end
        local ax, ay = layout.absPosition[1], layout.absPosition[2]
        local sx, sy = layout.absSize[1], layout.absSize[2]
        if ax == nil or sx == nil or sx <= 0.05 or sy <= 0.05 then return end
        local bx, by = ax + sx, ay + sy
        if xMin == nil then
            xMin, yMin, xMax, yMax = ax, ay, bx, by
        else
            xMin = math.max(xMin, ax); yMin = math.max(yMin, ay)
            xMax = math.min(xMax, bx); yMax = math.min(yMax, by)
        end
    end
    absorb(menuMapElement())
    if g_inGameMenu ~= nil then
        absorb(g_inGameMenu.pageMapOverview)
        absorb(g_inGameMenu.pageMap)
    end
    if xMin == nil or xMax <= xMin or yMax <= yMin then
        xMin, yMin, xMax, yMax = 0.30, 0.055, 0.995, 0.955
    end
    if xMin < 0.20 then xMin = 0.30 end   -- full-screen backing reported -> guard the left panel
    if yMin < 0.03 then yMin = 0.055 end
    if xMax > 0.995 then xMax = 0.995 end
    if yMax > 0.965 then yMax = 0.965 end
    return xMin, yMin, xMax, yMax
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
    if not ok or sx == nil then return nil, nil end
    -- Clip to the visible map area so dots don't draw over the panel / HUD.
    local x0, y0, x1, y1 = menuMapClipRect()
    if sx < x0 or sx > x1 or sy < y0 or sy > y1 then return nil, nil end
    return sx, sy
end

-- World -> screen position on the small HUD minimap (bottom-left). Same projection as the menu
-- map, but on g_currentMission.hud.ingameMap. (Pattern borrowed from WayPointGPS.)
local function worldToMinimapPos(wx, wz)
    local hud = g_currentMission and g_currentMission.hud
    local ingameMap = hud and (hud.ingameMap or (type(hud.getIngameMap) == "function" and hud:getIngameMap()))
    if ingameMap == nil or ingameMap.layout == nil then return nil, nil end
    if ingameMap.worldCenterOffsetX == nil or ingameMap.worldSizeX == nil
        or ingameMap.worldCenterOffsetZ == nil or ingameMap.worldSizeZ == nil then return nil, nil end
    local mapX = (wx + ingameMap.worldCenterOffsetX) / ingameMap.worldSizeX * 0.5 + 0.25
    local mapZ = (wz + ingameMap.worldCenterOffsetZ) / ingameMap.worldSizeZ * 0.5 + 0.25
    if mapX < 0.25 or mapX > 0.75 or mapZ < 0.25 or mapZ > 0.75 then return nil, nil end
    local ok, sx, sy = pcall(ingameMap.layout.getMapObjectPosition, ingameMap.layout, mapX, mapZ, 0, 0, 0, true)
    if not ok or sx == nil then return nil, nil end
    return sx, sy
end

-- Draw a dotted breadcrumb along a whole screen-space polyline. Arc-length stepping
-- drops a dot every `spacing` regardless of node density, so it works both for a dense
-- AD road path (many close nodes) and a sparse straight fallback (few far points).
-- dotW/spacingIn let the small minimap use finer dots than the full ESC map.
local function drawPolylineBreadcrumb(overlayId, pts, aspect, dotW, spacingIn)
    if pts == nil or #pts == 0 then return end
    local spacing = spacingIn or 0.009
    local w = dotW or 0.0045
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

-- Appended to InGameMenu.draw: draw the route points as dots on the open map.
-- Destination (last point) green, intermediate waypoints orange. pcall-wrapped so
-- a draw error can never take down the whole in-game menu.
function NaviHelper.drawMenuMap()
    local ok, err = pcall(NaviHelper._drawMenuMapInner)
    if not ok then logError("drawMenuMap: %s", tostring(err)) end
end

function NaviHelper._drawMenuMapInner()
    if g_inGameMenu == nil or not g_inGameMenu.isOpen then return end
    if not isMenuMapPageActive() then return end  -- only on the map page, not calendar/prices/etc.

    -- Overlay (lazy create) for the route dots.
    if NaviHelper.dotOverlayId == nil and createImageOverlay ~= nil and NaviHelper.modDirectory then
        NaviHelper.dotOverlayId = createImageOverlay(NaviHelper.modDirectory .. "textures/dot.png")
    end
    if NaviHelper.dotOverlayId == nil then return end

    local aspect = g_screenAspectRatio or (16 / 9)

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
        NaviHelper:onRouteToADDest()
        return
    end

    -- F-key fallbacks (work when Option+letter is consumed by Mac as special char)
    local f9, f10, f11, f12 = Input.KEY_f9, Input.KEY_f10, Input.KEY_f11, Input.KEY_f12
    if f9 and sym == f9 then NaviHelper:onMapSelectionMode(); return end
    if f10 and sym == f10 then NaviHelper:onToggleUI(); return end
    if f11 and sym == f11 then NaviHelper:onClearTarget(); return end
    if f12 and sym == f12 then NaviHelper:onRouteToADDest(); return end
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

-- Window length (m) each side used to measure the heading change at a path node, and the minimum
-- heading change that counts as a maneuver. Shared by the route-turn precompute below.
local TURN_WINDOW = 11.0
local TURN_ANGLE_MIN = math.rad(28)

-- Unit direction of the path ~TURN_WINDOW metres AHEAD of node i. On dense AD paths (nodes every
-- few metres) a 90 deg junction is spread over many nodes with tiny per-node angles; measuring over
-- a window catches it while ignoring gentle long road bends (they change heading too gradually).
local function pathDirAhead(path, i)
    local ax, az = path[i].x, path[i].z
    local acc = 0
    for j = i, #path - 1 do
        local p2 = path[j + 1]
        acc = acc + MathUtil.vector2Length(p2.x - path[j].x, p2.z - path[j].z)
        if acc >= TURN_WINDOW then
            local dx, dz = p2.x - ax, p2.z - az
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 0.5 then return dx / l, dz / l end
            return nil
        end
    end
    return nil
end
-- Unit direction of the path ~TURN_WINDOW metres BEHIND node i (still pointing forward).
local function pathDirBack(path, i)
    local ax, az = path[i].x, path[i].z
    local acc = 0
    for j = i, 2, -1 do
        local p1 = path[j - 1]
        acc = acc + MathUtil.vector2Length(path[j].x - p1.x, path[j].z - p1.z)
        if acc >= TURN_WINDOW then
            local dx, dz = ax - p1.x, az - p1.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 0.5 then return dx / l, dz / l end
            return nil
        end
    end
    return nil
end

-- Precompute the maneuver plan for a route ONCE, at build time (not per frame): a deduped, ordered
-- list of significant turns plus the cumulative arc length per node. Computing it per frame made the
-- arrow flicker between candidate turns at threshold boundaries; with a fixed plan, each frame only
-- has to pick the next turn ahead, which is stable.
-- Returns: turns = { {idx=<peak node>, dir="links"/"rechts", angle=<rad>}, ... }, cumArc = {per node}.
local function computeRouteTurns(path)
    local turns, cumArc = {}, {}
    if not path or #path < 3 then return turns, cumArc end
    cumArc[1] = 0
    for i = 2, #path do
        cumArc[i] = cumArc[i - 1]
            + MathUtil.vector2Length(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z)
    end
    local i = 2
    while i <= #path - 1 do
        local bx, bz = pathDirBack(path, i)
        local fx, fz = pathDirAhead(path, i)
        if bx and fx then
            local angle = math.acos(math.max(-1, math.min(1, bx * fx + bz * fz)))
            if angle > TURN_ANGLE_MIN then
                -- Walk through the maneuver region tracking the peak heading change, so a turn spread
                -- over many dense nodes is recorded once, at its sharpest point (slight vs sharp).
                local maxA, maxCross, peakIdx = angle, (bx * fz - bz * fx), i
                local k = i
                while k < #path - 1 do
                    k = k + 1
                    local kbx, kbz = pathDirBack(path, k)
                    local kfx, kfz = pathDirAhead(path, k)
                    if not (kbx and kfx) then break end
                    local ka = math.acos(math.max(-1, math.min(1, kbx * kfx + kbz * kfz)))
                    if ka < TURN_ANGLE_MIN * 0.6 then break end
                    if ka > maxA then maxA = ka; maxCross = kbx * kfz - kbz * kfx; peakIdx = k end
                end
                local dir = (maxCross > 0) and tr("NAVIHELPER_DIR_RIGHT", "rechts")
                    or tr("NAVIHELPER_DIR_LEFT", "links")
                turns[#turns + 1] = { idx = peakIdx, dir = dir, angle = maxA }
                i = k + 1  -- skip past this maneuver region so it is not counted twice
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return turns, cumArc
end

-- Find the next maneuver AHEAD of the vehicle from the precomputed route plan (slot.turns/cumArc).
-- Returns: distance (m), direction, angle (rad) — or nil if no turn within the warning range.
-- Progress is tracked monotonically (slot.turnProgressIdx mostly advances) so that where the route
-- passes near itself the closest-node lookup cannot jump backward and flip the reported turn.
function NaviHelper:findNextTurn(path, pathIdx, vehicle)
    local slot = self:routeSlot(vehicle, false)
    if not slot or not slot.turns or not slot.cumArc then return nil, nil end
    if not path or #path < 3 then return nil, nil end
    local vx, _, vz = self:getVehiclePosition(vehicle)
    if not vx or not vz then return nil, nil end

    -- Advance progress to the path node closest to the vehicle, searching a forward window from the
    -- last progress index (small backward allowance covers a fresh route or brief reversing).
    local n = #path
    local pi = slot.turnProgressIdx or 1
    if pi < 1 then pi = 1 elseif pi > n then pi = n end
    local lo = math.max(1, pi - 4)
    local hi = math.min(n, pi + 80)
    local bestI, bestD2 = pi, math.huge
    for i = lo, hi do
        local node = path[i]
        if node and node.x and node.z then
            local dx, dz = node.x - vx, node.z - vz
            local d2 = dx * dx + dz * dz
            if d2 < bestD2 then bestD2 = d2; bestI = i end
        end
    end
    slot.turnProgressIdx = bestI

    -- Distance from the closest node to each turn node along the route. Within ~one node spacing of
    -- the true distance-to-turn, and it counts DOWN monotonically as the vehicle advances.
    local vehicleArc = slot.cumArc[bestI] or 0
    local cap = NaviHelper.turnWarnRange or 300
    for _, t in ipairs(slot.turns) do
        if t.idx > bestI then
            local d = (slot.cumArc[t.idx] or 0) - vehicleArc
            if d <= 0 then
                return 0, t.dir, t.angle
            elseif d <= cap then
                return d, t.dir, t.angle
            else
                return nil, nil  -- next turn is still farther than the warning range -> straight
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

    -- Only a manual route is shown: set via map click, or via the "route to AutoDrive
    -- destination" key (which stores the marker name in slot.destName). We deliberately do NOT
    -- auto-display whatever destination AutoDrive happens to have selected (that was noisy).
    local mkey = vehicleKey(vehicle)
    local slot = mkey and NaviHelper.vehicleTargets and NaviHelper.vehicleTargets[mkey]
    if slot and slot.route and #slot.route > 0 then
        local dest = slot.route[#slot.route]
        return dest.x, dest.z, slot.pathNodes, slot.currentPathIndex or 1, slot.destName
    end
    return nil, nil, nil, nil, nil
end

-- Build a polyline through vehicle -> route waypoints -> destination.
-- Hybrid: each segment is routed via AutoDrive roads when available, else a
-- straight line. Segment ends are de-duplicated so the line is continuous.
function NaviHelper:buildRoutePath(route, vx, vz, hdx, hdz)
    if not route or #route == 0 then return nil end

    -- Drive sequence: current vehicle position, then every route point in order.
    local seq = { { x = vx, z = vz } }
    for i = 1, #route do seq[#seq + 1] = { x = route[i].x, z = route[i].z } end

    local nodes = {}
    local adRouted, straightSegs = 0, 0
    local function push(p)
        local last = nodes[#nodes]
        if last and math.abs(last.x - p.x) < 0.5 and math.abs(last.z - p.z) < 0.5 then return end
        nodes[#nodes + 1] = p
    end

    for i = 1, #seq - 1 do
        local a, b = seq[i], seq[i + 1]
        local seg
        -- Route over the AutoDrive network (the map's real, human-built / AD-generated road graph).
        -- The vehicle heading on the FIRST segment makes AD start ahead of the vehicle (no U-turn).
        if NaviHelperAD and NaviHelperAD.getPathFromToWorld then
            local shx, shz
            if i == 1 then shx, shz = hdx, hdz end
            local ok, path = pcall(NaviHelperAD.getPathFromToWorld, a.x, a.z, b.x, b.z, shx, shz)
            if ok and path and #path > 0 then seg = path; adRouted = adRouted + 1 end
        end
        if seg then
            for _, wp in ipairs(seg) do push({ x = wp.x, y = wp.y or 0, z = wp.z }) end
        else
            -- No AD path (no network, or AD found none): honest straight line for this segment.
            push({ x = a.x, y = 0, z = a.z })
            push({ x = b.x, y = 0, z = b.z })
            straightSegs = straightSegs + 1
        end
    end

    log("Route built: %d nodes from %d segment(s) — %d AD, %d straight",
        #nodes, #seq - 1, adRouted, straightSegs)
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

    -- Dynamic rerouting: if the vehicle has left the planned route (missed a turn, drove against
    -- AD direction), flag a rebuild — like a real sat-nav. Confirmed over a couple of checks so a
    -- brief wide turn or overtake doesn't trigger a needless reroute. Detection + rebuild happen in
    -- the SAME tick (below), so reaction is ~confirm * interval, not one interval longer.
    if not NaviHelper.pathDirty and slot.pathNodes and #slot.pathNodes >= 2 then
        local d = distanceFromPointToPath(vx, vz, slot.pathNodes)
        if d ~= nil and d > NaviHelper.offRouteThreshold then
            NaviHelper._offRouteCount = NaviHelper._offRouteCount + 1
            if NaviHelper._offRouteCount >= NaviHelper.offRouteConfirm then
                NaviHelper._offRouteCount = 0
                NaviHelper.pathDirty = true
                NaviHelper.lastEffectiveTarget = nil
                NaviHelper.lastDistanceUpdateTime = 0
                log("off-route %.0fm -> Neuberechnung", d)
            end
        else
            NaviHelper._offRouteCount = 0
        end
    end

    -- Rebuild now if flagged (manual click OR off-route) — same tick, no extra interval of delay.
    if NaviHelper.pathDirty then
        local hdx, hdz
        if vehicle.rootNode ~= nil and localDirectionToWorld ~= nil then
            local ok, dx, _, dz = pcall(localDirectionToWorld, vehicle.rootNode, 0, 0, 1)
            if ok and dx ~= nil then hdx, hdz = dx, dz end
        end
        slot.pathNodes = self:buildRoutePath(slot.route, vx, vz, hdx, hdz)
        slot.currentPathIndex = 1
        -- Precompute the maneuver plan once for this route; the arrow/turn logic reads it per frame.
        slot.turns, slot.cumArc = computeRouteTurns(slot.pathNodes)
        slot.turnProgressIdx = 1
        NaviHelper.pathDirty = false
        slot.lastVehicleX = vx
        slot.lastVehicleZ = vz
    end
end

function NaviHelper:update(dt)
    -- Track the active vehicle. controlledVehicle is non-nil in this logic context (unlike the
    -- draw context), so this is the reliable source for "which vehicle am I in right now".
    local cv = g_currentMission and g_currentMission.controlledVehicle
    if cv ~= nil then NaviHelper.lastActiveVehicle = cv end
    -- Inject our route-line settings into the General Settings page (idempotent; retries until
    -- the in-game menu is built).
    if NaviHelperSettings and not NaviHelperSettings._menuInjected and NaviHelperSettings.injectMenu then
        pcall(function() NaviHelperSettings:injectMenu() end)
    end
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
    local distNext, distTotal, turnDist, turnDir, turnAngle
    local cacheValid = (currentTime - NaviHelper.lastDistanceUpdateTime) < (NaviHelper.distanceCacheTime or 500)
    if cacheValid and NaviHelper.cachedDistTotal then
        distNext = NaviHelper.cachedDistNext
        distTotal = NaviHelper.cachedDistTotal
        turnDist = NaviHelper.cachedTurnDist
        turnDir = NaviHelper.cachedTurnDir
        turnAngle = NaviHelper.cachedTurnAngle
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

        turnDist, turnDir, turnAngle = self:findNextTurn(effPath, effPathIdx, vehicle)

        NaviHelper.lastDistanceUpdateTime = currentTime
        NaviHelper.cachedDistNext = distNext
        NaviHelper.cachedDistTotal = distTotal
        NaviHelper.cachedTurnDist = turnDist
        NaviHelper.cachedTurnDir = turnDir
        NaviHelper.cachedTurnAngle = turnAngle
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
        NaviHelper.cachedTurnAngle = nil
        NaviHelper.cachedPointX = effX
        NaviHelper.cachedPointZ = effZ
    end

    return {
        effPath = effPath, effPathIdx = effPathIdx, destName = destName,
        vx = vx, vz = vz, distTotal = distTotal,
        turnDist = turnDist, turnDir = turnDir, turnAngle = turnAngle,
    }
end

-- Pick the path index to start drawing the route line from: the node CLOSEST to the vehicle
-- (= how far along the route we are), kept one node back for visual continuity. This trims the
-- line as the vehicle drives so it follows along, instead of trailing from the original start.
function NaviHelper:routeLineStartIndex(pathToDraw, effPathIdx, vx, vz, vehicle)
    if not (vx and vz) or not pathToDraw or #pathToDraw == 0 then
        return math.max(1, effPathIdx or 1)
    end
    local bestI, bestDistSq = 1, 1e10
    for i = 1, #pathToDraw do
        local node = pathToDraw[i]
        if node and node.x and node.z then
            local dx, dz = node.x - vx, node.z - vz
            local d2 = dx * dx + dz * dz
            if d2 < bestDistSq then bestDistSq = d2; bestI = i end
        end
    end
    return math.max(1, bestI - 1)
end

-- Hide the persistent I3D route-line breadcrumb segments. Pooled scene nodes keep their last
-- visibility state, so once the route is cleared (Alt+T off, destination reached) and drawRouteLine
-- stops being called, the ground dots would linger until something hides them. This is that thing.
function NaviHelper:hideRouteLine()
    local segs = NaviHelper.routeLineSegmentNodes
    if not segs or not setVisibility then return end
    pcall(function()
        for _, seg in ipairs(segs) do
            setVisibility(seg, false)
        end
    end)
end

-- Draw the route line on the ground (AutoDrive's I3D segments, or a drawDebugLine fallback).
function NaviHelper:drawRouteLine(vehicle, pathToDraw, effPathIdx, vx, vz)
    if not NaviHelper.drawRouteOnGround then return end

    -- Lazy-load the I3D line here: at loadMap time terrainRootNode may not exist yet, so the
    -- one-shot load there silently fails and the route falls back to the see-through drawDebugLine.
    -- By draw time the world is ready. Cap attempts so a genuine load failure doesn't retry forever.
    if NaviHelper.routeLineRootNode == nil and (NaviHelper._routeLineAttempts or 0) < 30 then
        NaviHelper._routeLineAttempts = (NaviHelper._routeLineAttempts or 0) + 1
        self:tryLoadRouteLineI3D()
    end

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

    if haveSegments and NaviHelper.routeLineRootNode and setWorldTranslation and setScale then
        -- Breadcrumb trail: a small flat dot every `spacing` metres along the path (more immersive
        -- than a continuous ribbon). Reuses the segment pool; the width value sets the dot size.
        local segs = NaviHelper.routeLineSegmentNodes
        local pool = #segs
        local spacing = NaviHelper.routeDotSpacing or 3.5
        local dotSize = NaviHelper.routeLineThickness or 0.4
        local cr, cg, cb = NaviHelper.routeLineColorR, NaviHelper.routeLineColorG, NaviHelper.routeLineColorB
        local ca = NaviHelper.routeLineColorA or 0.6
        pcall(function()
            local used = 0
            local function placeDot(x, z, yIn)
                local seg = segs[used + 1]
                if seg == nil then return false end
                local y = yIn or 0
                if y == 0 and g_terrainNode and getTerrainHeightAtWorldPos then
                    y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) or 0
                end
                setWorldTranslation(seg, x, y + 0.15, z)
                if setWorldRotation then setWorldRotation(seg, 0, 0, 0) end
                setScale(seg, dotSize, 1, dotSize)
                if setShaderParameter then setShaderParameter(seg, "lineColor", cr, cg, cb, ca, false) end
                if setVisibility then setVisibility(seg, true) end
                used = used + 1
                return used < pool
            end
            local cont = true
            local p0 = pathToDraw[startIdx]
            if p0 and p0.x then cont = placeDot(p0.x, p0.z, p0.y) end
            local acc = 0
            for i = startIdx, #pathToDraw - 1 do
                if not cont then break end
                local a, b_ = pathToDraw[i], pathToDraw[i + 1]
                if a and b_ and a.x and b_.x then
                    local dx, dz = b_.x - a.x, b_.z - a.z
                    local seglen = math.sqrt(dx * dx + dz * dz)
                    if seglen > 0 then
                        local pos = spacing - acc
                        while pos < seglen and cont do
                            local t = pos / seglen
                            cont = placeDot(a.x + dx * t, a.z + dz * t, nil)
                            pos = pos + spacing
                        end
                        acc = (acc + seglen) % spacing
                    end
                end
            end
            for k = used + 1, pool do
                if setVisibility then setVisibility(segs[k], false) end
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
-- Map a turn (direction text + magnitude in radians) to a maneuver-arrow asset name.
local function turnArrowName(turnDir, angle)
    if angle == nil then return "straight" end
    local deg = math.deg(angle)
    local side = (turnDir == tr("NAVIHELPER_DIR_RIGHT", "rechts")) and "right" or "left"
    if deg < 22 then return "straight"
    elseif deg < 40 then return "slight_" .. side
    elseif deg < 78 then return side
    elseif deg < 150 then return "sharp_" .. side
    else return "uturn" end
end

-- Lazy-load (and cache) a turn-arrow image overlay.
function NaviHelper:arrowOverlay(name)
    NaviHelper.arrowOverlays = NaviHelper.arrowOverlays or {}
    local cached = NaviHelper.arrowOverlays[name]
    if cached ~= nil then return cached or nil end
    local id = nil
    if createImageOverlay ~= nil and NaviHelper.modDirectory then
        id = createImageOverlay(NaviHelper.modDirectory .. "textures/arrows/arrow_" .. name .. ".png")
    end
    NaviHelper.arrowOverlays[name] = id or false
    return id
end

-- Screen-space bounding box (x1,y1,x2,y2) of the whole HUD widget around its centre (cx, cy).
-- Used both for the drag hit-test and for the hover/drag highlight, so they always match what is
-- actually drawn. Spans from just below the "Total" line up over the maneuver arrow.
local function hudWidgetBox(cx, cy, aspect)
    local halfW = 0.06
    local top = cy + 0.05 + 0.045 * aspect + 0.02   -- arrow top (see drawHud) + margin
    local bottom = cy - 0.02
    return cx - halfW, bottom, cx + halfW, top
end

-- HUD: a glanceable maneuver arrow (straight / slight / turn / sharp / U-turn), the distance
-- number under it, and a proximity bar that depletes as you approach — plus destination + total.
function NaviHelper:drawHud(distTotal, turnDist, turnDir, destName, effPath, turnAngle)
    local aspect = g_screenAspectRatio or (16 / 9)
    local cx = NaviHelper.hudCenterX or 0.5
    local cy = NaviHelper.hudCenterY or 0.12
    local hasTurn = turnDist ~= nil and turnDist < 5000

    -- Reposition affordance: a faint panel behind the widget while the cursor hovers it (mouse free
    -- via right-click) or while dragging, so the grab area is visible without cluttering normal play.
    if (NaviHelper.hudHover or NaviHelper.hudDragging) and renderOverlay and setOverlayColor then
        if NaviHelper.dotOverlayId == nil and createImageOverlay ~= nil and NaviHelper.modDirectory then
            NaviHelper.dotOverlayId = createImageOverlay(NaviHelper.modDirectory .. "textures/dot.png")
        end
        if NaviHelper.dotOverlayId then
            local x1, y1, x2, y2 = hudWidgetBox(cx, cy, aspect)
            pcall(function()
                setOverlayColor(NaviHelper.dotOverlayId, 1, 1, 1, NaviHelper.hudDragging and 0.18 or 0.10)
                renderOverlay(NaviHelper.dotOverlayId, x1, y1, x2 - x1, y2 - y1)
                setOverlayColor(NaviHelper.dotOverlayId, 1, 1, 1, 1)
            end)
        end
    end

    -- Maneuver arrow (straight when no turn is imminent).
    local arrowId = self:arrowOverlay(hasTurn and turnArrowName(turnDir, turnAngle) or "straight")
    local aw, ah = 0.045, 0.045 * aspect
    local ay = cy + 0.062
    if arrowId and setOverlayColor and renderOverlay then
        pcall(function()
            setOverlayColor(arrowId, 1, 1, 1, 1)
            renderOverlay(arrowId, cx - aw * 0.5, ay, aw, ah)
        end)
    end

    -- Proximity bar (only when a turn is near): full far out, depletes to nothing at the turn.
    if hasTurn and NaviHelper.dotOverlayId == nil and createImageOverlay ~= nil and NaviHelper.modDirectory then
        NaviHelper.dotOverlayId = createImageOverlay(NaviHelper.modDirectory .. "textures/dot.png")
    end
    if hasTurn and NaviHelper.dotOverlayId and setOverlayColor and renderOverlay then
        local frac = math.max(0, math.min(1, turnDist / 200))
        local fullW, barH = 0.06, 0.006
        -- Sit the bar in the gap between the arrow (above) and the distance number
        -- (below, top ~cy+0.048): ~0.004 clearance on each side so nothing touches.
        local bx, by = cx - fullW * 0.5, cy + 0.052
        pcall(function()
            setOverlayColor(NaviHelper.dotOverlayId, 1, 1, 1, 0.16)
            renderOverlay(NaviHelper.dotOverlayId, bx, by, fullW, barH)
            setOverlayColor(NaviHelper.dotOverlayId, 0.27, 0.77, 0.37, 0.95)
            renderOverlay(NaviHelper.dotOverlayId, bx, by, fullW * frac, barH)
            setOverlayColor(NaviHelper.dotOverlayId, 1, 1, 1, 1)
        end)
    end

    -- Text: distance number (just the number), destination, total.
    local renderFn = renderText or renderTextOverlay
    if not renderFn then return end
    local totalStr = (distTotal and distTotal < 1e6) and string.format("%.0f m", distTotal) or "-"
    pcall(function()
        if setTextAlignment then setTextAlignment(RenderText and RenderText.ALIGN_CENTER or 1) end
        if setTextColor then setTextColor(1, 1, 1, 1) end
        if hasTurn then
            renderFn(cx, cy + 0.026, 0.022, string.format("%.0f m", turnDist))
        end
        if destName and destName ~= "" then
            renderFn(cx, cy + 0.012, 0.015, destName)
        end
        renderFn(cx, cy, 0.015, tr("NAVIHELPER_HUD_TOTAL", "Total") .. ": " .. totalStr)
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
        self:hideRouteLine()
        return
    end

    self:drawRouteLine(vehicle, nav.effPath, nav.effPathIdx, nav.vx, nav.vz)
    self:drawHud(distTotal, nav.turnDist, nav.turnDir, nav.destName, nav.effPath, nav.turnAngle)
end

-- Breadcrumb the active route onto the small HUD minimap (bottom-left), every frame, so you get
-- the "big picture" at a glance like a real sat-nav. Mirrors the ESC-map drawing via worldToMinimapPos.
function NaviHelper:drawMinimapRoute()
    if not NaviHelper.drawRouteOnMinimap then return end
    if NaviHelper.dotOverlayId == nil and createImageOverlay ~= nil and NaviHelper.modDirectory then
        NaviHelper.dotOverlayId = createImageOverlay(NaviHelper.modDirectory .. "textures/dot.png")
    end
    if NaviHelper.dotOverlayId == nil then return end

    local v = NaviHelper.drawVehicle or NaviHelper.lastActiveVehicle
        or (g_currentMission and g_currentMission.controlledVehicle)
    if v == nil then return end
    local key = vehicleKey(v)
    local slot = key and NaviHelper.vehicleTargets and NaviHelper.vehicleTargets[key]
    if not slot or not slot.route or #slot.route == 0 then return end

    local worldLine = {}
    if slot.pathNodes ~= nil and #slot.pathNodes >= 2 then
        for i = 1, #slot.pathNodes do worldLine[#worldLine + 1] = { slot.pathNodes[i].x, slot.pathNodes[i].z } end
    else
        local vx, _, vz = self:getVehiclePosition(v)
        if vx and vz then worldLine[#worldLine + 1] = { vx, vz } end
        for i = 1, #slot.route do worldLine[#worldLine + 1] = { slot.route[i].x, slot.route[i].z } end
    end

    local screenLine = {}
    for i = 1, #worldLine do
        local sx, sy = worldToMinimapPos(worldLine[i][1], worldLine[i][2])
        if sx then screenLine[#screenLine + 1] = { sx, sy } end
    end
    -- finer dots/spacing than the ESC map, since the minimap is small
    drawPolylineBreadcrumb(NaviHelper.dotOverlayId, screenLine, g_screenAspectRatio or (16 / 9), 0.0026, 0.0055)
end

-- Drag the nav widget with the mouse. The engine calls this on every mouse event because NaviHelper
-- is an addModEventListener object. Active only when the cursor is free (the player has toggled the
-- camera off with right-click, exactly like AutoDrive's movable HUD) and the widget is on screen.
-- Left-press inside the widget box grabs it; moving drags it; release stores the new position.
function NaviHelper:mouseEvent(posX, posY, isDown, isUp, button)
    local cursorFree = g_inputBinding and g_inputBinding.getShowMouseCursor
        and g_inputBinding:getShowMouseCursor()
    -- No free cursor, or widget not currently shown -> never drag, and drop any in-progress drag.
    if not cursorFree or not NaviHelper.navAidOn or not NaviHelper.drawVehicle then
        NaviHelper.hudHover = false
        if NaviHelper.hudDragging then NaviHelper.hudDragging = false end
        return
    end

    local LEFT = (Input and Input.MOUSE_BUTTON_LEFT) or 1
    local aspect = g_screenAspectRatio or (16 / 9)
    local cx = NaviHelper.hudCenterX or 0.5
    local cy = NaviHelper.hudCenterY or 0.12
    local x1, y1, x2, y2 = hudWidgetBox(cx, cy, aspect)
    local inside = posX >= x1 and posX <= x2 and posY >= y1 and posY <= y2
    NaviHelper.hudHover = inside or NaviHelper.hudDragging

    if button == LEFT and isDown and inside and not NaviHelper.hudDragging then
        -- Grab: remember the offset from the cursor to the centre so the widget does not jump.
        NaviHelper.hudDragging = true
        NaviHelper.hudGrabDX = posX - cx
        NaviHelper.hudGrabDY = posY - cy
    elseif NaviHelper.hudDragging and (isUp and button == LEFT) then
        -- Drop: persist the new position so it survives reloads (same store as the other settings).
        NaviHelper.hudDragging = false
        if NaviHelperSettings then
            NaviHelperSettings.hudCenterX = NaviHelper.hudCenterX
            NaviHelperSettings.hudCenterY = NaviHelper.hudCenterY
            if NaviHelperSettings.saveToXML then pcall(function() NaviHelperSettings:saveToXML() end) end
        end
        log("HUD moved to %.3f, %.3f", NaviHelper.hudCenterX, NaviHelper.hudCenterY)
    elseif NaviHelper.hudDragging then
        -- Drag: follow the cursor, keeping the grab offset, clamped so it stays fully on screen.
        local nx = posX - (NaviHelper.hudGrabDX or 0)
        local ny = posY - (NaviHelper.hudGrabDY or 0)
        NaviHelper.hudCenterX = math.max(0.08, math.min(0.92, nx))
        NaviHelper.hudCenterY = math.max(0.04, math.min(0.80, ny))
    end
end

function NaviHelper:draw()
    -- Keep the drawn route bound to the active vehicle. controlledVehicle is often nil in the draw
    -- context (FS25 quirk), so fall back to the tracked active vehicle — each vehicle shows its own
    -- route, and switching vehicles switches the displayed route.
    local active = (g_currentMission and g_currentMission.controlledVehicle) or NaviHelper.lastActiveVehicle
    if NaviHelper.navAidOn and active and NaviHelper.drawVehicle ~= active then
        NaviHelper.drawVehicle = active
        NaviHelper.lastEffectiveTarget = nil
    end
    if not NaviHelper.navAidOn or not NaviHelper.drawVehicle then return end
    self:drawForVehicle(NaviHelper.drawVehicle)
    pcall(function() self:drawMinimapRoute() end)
end

addModEventListener(NaviHelper)
