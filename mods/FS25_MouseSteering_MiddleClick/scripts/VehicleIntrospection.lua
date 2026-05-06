--[[
  VehicleIntrospection.lua
  Defensive extraction of the three geometry values that PathGeometry needs:
    wheelbase (distance between front and rear axles, in meters)
    trackWidth (distance between left and right wheels on the front axle)
    maxSteerAngle (maximum wheel rotation, in radians)

  Every access is wrapped in pcall. If any individual source fails, a
  documented default is used. On first successful lookup per vehicle,
  the discovered values are logged once, so later diagnostics can tell
  whether the introspection actually found real data or fell back.

  Defaults approximate a mid-size utility tractor (e.g. John Deere 6R).
]]

VehicleIntrospection = {}

-- Per-vehicle cache so we don't repeat the log spam every frame.
VehicleIntrospection._cache = setmetatable({}, { __mode = "k" })  -- weak keys

-- Sensible defaults (mid-size tractor).
VehicleIntrospection.DEFAULTS = {
    wheelbase     = 2.5,
    trackWidth    = 1.8,
    maxSteerAngle = math.rad(40),  -- ~0.698 rad
}

-- Vehicle specs are metatable-backed: pairs(vehicle) does not list spec_* (see docs/learned.md).
-- Loader hydraulic mouse axes live on these specs; probe by explicit field name only.
local LOADER_AXIS_SPEC_NAMES = {
    "spec_attachableFrontloader",
    "spec_attachableFrontLoader",
    "spec_attachable",
    "spec_cylindered",
    "spec_shovel",
    "spec_baleGrab",
    "spec_fork",
    "spec_palletFork",
    "spec_grapple",
    "spec_grab",
    "spec_logGrab",
    "spec_movingTool",
    "spec_movingTools",
    "spec_pickup",
    "spec_pickUp",
    "spec_dynamicMountAttacher",
    "spec_implementDynamicMountAttacher",
    "spec_leveler",
    "spec_foldable",
    "spec_frontLoaderTool",
    "spec_toolHolder",
    "spec_wheelLoaderShovel",
    "spec_manureFork",
    "spec_woodCrusher",
}

VehicleIntrospection._loaderSpecKeysByTypeName = VehicleIntrospection._loaderSpecKeysByTypeName or {}

-- Bump when spec key resolution changes so stale cached arrays are not reused in-session.
local LOADER_SPEC_KEY_LIST_CACHE_VER = 4

---Giants maps specialization registration name -> vehicle field `spec_` + first char lower + rest.
---@param regName string
---@return string|nil
local function specLuaFieldFromRegistrationName(regName)
    if type(regName) ~= "string" or regName == "" then return nil end
    return "spec_" .. regName:sub(1, 1):lower() .. regName:sub(2)
end

---Merged spec_* field names for one vehicle instance (cached per typeName).
---@param obj table
---@return table  array of string keys
local function resolveSpecFieldNamesForVehicleType(obj)
    local tn = "?"
    pcall(function() tn = (obj and obj.typeName) and tostring(obj.typeName) or "?" end)
    local cache = VehicleIntrospection._loaderSpecKeysByTypeName
    local hit = cache[tn]
    if type(hit) == "table" and hit.v == LOADER_SPEC_KEY_LIST_CACHE_VER and type(hit.keys) == "table" then
        return hit.keys
    end
    -- Drop legacy cache shape (plain array from older builds).
    if type(hit) == "table" and hit[1] ~= nil and type(hit[1]) == "string" and hit.keys == nil then
        cache[tn] = nil
    end

    local seen = {}
    local out = {}
    local function addKey(nk)
        if type(nk) ~= "string" or nk:sub(1, 5) ~= "spec_" then return end
        if seen[nk] then return end
        seen[nk] = true
        table.insert(out, nk)
    end

    for _, nk in ipairs(LOADER_AXIS_SPEC_NAMES) do
        addKey(nk)
    end

    local nFromType = 0
    pcall(function()
        local tm = g_vehicleTypeManager
        if not tm then return end
        local td = tm.types and tm.types[tn] or nil
        if not td and type(tm.getVehicleTypeByName) == "function" then
            td = tm:getVehicleTypeByName(tn)
        end
        if not td or type(td.specializationsByName) ~= "table" then return end
        for regName in pairs(td.specializationsByName) do
            local nk = specLuaFieldFromRegistrationName(regName)
            if nk then
                addKey(nk)
                nFromType = nFromType + 1
            end
            if type(regName) == "string" then
                local rl = regName:lower()
                if rl:find("attachablefrontloader", 1, true) or (rl:find("attachable", 1, true) and rl:find("front", 1, true) and rl:find("loader", 1, true)) then
                    addKey("spec_attachableFrontLoader")
                    addKey("spec_attachableFrontloader")
                    addKey("spec_attachablefrontloader")
                end
                if rl:find("dynamicmount", 1, true) or rl:find("dynamic_mount", 1, true) then
                    addKey("spec_implementDynamicMountAttacher")
                    addKey("spec_dynamicMountAttacher")
                end
            end
        end
    end)

    cache[tn] = { v = LOADER_SPEC_KEY_LIST_CACHE_VER, keys = out }

    return out
