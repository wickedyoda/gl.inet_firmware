#!/usr/bin/lua

local uci = require "uci"
local ubus = require "ubus"
local kmwan = require "gl.kmwan"

local function ubus_call(o, m, p)
    local con = ubus.connect()
    local res = con:call(o, m, p or {})
    con:close()
    return res
end

local network = {}
local c = uci.cursor()

local mode_str = c:get("glconfig", "general", "mode") or "router"
local mode = 5

if mode_str == "router"  then
    mode = 0
elseif mode_str == "wds" then
    mode = 1
elseif mode_str == "relay" then
    mode = 2
elseif mode_str == "mesh" then
    mode = 3
elseif mode_str == "ap" then
    mode = 4
end

c:foreach("kmwan", "member", function(s)
    local name = s[".name"]
    if mode == 4 and name == "wan" then
        name = "lan"
    elseif mode == 1 and name == "wwan" then
        name = "lan"
    end

    local up = (ubus_call("network.interface."..name, "status") or {}).up or false
    local online = up
    local kmwan_enable = c:get("kmwan", name, "disabled") == "0"
    if kmwan_enable then
        online = up and kmwan.get_ifstatus(name) == "online" or false
    end
    if name == "lan" and up == true then
        online = true
    end

    if online then
        online = "online"
    else
        online = "offline"
    end

    network[#network + 1] = {
        interface = s[".name"],
        online = online,
        up = up,
        print(name),
        print(up),
        print(online),
    }
end)
