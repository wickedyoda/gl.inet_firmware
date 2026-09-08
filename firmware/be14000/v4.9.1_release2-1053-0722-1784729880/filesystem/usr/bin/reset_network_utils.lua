#!/usr/bin/lua

local uci = require "uci"
local ubus = require "ubus"
local lfactory = require "lfactory"
local cjson = require "cjson"
local utils = require "oui.utils"
local fs = require 'oui.fs'

local function ubus_call(o, m, p)
    local con = ubus.connect()
    local res = con:call(o, m, p or {})
    con:close()
    return res
end

local function turn_off_sqm()
    local c = uci.cursor()
    if fs.access("/etc/init.d/sqm") then
        c:foreach("sqm", "queue", function(s)
            c:set("sqm", s[".name"], "enabled", '0')
        end)
        c:commit("sqm")
        os.execute("/etc/init.d/sqm reload")
    end
end

local function switch_vpn(mod, turn_on)
    local func = turn_on and "start" or "stop"
    local params = {
        not_reload_network = true
    }

    local res = ubus_call('gl-session', 'call', { module = mod, func = func, params = params })
    if res then
        return res.result
    end
end

local function turn_off_vpn_server()
    local c = uci.cursor()
    if c:get("network", "ovpnserver", "disabled") == "0" then
        switch_vpn("ovpn-server", false)
    end
    if c:get("network", "wgserver", "disabled") == "0" then
        switch_vpn("wg-server", false)
    end
end

local function turn_off_vpn_client()
    ubus_call("gl-session", "call", { module = "vpn-client", func = "turn_off_all_vpn_tunnel", params = {} })
end

local function turn_off_tailscale()
    local c = uci.cursor()
    if c:get("tailscale", "settings", "enabled") == "1" then
        ubus_call('gl-session', 'call', { module = "tailscale", func = "set_config", params = { enabled = false } })
    end
end

local function turn_off_zerotier()
    local c = uci.cursor()
    if c:get("zerotier", "gl", "enabled") == "1" then
        ubus_call('gl-session', 'call', { module = "zerotier", func = "set_config", params = { enabled = false } })
    end
end

local function turn_off_tor()
    local c = uci.cursor()
    if c:get("tor", "global", "enable") == "1" then
        ubus_call('gl-session', 'call', { module = "tor", func = "set_config", params = { enable = false } })
    end
end

local function turn_off_adguardhome()
    local c = uci.cursor()
    if c:get("adguardhome", "config", "enabled") == "1" then
        ubus_call('gl-session', 'call', { module = "adguardhome", func = "set_config", params = { enabled = false } })
    end
end

local function restore_wan_config()
    local c = uci.cursor()

    local not_device = true
    local wan_port = lfactory.get_wan_port()
    local secondwan_port = lfactory.get_secondwan_port()

    local model = utils.readfile("/proc/gl-hw-info/model")
    if model and (model:find("be9300") or model:find("be6500")) then
        c:delete("board_special", "hardware", "wan")
        c:delete("board_special", "hardware", "secondwan")
        c:delete("network", "vlan_secondwan")
        c:delete("network", "secondwan_dev")
        c:foreach("network", "switch_vlan", function(s)
        if s[".name"] == "vlan_lan" then
            c:set("network", s[".name"], "ports", "4 5 6 7 3t")
        end
        end)
        c:set("board_special", "hardware", "lan", "eth1.1")
        c:commit("board_special")
    elseif model and (model:find("mt5000")) then
        c:delete("board_special", "hardware", "wan")
        c:delete("board_special", "hardware", "secondwan")
        c:delete("network", "vlan_secondwan")
        c:delete("network", "secondwan_dev")
        c:foreach("network", "switch_vlan", function(s)
        if s[".name"] == "vlan_lan" then
            c:set("network", s[".name"], "ports", "0 1 17t")
        end
        end)
        c:set("board_special", "hardware", "lan", "eth0.1")
        c:commit("board_special")
    end

    for s in c:each("network", "device") do
        if s.name == wan_port or s.name == secondwan_port then
            local mac_mode = c:get("network", s['.name'], "mac_mode")

            if mac_mode and mac_mode:find('[cr]') then
                not_device = false
                local board = cjson.decode(utils.readfile('/etc/board.json'))

                local mac
                if s.name == secondwan_port then
                    mac = board.network.lan.macaddr
                else
                    mac = board.network.wan.macaddr
                end

                c:delete("network", s['.name'], "mac_mode")
                c:delete("network", s['.name'], "mac_expire")
                c:set("network", s['.name'], "macaddr", mac or "")
            end
        end
    end

    if not_device then
        local mac_mode = c:get("network",'wan', "mac_mode")
        if mac_mode and mac_mode:find('[cr]') then
            local board = cjson.decode(utils.readfile('/etc/board.json'))
            local mac =  board.network.wan.macaddr or lfactory.get_mac() or ""

            c:delete("network", 'wan', "mac_mode")
            c:delete("network", 'wan', "mac_expire")
            c:set("network", 'wan', "macaddr", mac)
        end
    end

    c:delete("network", "secondwan", "device")
    c:delete("network", "secondwan", "disabled")

    c:delete("network", "wan", "hostname")
    c:delete("network", "secondwan", "hostname")

    c:set("glconfig", "general", "lan2wan", "0")
    c:commit("network")
    c:commit("glconfig")
end

local function turn_off_wan_isolate()
    local c = uci.cursor()
    local need_reload = false

    c:set("gl-black_white_list", "guest", "wan_isolate", "0")
    c:set("gl-black_white_list", "iot", "wan_isolate", "0")
    c:set("network", "guest", "disabled", "1")
    c:set("network", "iot", "disabled", "1")

    for s in c:each("firewall", "rule") do
        local name = s[".name"]
        if string.find(name, "_guest_isolate") or string.find(name, "_iot_isolate") then
            c:delete("firewall", name)
            need_reload = true
        end
    end

    c:commit("gl-black_white_list")
    c:commit("firewall")
    c:commit("network")

    if need_reload then
        os.execute("/etc/init.d/firewall reload&")
    end
end

local function turn_off_tap_s2s()
    local c = uci.cursor()

    c:delete("network", "ovpnclient")
    c:commit("network")
    os.execute("/usr/bin/setup_tap_s2s client_ifdown >/dev/null 2>&1")
    c:set("route_policy", "global", "is_tap_s2s", "0")
    c:commit("route_policy")
end

local function turn_off_easymesh()
    if fs.access("/etc/config/gl-mesh") then
        local c = uci.cursor()
        local mode = c:get('gl-mesh', '@base[0]', 'mode')
        ubus_call('gl-session', 'call', { module = "mesh", func = "set_config", params = { enabled = false, mode = mode } })
    end
end

local function turn_off_all()
    turn_off_vpn_server()
    turn_off_vpn_client()
    turn_off_tailscale()
    turn_off_zerotier()
    turn_off_tor()
    turn_off_adguardhome()
    restore_wan_config()
    turn_off_wan_isolate()
    turn_off_tap_s2s()
    turn_off_easymesh()
end

local function switch_to_tap_s2s()
    turn_off_tailscale()
    turn_off_zerotier()
    turn_off_tor()
    turn_off_adguardhome()
    turn_off_sqm()
    turn_off_vpn_server()
end

if #arg then
    if arg[1] == "turn_off_all" then
        turn_off_all()
    end

    if arg[1] == "switch_to_tap_s2s" then
        switch_to_tap_s2s()
    end
end
