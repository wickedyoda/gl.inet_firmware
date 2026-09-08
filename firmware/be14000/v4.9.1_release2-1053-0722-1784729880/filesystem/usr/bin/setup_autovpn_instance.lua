#!/usr/bin/env eco

local uci = require 'uci'
local ubus = require 'eco.ubus'
local time = require 'eco.time'
local file = require 'eco.file'

local function get_tunnel_sid(tunnel)
    local sid
    local c = uci.cursor()

    c:foreach("route_policy", "rule", function(s)
        if s.tunnel_id == tunnel then
            sid = s[".name"]
        end
    end)

    return sid
end

local function notify_status()
    local status = ubus.call('gl-session', 'call', { module = "vpn-client", func = "get_status", params = {} })

    if status and status.result then
        ubus.call('gl-session', 'notify', { name = "vpnclient.status", data = status.result})
    end
end

local function apply()
    os.execute("/etc/init.d/vpn-client restart&")
    return
end

local function find_peer_in_network(config, type)
    local res = {}
    local count = 0
    local c = uci.cursor()

    for s in c:each('network', 'interface') do
        if s.proto == type then
            count = count + 1
            if s.config == config then
                res.name = s[".name"]
                res.found = true
                res.disabled = s.disabled
            end
        end
    end

    res.count = count
    return res
end

local function setup_instance(sid, type)
    local c = uci.cursor()

    local peer = type == "wgclient" and "peers" or "clients"
    local config = type == "wgclient" and "wireguard" or "ovpnclient"
    for s in c:each(config, peer) do
        local res = find_peer_in_network(s[".name"], type)
        if (not res.found and res.count < 5) or (res.found and res.disabled == "1") and (s.mode ~= "tap-s2s") then
            local peer_id
            if type == "wgclient" then
                peer_id = string.match(s[".name"], "%d+")
                c:set("route_policy", sid, "peer_id", peer_id)
            else
                peer_id = s.client_id
                c:set("route_policy", sid, "client_id", peer_id)
            end

            c:set("route_policy", sid, "group_id", s.group_id)
            c:commit("route_policy")
            return true
        end

    end

    return false
end

local function find_available_instance(type)
    local instance
    local c = uci.cursor()

    for s in c:each('network', 'interface') do
        if s.proto == type and s.disabled ~= "1" then
            local ifstatus = s[".name"] and ubus.call('network.interface.'..s[".name"], 'status') or {}
            if ifstatus.up then
                local group_id
                local client_id
                local peer_id
                if type == "ovpnclient" then
                    group_id, client_id = s.config:match("(%d+)%_(%d+)")
                else
                    group_id = c:get("wireguard", s.config, "group_id")
                    peer_id = s.config:match("%_(%d+)")
                end

                instance = {
                    name = s[".name"],
                    group_id = group_id,
                    peer_id = peer_id,
                    client_id = client_id
                }

                notify_status()
                return instance
            end
        end
    end

    return nil
end

local function select_instance(tunnel)
    local instance
    local c = uci.cursor()
    local sid = get_tunnel_sid(tunnel)

    if not sid then return true end

    local via_type = c:get("route_policy", sid, "via_type")
    local enabled = c:get("route_policy", sid, "enabled")
    if via_type ~= "autovpn" or enabled ~= "1" then
        return true
    end

    local via = c:get("route_policy", sid, "via")
    local ifstatus = via and ubus.call('network.interface.'..via, 'status') or {}
    if ifstatus.up then
        return true
    end

    instance = find_available_instance("wgclient")
    if not instance then
        instance = find_available_instance("ovpnclient")
    end

    if instance then
        c:set("route_policy", sid, "via", instance.name)
        c:set("route_policy", sid, "group_id", instance.group_id)
        if instance.peer_id then
            c:set("route_policy", sid, "peer_id", instance.peer_id)
        else
            c:set("route_policy", sid, "client_id", instance.client_id)
        end
        c:commit("route_policy")
        apply()
        return true
    end

    -- no instances that have already been setup, select and setup instance
    local ret = setup_instance(sid, "wgclient")
    if not ret then
        ret = setup_instance(sid, "ovpnclient")
    end

    if ret then apply() end

    return ret
end

local function main(tunnel)
    local success = false

    while not success do
        success = select_instance(tunnel)
        if success then
            file.sync()
            os.exit(1)
        end

        time.sleep(300)
    end
end

if #arg < 1 then
    os.exit(1)
end

main(arg[1])