end

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[MouseSteering][Introspect] " .. fmt, ...)
    end
end

---Extract wheelbase from a wheels array by spanning min/max Z position.
---@param wheels table|nil array of wheel objects, each expected to have .positionZ or similar
---@return number|nil
local function inferWheelbaseFromWheels(wheels)
    if type(wheels) ~= "table" or #wheels < 2 then return nil end
    local minZ, maxZ
    for _, w in ipairs(wheels) do
        local z = nil
        -- Try a few known field shapes; different FS versions, different specs.
        if type(w) == "table" then
            z = w.positionZ or (w.netInfo and w.netInfo.positionZ) or nil
            if z == nil and type(w.wheelConfig) == "table" then
                z = w.wheelConfig.positionZ
            end
        end
        if type(z) == "number" then
            if minZ == nil or z < minZ then minZ = z end
            if maxZ == nil or z > maxZ then maxZ = z end
        end
    end
    if minZ and maxZ and maxZ > minZ then
        return maxZ - minZ
    end
    return nil
end

---Extract front-axle track width by finding the two front wheels and spanning their X positions.
---@param wheels table|nil
---@return number|nil
local function inferTrackWidthFromWheels(wheels)
    if type(wheels) ~= "table" or #wheels < 2 then return nil end
    -- Collect wheels paired by Z position. Front wheels are those with the largest positiveZ.
    local wheelsWithZX = {}
    for _, w in ipairs(wheels) do
        if type(w) == "table" then
            local x = w.positionX or (w.wheelConfig and w.wheelConfig.positionX)
            local z = w.positionZ or (w.wheelConfig and w.wheelConfig.positionZ)
            if type(x) == "number" and type(z) == "number" then
                table.insert(wheelsWithZX, { x = x, z = z })
            end
        end
    end
    if #wheelsWithZX < 2 then return nil end
    -- Find the max Z (front axle). Allow some tolerance for wheels not exactly at the same Z.
    local maxZ = -math.huge
    for _, w in ipairs(wheelsWithZX) do
        if w.z > maxZ then maxZ = w.z end
    end
    local tolerance = 0.3
    local minX, maxX
    for _, w in ipairs(wheelsWithZX) do
        if math.abs(w.z - maxZ) <= tolerance then
            if minX == nil or w.x < minX then minX = w.x end
            if maxX == nil or w.x > maxX then maxX = w.x end
        end
    end
    if minX and maxX and maxX > minX then
        return maxX - minX
    end
    return nil
end

---Find the largest maxRotation among steering wheels.
---@param wheels table|nil
---@return number|nil radians
local function inferMaxSteerFromWheels(wheels)
    if type(wheels) ~= "table" then return nil end
    local maxRot = 0
    for _, w in ipairs(wheels) do
        if type(w) == "table" then
            -- Candidates, in order of likelihood.
            local r = w.rotMax or w.maxRot or w.steeringAngle or nil
            if type(r) == "number" and math.abs(r) > maxRot then
                maxRot = math.abs(r)
            end
        end
    end
    if maxRot > 0 then return maxRot end
    return nil
end

