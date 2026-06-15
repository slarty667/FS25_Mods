--[[
  RmbSuppression.lua
  Suppresses vanilla RMB-bound action callbacks while the player is in an
  active mouse-steering session (LMB held). Purpose: allow LMB+RMB to feel
  like "both hands on the wheel, head turning" — LMB keeps steering, RMB
  triggers free-look, without FS25 toggling the cursor mode or zooming
  the camera on us.

  Target actions (identified from the user's inputBinding.xml):
    CLICK_TO_SWITCH_TOGGLE_MOUSE      — vanilla cursor toggle
    MOUSE_ALT_COMMAND2_BUTTON         — generic "mouse alt" action 2
    MOUSE_ALT_COMMAND4_BUTTON         — LMB+RMB combo (suspected zoom)
    CP_TOGGLE_MOUSE                   — Courseplay mouse toggle
    ADToggleMouse                     — AutoDrive mouse toggle

  Mechanism: walk through g_inputBinding.actionEvents once the binding is up,
  wrap the callback of every matching event with a conditional no-op that
  checks MouseSteering.lmbDown at call time.

  Diagnostics: log what we find even if we can't wrap it, so we see the real
  event shape in FS25 and can adjust.
]]

RmbSuppression = {}
RmbSuppression.installed = false
RmbSuppression.wrappedEvents = {}
RmbSuppression.cursorWrapped = false
RmbSuppression.cursorOriginal = nil

RmbSuppression.TARGET_ACTIONS = {
    CLICK_TO_SWITCH_TOGGLE_MOUSE = true,
    MOUSE_ALT_COMMAND2_BUTTON = true,
    MOUSE_ALT_COMMAND4_BUTTON = true,
    CP_TOGGLE_MOUSE = true,
    ADToggleMouse = true,
}

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[MouseSteering][RMB] " .. fmt, ...)
    end
end

---Install wrappers. Safe to call repeatedly — only wraps once.
---
---NOTE: investigation showed FS25's RMB cursor toggle does NOT go through the
---action-event system (the bound actions exist but have 0 registered events).
---The toggle is driven straight from the engine via g_inputBinding.setShowMouseCursor.
---That's the function we actually need to wrap. The action-event walk below is
---kept as a safety net in case some mod registers a real event for our targets.
---@return boolean success whether at least one wrapper was installed
function RmbSuppression:install()
    if self.installed then return true end
    if not g_inputBinding or type(g_inputBinding.actionEvents) ~= "table" then
        return false
    end
    if type(g_inputBinding.nameActions) ~= "table" then
        return false
    end

    local nameToId = g_inputBinding.nameActions
    local count = 0

    -- Walk events for each target action id (in case any are registered).
    for name in pairs(RmbSuppression.TARGET_ACTIONS) do
        local id = nameToId[name]
        if id ~= nil then
            local list = g_inputBinding.actionEvents[id]
            if type(list) == "table" then
                for _, ev in ipairs(list) do
                    if type(ev) == "table" then
                        local callbackKey = nil
                        if     type(ev.callback)   == "function" then callbackKey = "callback"
                        elseif type(ev.callbackFn) == "function" then callbackKey = "callbackFn"
                        elseif type(ev.targetFunc) == "function" then callbackKey = "targetFunc"
                        elseif type(ev.func)       == "function" then callbackKey = "func"
                        end
                        if callbackKey then
                            local original = ev[callbackKey]
                            ev[callbackKey] = function(...)
                                if MouseSteering and MouseSteering.armed and MouseSteering.lmbDown then
                                    return -- suppress
                                end
                                return original(...)
                            end
                            table.insert(self.wrappedEvents,
                                { event = ev, original = original, key = callbackKey, actionName = name })
                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    -- Main suppression path: wrap the cursor-show API on the input binding
    -- singleton. This is what actually catches the RMB → cursor toggle.
    self:tryWrapCursorAPI()

    log("install done — action-events wrapped=%d, cursor API wrapped=%s",
        count, tostring(self.cursorWrapped))

    -- Mark installed once a real scan completed, regardless of count.
    self.installed = true
    return count > 0 or self.cursorWrapped
end

---Wrap g_inputBinding.setShowMouseCursor so cursor activations during an
---LMB-held steering session become no-ops. The Vanilla code path that the
---RMB toggle ultimately hits.
function RmbSuppression:tryWrapCursorAPI()
    if self.cursorWrapped then return true end
    if not g_inputBinding then return false end
    if type(g_inputBinding.setShowMouseCursor) ~= "function" then
        log("g_inputBinding.setShowMouseCursor not available — cursor suppression disabled")
        return false
    end

    local original = g_inputBinding.setShowMouseCursor
    self.cursorOriginal = original
    g_inputBinding.setShowMouseCursor = function(selfBinding, state, ...)
        if MouseSteering and MouseSteering.armed and MouseSteering.lmbDown and state then
            return -- don't show the cursor while we're actively steering
        end
        return original(selfBinding, state, ...)
    end
    self.cursorWrapped = true
    return true
end

---Restore all wrapped callbacks.
function RmbSuppression:uninstall()
    for i = #self.wrappedEvents, 1, -1 do
        local w = self.wrappedEvents[i]
        if w.event and w.original and w.key then
            w.event[w.key] = w.original
        end
        self.wrappedEvents[i] = nil
    end
    if self.cursorWrapped and g_inputBinding and self.cursorOriginal then
        g_inputBinding.setShowMouseCursor = self.cursorOriginal
        self.cursorWrapped = false
        self.cursorOriginal = nil
    end
    self.installed = false
    log("uninstalled")
end
