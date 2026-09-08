-- gl.common - 通用工具函数
-- 注意：本模块会被 eco 协程环境和普通 Lua 环境同时引用，内部接口需同时兼容两种环境。
local M = {}

local ok, ubus = pcall(require, "eco.ubus")
if not ok then
    ubus = require("ubus")
    function M.ubus_call(object, method, params)
        local con = ubus.connect()
        if not con then
            return nil
        end
        local res = con:call(object, method, params)
        con:close()
        return res
    end
else
    function M.ubus_call(object, method, params)
        return ubus.call(object, method, params)
    end
end

local get_device_wan_port_raw
local ok, lfactory = pcall(require, "lfactory")
if ok then
    get_device_wan_port_raw = function()
        return lfactory.get_wan_port()
    end
else
    local ffi = require("ffi")
    pcall(ffi.cdef, "int get_device_wan_port(char *port, int len);")
    local lib = ffi.load("libgl-utils.so")
    get_device_wan_port_raw = function()
        local buf = ffi.new("char[24]")
        if lib.get_device_wan_port(buf, 24) == 0 then
            local port = ffi.string(buf)
            if port ~= '' then
                return port
            end
        end
        return nil
    end
end

function M.get_wan_port()
    local port = get_device_wan_port_raw()
    if port and port ~= '' then
        return port
    end
    return nil
end

return M