---Retrieve or compute the three geometry numbers for a vehicle.
---Cached per vehicle (weak keys). Returns defaults on any failure.
---@param vehicle table
---@return table { wheelbase=..., trackWidth=..., maxSteerAngle=... }
function VehicleIntrospection:getGeometry(vehicle)
    if not vehicle then return VehicleIntrospection.DEFAULTS end
    local cached = VehicleIntrospection._cache[vehicle]
    if cached then return cached end

    local geo = {
        wheelbase     = VehicleIntrospection.DEFAULTS.wheelbase,
        trackWidth    = VehicleIntrospection.DEFAULTS.trackWidth,
        maxSteerAngle = VehicleIntrospection.DEFAULTS.maxSteerAngle,
    }

    local wheels = nil
    pcall(function()
        if vehicle.spec_wheels and type(vehicle.spec_wheels.wheels) == "table" then
            wheels = vehicle.spec_wheels.wheels
        end
    end)

    if wheels then
        pcall(function()
            local wb = inferWheelbaseFromWheels(wheels)
            if wb and wb > 0.5 then geo.wheelbase = wb end
        end)
        pcall(function()
            local tw = inferTrackWidthFromWheels(wheels)
            if tw and tw > 0.5 then geo.trackWidth = tw end
        end)
        pcall(function()
            local ms = inferMaxSteerFromWheels(wheels)
            if ms and ms > 0.1 then geo.maxSteerAngle = ms end
        end)
    end

    -- One-shot diagnostic log per vehicle.
    local name = "?"
    pcall(function() if vehicle.getName then name = vehicle:getName() or "?" end end)
    log("vehicle=%s wheelbase=%.2f trackWidth=%.2f maxSteerRad=%.3f%s",
        name, geo.wheelbase, geo.trackWidth, geo.maxSteerAngle,
        wheels and "" or " (no spec_wheels; full defaults)"
    )

    VehicleIntrospection._cache[vehicle] = geo
    return geo
end

---Determine current speed and reverse state for a vehicle.
---Returns speedKmh (unsigned, km/h) and isReverse (bool).
---Uses the same sourcing chain as CruiseControlPlus findings in docs/learned.md.
---@param vehicle table
---@return number speedKmh, boolean isReverse
function VehicleIntrospection:getMotion(vehicle)
    local speedKmh = 0
    local movingDirection = 0  -- +1 forward, -1 reverse, 0 undetermined/stopped

    pcall(function()
        if type(vehicle.lastSpeed) == "number" then
            speedKmh = math.abs(vehicle.lastSpeed) * 3.6
        elseif vehicle.spec_motorized and vehicle.spec_motorized.motor
            and type(vehicle.spec_motorized.motor.lastSpeed) == "number" then
            speedKmh = math.abs(vehicle.spec_motorized.motor.lastSpeed) * 3.6
        elseif type(vehicle.getLastSpeed) == "function" then
            -- Per learned.md: getLastSpeed() returns km/h in FS25 (not m/s as in GDN).
            speedKmh = math.abs(vehicle:getLastSpeed())
        end
    end)

    pcall(function()
        if type(vehicle.movingDirection) == "number" then
            movingDirection = vehicle.movingDirection
        elseif vehicle.spec_motorized and vehicle.spec_motorized.motor
            and type(vehicle.spec_motorized.motor.currentDirection) == "number" then
            movingDirection = vehicle.spec_motorized.motor.currentDirection
        end
    end)

    local isReverse = movingDirection < 0
    return speedKmh, isReverse
end

