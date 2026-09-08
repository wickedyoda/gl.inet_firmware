local core = require "oui.utils.utils"
local fs = require "oui.fs"
local uci = require "uci"
local cjson = require "cjson"
local ubus = require "oui.ubus"

local M = {}

setmetatable(M, {
    __index = core
})

-- The available formats are:
-- "n": reads a numeral and returns it as a float or an integer, following the lexical conventions of Lua.
-- "a": reads the whole file. This is the default format.
-- "l": reads the next line skipping the end of line.
-- "L": reads the next line keeping the end-of-line character (if present).
-- number: reads a string with up to this number of bytes. If number is zero, it reads nothing and returns an empty string.
-- Return nil if the file open failed
M.readfile = function(name, format)
    local f = io.open(name, "r")
    if not f then return nil end

    -- Compatible with the version below 5.3
    if type(format) == "string" and format:sub(1, 1) ~= "*" then format = "*" .. format end

    local data

    if format == "*L" and tonumber(_VERSION:match("%d.%d")) < 5.2 then
        data = f:read("*l")
        if data then data = data .. "\n" end
    else
        data = f:read(format or "*a")
    end

    f:close()
    return data or ""
end

M.writefile = function (name, data, append)
    local f = io.open(name, append and "a" or "w")
    if not f then return nil end
    f:write(data)
    f:close()
    return true
end

M.generate_id = function(n)
    local t = {
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
    }
    local s = {}
    for _ = 1, n do
        s[#s + 1] = t[math.random(#t)]
    end

    return table.concat(s)
end

local function check_net(ip, port)
    local sock = ngx.socket.tcp()
    sock:settimeout(1000)
    local ok = sock:connect(ip, port)
    sock:close()
    return ok
end

M.get_net_status = function()
    local port = 53
    local c = uci.cursor()
    local track_ips = c:get("glconfig", "general", "track_ip")

    for _, ip in ipairs(track_ips) do
        if check_net(ip, port) then return true end
    end

    return false
end

--[[
    local utils = require 'oui.utils'

    local pids =  utils.pidof('nginx')

    for _, pid in ipairs(pids) do
        print(pid)
    end
--]]
M.pidof = function(name)
    local pids = {}

    for pid in fs.dir("/proc") do
        if pid:match("%d+") == pid then
            local comm = M.readfile("/proc/" .. pid .. "/comm", "l")
            if comm == name then
                pids[#pids + 1] = tonumber(pid)
            end
        end
    end

    return pids
end
M.escape_shell_arg = function(arg)
    -- 转义单引号和其他特殊字符
    return "'" .. arg:gsub("'", "'\\''") .. "'"
end

-- 该函数只负责严格匹配格式xxx:xxx
M.split_host_port = function(str)
    local host
    local port

    -- 先尝试匹配 IPv6 方括号格式 [host]:port
    host, port = string.match(str, "^%[([%x:]+)%]:(%d+)$")
    if host then
        return host, port
    end

    -- 若无方括号，找最后一个冒号分割（兼容非常规格式）
    host, port = string.match(str, "^(.+):(%d+)$")
    if host then
        return host, port
    end

    return nil, nil -- 无效格式
end

M.call_rpc = function(mod, func, params)
    local res = ubus.call('gl-session', 'call', { module = mod, func = func, params = params })
    if res then
        return res.result
    end
end

M.get_client_data_by_socket = function(cmd)
    local sock = ngx.socket.tcp()
    sock:settimeout(10000)
    local ok, _ = sock:connect("unix:/tmp/gl_clients.sock")
    if not ok then
        return nil
    end
    sock:send(cmd.."\n")
    local data_len, _ = sock:receive()
    if data_len == nil then
        return nil
    end
    local data, _  = sock:receive(tonumber(data_len))
    if data == nil then
        return nil
    end
    return cjson.decode(data)
end

M.adjust_firewall_priority = function(sid)
    local c = uci.cursor()
    local my_prio
    local special_rules = {
        sambasharewan = 2,
        sambasharelan = 2,
        glnas_ser = 2,
        webdav_wan = 2
    }
    c:foreach("firewall", "rule", function(s)
        if s[".name"] == sid then
            my_prio = tonumber(s.gl_prio)
        end
    end)
    if not my_prio then return end
    local last_same_prio_pos
    local first_lower_prio_pos
    c:foreach("firewall", "rule", function(s)
        if s[".name"] == sid then return end
        local rule_prio = tonumber(s.gl_prio) or special_rules[s[".name"]]
        if not rule_prio then return end
        if rule_prio == my_prio then
            last_same_prio_pos = s[".index"]
        elseif rule_prio > my_prio then  -- 优先级比我低
            if not first_lower_prio_pos then  -- 只记录第一个
                first_lower_prio_pos = s[".index"]
            end
        end
    end)
    if last_same_prio_pos then
        c:reorder("firewall", sid, last_same_prio_pos + 1)
    elseif first_lower_prio_pos then
        c:reorder("firewall", sid, first_lower_prio_pos)
    end
    c:commit("firewall")
end

return M
