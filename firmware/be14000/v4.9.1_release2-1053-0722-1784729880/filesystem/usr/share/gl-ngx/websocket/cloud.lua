local ubus = require 'oui.ubus'

local M = {}

function M.status()
    local data = ubus.call("gl-session", "call", { module = "cloud", func = "get_config", params = {} })
    if data and data.result then
        return data.result
    else
        return ""
    end
end

return M