---Inspect what is attached at the vehicle's attacher joints. Returns a table
---separating implements by category (front-loaders vs trailers vs others) so
---callers can do quick capability checks.
---
---NOTE: this is partly exploratory — FS25's exact field shapes for joint types
---are something we want to confirm from real log output. Whatever we extract
---we log once per vehicle for diagnostic purposes.
---
---@param vehicle table
---@return table { frontLoaders={...}, trailers={...}, others={...} }
function VehicleIntrospection:getAttachedImplementsInfo(vehicle)
    local result = { frontLoaders = {}, trailers = {}, others = {} }
    if not vehicle then return result end

    local attached = nil
    pcall(function()
        if vehicle.spec_attacherJoints and type(vehicle.spec_attacherJoints.attachedImplements) == "table" then
            attached = vehicle.spec_attacherJoints.attachedImplements
        end
    end)
    if not attached then return result end

    local cache = VehicleIntrospection._implementsCache
    if not cache then
        cache = setmetatable({}, { __mode = "k" })
        VehicleIntrospection._implementsCache = cache
    end

    -- Cache key encodes the identity chain of attached objects so we re-scan
    -- on both count changes AND object swaps (e.g. attach trailer A, detach,
    -- attach trailer B — count stays 1 but object is different).
    local idBits = {}
    for _, impl in ipairs(attached) do table.insert(idBits, tostring(impl.object)) end
    local cacheKey = table.concat(idBits, "|")
    local cached = cache[vehicle]
    if cached and cached.key == cacheKey then return cached.info end

    -- Build an int -> name map for AttacherJoint types if the engine exposes one.
    local jointNames = {}
    pcall(function()
        if AttacherJoints and type(AttacherJoints.jointTypeNameToInt) == "table" then
            for name, int in pairs(AttacherJoints.jointTypeNameToInt) do
                jointNames[int] = name
            end
        end
    end)

    for _, impl in ipairs(attached) do
        local info = { object = impl.object, jointType = "?", jointTypeStr = "?",
                       jointZ = nil, vehicleTypeName = "?", axleCount = 0,
                       axleZs = {}, length = nil, width = nil, hasTurntable = false }

        -- Joint type from the host vehicle's joint descriptor.
        pcall(function()
            local idx = impl.jointDescIndex
            local descs = vehicle.spec_attacherJoints.attacherJoints
            if idx and descs and descs[idx] then
                info.jointType = descs[idx].jointType or "?"
                info.jointTypeStr = jointNames[info.jointType] or tostring(info.jointType)
                if descs[idx].jointTransform then
                    pcall(function()
                        local _, _, jz = localToLocal(descs[idx].jointTransform, vehicle.rootNode, 0, 0, 0)
                        info.jointZ = jz
                    end)
                end
            end
        end)

        -- Implement-side inspection. Two strategies: (a) probe the known-useful
        -- paths directly (specs are usually metatable-inherited and don't show up
        -- in pairs()), (b) dump scalar top-level keys for anything new we missed.
        pcall(function()
            local o = impl.object
            if not o then return end

            info.vehicleTypeName = o.typeName or "?"

            -- (a) Size: FS25 trailers expose a size subtable, NOT sizeLength/sizeWidth directly.
            if type(o.size) == "table" then
                info.length = o.size.length
                info.width  = o.size.width
                if type(o.sizeCenterOffset) == "table" then
                    info.sizeCenterZ = o.sizeCenterOffset.z
                end
            else
                info.length = o.sizeLength
                info.width  = o.sizeWidth
            end

            -- Probe where the wheels live. Now that we know specs are inherited,
            -- the spec_wheels.wheels path should succeed when wheels exist.
            local wheelSources = {
                { path = "spec_wheels.wheels",      get = function() return o.spec_wheels and o.spec_wheels.wheels end },
                { path = "wheels",                  get = function() return o.wheels end },
                { path = "spec_attachable.wheels",  get = function() return o.spec_attachable and o.spec_attachable.wheels end },
            }
            for _, src in ipairs(wheelSources) do
                pcall(function()
                    local ws = src.get()
                    if type(ws) == "table" and #ws > 0 then
                        for _, w in ipairs(ws) do
                            local z = w.positionZ
                                or (w.wheelConfig and w.wheelConfig.positionZ)
                                or (w.repr and w.repr.positionZ)
                            if type(z) == "number" then
                                info.axleCount = info.axleCount + 1
                                table.insert(info.axleZs, z)
                            end
                        end
                        if info.axleCount > 0 then info.axleSource = src.path end
                    end
                end)
                if info.axleCount > 0 then break end
            end

            if o.components and #o.components > 1 then
                info.hasTurntable = true
                info.componentCount = #o.components
            end

            -- Bonus: record the implement's rootNode so we can later read its
            -- live world position (needed for trailer kinematics visualization).
            info.rootNode = o.rootNode
        end)

        -- Heuristic categorisation using the *resolved* joint name.
        local jt = (info.jointTypeStr or ""):lower()
        local tn = (info.vehicleTypeName or ""):lower()
        if jt:find("frontloader") or tn:find("frontloader") or tn:find("loader") then
            table.insert(result.frontLoaders, info)
        elseif jt:find("trailer") or jt:find("hook") or jt:find("low")
            or tn:find("trailer") or tn:find("wagon") or tn:find("tipper")
            or info.axleCount > 0 then
            table.insert(result.trailers, info)
        else
            table.insert(result.others, info)
        end
    end

    -- Diagnostic log on first detection / when implements change.
    log("attachments for vehicle=%s: %d frontloader(s), %d trailer(s), %d other(s)",
        (vehicle.getName and vehicle:getName()) or "?",
        #result.frontLoaders, #result.trailers, #result.others)
    for _, fl in ipairs(result.frontLoaders) do
        log("  frontloader: type=%s jointType=%s (id=%s)", fl.vehicleTypeName, fl.jointTypeStr, tostring(fl.jointType))
    end
    for _, tr in ipairs(result.trailers) do
        log("  trailer: type=%s jointType=%s jointZ=%s length=%s width=%s turntable=%s",
            tr.vehicleTypeName, tr.jointTypeStr,
            tostring(tr.jointZ), tostring(tr.length), tostring(tr.width),
            tostring(tr.hasTurntable))
    end
    for _, ot in ipairs(result.others) do
        log("  other: type=%s jointType=%s", ot.vehicleTypeName, ot.jointTypeStr)
    end

    cache[vehicle] = { key = cacheKey, info = result }
    return result
end

---Convenience: returns true if a frontloader is attached.
---@param vehicle table
---@return boolean
function VehicleIntrospection:hasFrontloader(vehicle)
    local info = self:getAttachedImplementsInfo(vehicle)
    return #info.frontLoaders > 0
end

---Build a set [implementVehicle]=true for the frontloader arm and everything
---attached to it (DFS over spec_attacherJoints). Uses (1) attacher joints on the
---root whose joint type name contains "frontloader" and (2) a union with objects
---from getAttachedImplementsInfo().frontLoaders so JD / odd XML still maps.
---@param root table rootVehicle
---@return table set keyed by implement/loader vehicle table -> true
function VehicleIntrospection:getFrontloaderSubtreeObjectSet(root)
    local set = {}
    if not root then return set end

    local jointNames = {}
    pcall(function()
        if AttacherJoints and type(AttacherJoints.jointTypeNameToInt) == "table" then
            for name, int in pairs(AttacherJoints.jointTypeNameToInt) do
                jointNames[int] = name
            end
        end
    end)

    local function visitFrom(v, depth)
        pcall(function()
            if not v or depth > 14 then return end
            if set[v] then return end
            set[v] = true
            local aj = v.spec_attacherJoints
            if aj and type(aj.attachedImplements) == "table" then
                for _, impl in ipairs(aj.attachedImplements) do
                    if impl and impl.object then
                        visitFrom(impl.object, depth + 1)
                    end
                end
            end
        end)
    end

    local nJointFrontloader = 0
    local ajRoot = root.spec_attacherJoints
    if ajRoot and type(ajRoot.attachedImplements) == "table" and ajRoot.attacherJoints then
        for _, impl in ipairs(ajRoot.attachedImplements) do
            local jt = "?"
            pcall(function()
                local idx = impl.jointDescIndex
                local descs = ajRoot.attacherJoints
                if idx and descs and descs[idx] then
                    jt = jointNames[descs[idx].jointType] or tostring(descs[idx].jointType)
                end
            end)
            local jtl = (tostring(jt)):lower()
            if jtl:find("frontloader") and impl.object then
                nJointFrontloader = nJointFrontloader + 1
                visitFrom(impl.object, 0)
            end
        end
    end

    local nHeuristicFL = 0
    local ok, info = pcall(function() return self:getAttachedImplementsInfo(root) end)
    if ok and info and type(info.frontLoaders) == "table" then
        nHeuristicFL = #info.frontLoaders
        for _, fl in ipairs(info.frontLoaders) do
            if fl.object then
                visitFrom(fl.object, 0)
            end
        end
    end

    return set
end

---While LMB mouse-steering the tractor, vanilla may still feed mouse axes into
---frontloader / tool lastInputValues (fork up/down). Zero those axes each frame
---only on vehicles in the FL hardware subtree — not on drivable/motor/etc.
---@param root table rootVehicle
---@param _phase string|nil caller tag (missionUpdate | vehiclePost | modDraw); reserved for API compatibility
function VehicleIntrospection:zeroMouseHydraulicAxesOnFrontloaderHardware(root, _phase)
    local set = self:getFrontloaderSubtreeObjectSet(root)
    local setN = 0
    for _ in pairs(set) do setN = setN + 1 end
    if setN == 0 then
        return
    end

    local EXCLUDE_SPECS = {
        spec_drivable = true,
        spec_motorized = true,
        spec_enterable = true,
        spec_attacherJoints = true,
        spec_wheels = true,
        spec_lights = true,
        spec_light = true,
        spec_licensePlates = true,
        spec_aiVehicle = true,
        spec_fillUnit = true,
        spec_dischargeable = true,
        spec_combine = true,
        spec_cutter = true,
        spec_plow = true,
        spec_cultivator = true,
        spec_sowingMachine = true,
        spec_sprayer = true,
        spec_baler = true,
        spec_dashboard = true,
        spec_display = true,
    }

    ---Giants vehicle specs may be Lua tables or userdata with a __index metatable.
    local function isSpecInstance(spec)
        return spec ~= nil and (type(spec) == "table" or type(spec) == "userdata")
    end

    ---Root-only: match FL / cylinder / fork-style specs (Giants naming varies by brand).
    local function rootSpecMatchesLoaderHydraulics(nk)
        local hint = (nk or ""):lower()
        return hint:find("frontloader") or hint:find("front_loader") or hint:find("frontload")
            or hint:find("cylinder") or hint:find("movingtool") or hint:find("moving_tool")
            or hint:find("shovel") or hint:find("grab") or hint:find("balegrab")
            or hint:find("loaderconsole") or hint:find("stapler") or hint:find("palletfork")
            or hint:find("pallet") or hint:find("fork")
    end

    ---Visit specs that may carry loader hydraulic axes (never use pairs(obj) for spec_*).
    local function forLoaderHydraulicSpecs(obj, visitFn)
        local keys = resolveSpecFieldNamesForVehicleType(obj)
        for _, nk in ipairs(keys) do
            if not EXCLUDE_SPECS[nk] then
                local spec = nil
                pcall(function() spec = obj[nk] end)
                if isSpecInstance(spec) then
                    if obj == root then
                        if rootSpecMatchesLoaderHydraulics(nk) then
                            visitFn(nk, spec)
                        end
                    else
                        visitFn(nk, spec)
                    end
                end
            end
        end
    end

    ---Match any lastInputValues key that plausibly carries an analog axis (Giants naming varies).
    local function isAxisLikeKey(k)
        if type(k) ~= "string" then return false end
        return k:lower():find("axis", 1, true) ~= nil
    end

    local function zeroAxisLastInputs(spec)
        if not spec or type(spec.lastInputValues) ~= "table" then return end
        local liv = spec.lastInputValues
        for k, val in pairs(liv) do
            if isAxisLikeKey(k) and type(val) == "number" then
                liv[k] = 0
            end
        end
    end

    ---Visit root once, then subtree objects (root is usually not in `set`).
    local function forEachLoaderObject(fn)
        local seen = {}
        local function once(obj)
            if not obj or seen[obj] then return end
            seen[obj] = true
            pcall(function() fn(obj) end)
        end
        once(root)
        for obj in pairs(set) do
            once(obj)
        end
    end

    forEachLoaderObject(function(obj)
        forLoaderHydraulicSpecs(obj, function(_, spec)
            zeroAxisLastInputs(spec)
        end)
    end)
end

---True when the player's current implement selection is the frontloader arm or
---any tool attached to that arm (subtree of spec_attacherJoints on the FL vehicle).
---When the root vehicle or a rear hitch trailer (etc.) is selected, returns false
---so mouse steering can stay active.
---@param vehicle table controlled vehicle (tractor); uses rootVehicle for selection.
---@return boolean
function VehicleIntrospection:isFrontloaderBranchSelected(vehicle)
    if not vehicle then return false end
    local root = vehicle.rootVehicle or vehicle
    if not root then return false end

    local set = self:getFrontloaderSubtreeObjectSet(root)
    if not next(set) then
        return false
    end

    local function inSet(v)
        return v ~= nil and v ~= root and set[v] == true
    end

    local selVeh = nil
    pcall(function()
        if type(root.getSelectedVehicle) == "function" then
            selVeh = root:getSelectedVehicle()
        end
    end)
    if inSet(selVeh) then
        return true
    end

    local impl = nil
    pcall(function()
        if type(root.getSelectedImplement) == "function" then
            impl = root:getSelectedImplement()
        end
    end)
    if impl and impl.object and inSet(impl.object) then
        return true
    end

    return false
end

---Return trailer kinematics parameters for the FIRST attached trailer, or nil
---if nothing suitable is hooked up. Measures the live hitch angle (trailer yaw
---relative to the tractor) so the simulation starts from the current state.
---@param vehicle table
---@return table|nil { tongueLength, halfWidth, hitchOffsetZ, hitchAngle, isTurntable, implRootNode }
function VehicleIntrospection:getTrailerKinematics(vehicle)
    if not vehicle or not vehicle.rootNode then return nil end
    local info = self:getAttachedImplementsInfo(vehicle)
    local trailer = info.trailers[1]
    if not trailer or not trailer.rootNode then return nil end

    local length = trailer.length or 6.0
    local width  = trailer.width or 2.0
    local tongueLength = TrailerKinematics.approxTongueLength(length, trailer.hasTurntable)

    -- Measure the current trailer yaw relative to the tractor by transforming
    -- a forward point (0, 0, 1) from the trailer's frame into the tractor's frame.
    -- The resulting (dx, dz) gives us the direction of the trailer's forward axis
    -- as seen from the tractor, from which we derive the hitch angle.
    local hitchAngle = 0
    pcall(function()
        local tx, _, tz   = localToLocal(trailer.rootNode, vehicle.rootNode, 0, 0, 0)
        local fx, _, fz   = localToLocal(trailer.rootNode, vehicle.rootNode, 0, 0, 1)
        local dx, dz = fx - tx, fz - tz
        -- Trailer-forward direction in vehicle frame. Reference: tractor-forward = (0, 0, 1).
        -- hitchAngle = angle between those two vectors (signed), 0 = aligned.
        -- atan2(dx, dz) gives angle from +Z axis, positive for +X (right).
        hitchAngle = math.atan2(dx, dz)
    end)

    return {
        tongueLength   = tongueLength,
        halfWidth      = (width + 0.30) * 0.5,  -- match tractor line padding (15 cm each side)
        hitchOffsetZ   = trailer.jointZ or -2.0,
        hitchAngle     = hitchAngle,
        isTurntable    = trailer.hasTurntable or false,
        implRootNode   = trailer.rootNode,
        trailerLength  = length,
    }
end

---Best-effort lookup of the vehicle's physical bounding box (relative to rootNode).
---Used by the path indicator to (a) start the projected lines at the nose/tail
---instead of the geometric centre, and (b) align them with the actual outer
---edges of the vehicle — much more useful for maneuvering around obstacles
---than using the wheelbase track width.
---
---FS25 exposes vehicle.sizeLength / vehicle.sizeWidth and (optionally)
---vehicle.sizeCenterOffset { x, y, z } that shifts the bounding centre away
---from rootNode origin. Defensive pcall with tractor-ish fallbacks.
---@param vehicle table
---@return table bounds { frontZ, rearZ, leftX, rightX, length, width }
function VehicleIntrospection:getBounds(vehicle)
    if not vehicle then
        return { frontZ = 3.0, rearZ = -3.0, leftX = -1.1, rightX = 1.1, length = 6.0, width = 2.2 }
    end
    local cache = VehicleIntrospection._boundsCache
    if not cache then
        cache = setmetatable({}, { __mode = "k" })
        VehicleIntrospection._boundsCache = cache
    end
    local hit = cache[vehicle]
    if hit then return hit end

    local length, width = 6.0, 2.2  -- mid-size tractor defaults
    local cx, cz = 0, 0

    pcall(function()
        -- FS25 exposes size both as a subtable (size.length) and, on older
        -- vehicle definitions, as flat sizeLength/sizeWidth attributes. Probe
        -- the subtable first since that's what newer content uses.
        if type(vehicle.size) == "table" then
            if type(vehicle.size.length) == "number" and vehicle.size.length > 0 then
                length = vehicle.size.length
            end
            if type(vehicle.size.width) == "number" and vehicle.size.width > 0 then
                width = vehicle.size.width
            end
        end
        if type(vehicle.sizeLength) == "number" and vehicle.sizeLength > 0 then
            length = vehicle.sizeLength
        end
        if type(vehicle.sizeWidth) == "number" and vehicle.sizeWidth > 0 then
            width = vehicle.sizeWidth
        end
        if type(vehicle.sizeCenterOffset) == "table" then
            cx = vehicle.sizeCenterOffset.x or 0
            cz = vehicle.sizeCenterOffset.z or 0
        end
    end)

    local bounds = {
        length = length,
        width  = width,
        frontZ = cz + length * 0.5,
        rearZ  = cz - length * 0.5,
        leftX  = cx - width * 0.5,
        rightX = cx + width * 0.5,
    }

    log("bounds for vehicle=%s length=%.2f width=%.2f frontZ=%+.2f rearZ=%+.2f",
        (vehicle.getName and vehicle:getName()) or "?",
        bounds.length, bounds.width, bounds.frontZ, bounds.rearZ)

    cache[vehicle] = bounds
    return bounds
end

---Best-effort lookup of the vehicle's top speed in km/h.
---Tries common paths in spec_motorized, returns 40 km/h as a tractor-ish default.
---Result is cached (weak-keyed) alongside the geometry cache for per-vehicle stability.
---@param vehicle table
---@return number maxSpeedKmh
function VehicleIntrospection:getMaxSpeed(vehicle)
    if not vehicle then return 40 end
    local cache = VehicleIntrospection._maxSpeedCache
    if not cache then
        cache = setmetatable({}, { __mode = "k" })
        VehicleIntrospection._maxSpeedCache = cache
    end
    local hit = cache[vehicle]
    if hit then return hit end

    local maxKmh = nil

    -- Try a function API first: getCruiseControlMaxSpeed / getSpeedLimit sometimes exist.
    pcall(function()
        if type(vehicle.getCruiseControlMaxSpeed) == "function" then
            local v = vehicle:getCruiseControlMaxSpeed()
            if type(v) == "number" and v > 0 then maxKmh = v end
        end
    end)

    -- Fall back to motor fields (m/s → km/h).
    if not maxKmh then
        pcall(function()
            if vehicle.spec_motorized and vehicle.spec_motorized.motor then
                local motor = vehicle.spec_motorized.motor
                local candidates = { motor.maxForwardSpeed, motor.maxSpeed, motor.maxBackwardSpeed }
                for _, c in ipairs(candidates) do
                    if type(c) == "number" and c > 0 then
                        maxKmh = c * 3.6
                        break
                    end
                end
            end
        end)
    end

    -- Fall back to the Drivable spec speed limit.
    if not maxKmh then
        pcall(function()
            if vehicle.spec_drivable and type(vehicle.spec_drivable.cruiseControl) == "table"
                and type(vehicle.spec_drivable.cruiseControl.maxSpeed) == "number" then
                maxKmh = vehicle.spec_drivable.cruiseControl.maxSpeed
            end
        end)
    end

    if not maxKmh or maxKmh < 10 then maxKmh = 40 end
    if maxKmh > 300 then maxKmh = 300 end  -- hard sanity clamp

    cache[vehicle] = maxKmh
    log("maxSpeed for vehicle=%s -> %.1f km/h", (vehicle.getName and vehicle:getName()) or "?", maxKmh)
    return maxKmh
end
