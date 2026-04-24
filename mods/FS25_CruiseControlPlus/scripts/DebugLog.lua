--[[
  DebugLog.lua - NDJSON instrumentation for debug sessions.
  Writes to workspace .cursor/debug.log when DebugLog_write() is called.
]]
local DEBUG_LOG_PATH = "/Users/markusuhl/Dropbox/htdocs/FS25_Mods/.cursor/debug.log"

local function escape(s)
    if s == nil then return "" end
    return tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

function DebugLog_write(hypothesisId, location, message, data)
    local ts = (g_currentMission and g_currentMission.time) or (getTickCount and getTickCount()) or 0
    local dataJson = "null"
    if data and type(data) == "table" then
        local parts = {}
        for k, v in pairs(data) do
            local key = escape(tostring(k))
            if v == nil then
                parts[#parts + 1] = string.format('"%s":null', key)
            elseif type(v) == "number" then
                parts[#parts + 1] = string.format('"%s":%s', key, v)
            elseif type(v) == "boolean" then
                parts[#parts + 1] = string.format('"%s":%s', key, tostring(v))
            else
                parts[#parts + 1] = string.format('"%s":"%s"', key, escape(tostring(v)))
            end
        end
        dataJson = "{" .. table.concat(parts, ",") .. "}"
    end
    local line = string.format('{"hypothesisId":"%s","location":"%s","message":"%s","data":%s,"timestamp":%s}',
        escape(hypothesisId), escape(location), escape(message), dataJson, ts)
    pcall(function()
        local f = io.open(DEBUG_LOG_PATH, "a")
        if f then f:write(line .. "\n"); f:close() end
    end)
end
