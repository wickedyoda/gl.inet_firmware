#!/usr/bin/lua

local uci  = require("uci").cursor()
local ubus = require("ubus").connect()

local PROC_PORT_FORWARD = "/proc/port_forward"

local function valid_proc_line(line)
    return type(line) == "string" and line:match("^[%w%. %-]+$") ~= nil
end

local function writeln(line)
    if #line >= 200 then
        error("port_forward cmd too long: " .. line)
    end

    if not valid_proc_line(line) then
        return
    end

    local fp = io.open(PROC_PORT_FORWARD, "w")
    if not fp then
        return
    end

    fp:write(line, "\n")
    fp:close()
end

local function parse_port_range(p)
    if not p then return nil end
    local s, e = p:match("^(%d+)%-(%d+)$")
    if s then return tonumber(s), tonumber(e) end
    local n = tonumber(p)
    if n then return n, n end
    return nil
end

local function zone_to_ips(zones)
    local ips = {}

    if type(zones) == "string" then
        zones = {zones}
    end

    for _, zone in ipairs(zones) do
        local res = ubus:call("network.interface." .. zone, "status", {})
        if res and res["ipv4-address"] then
            for _, addr in ipairs(res["ipv4-address"]) do
                if addr.address then
                    ips[#ips + 1] = addr.address
                end
            end
        end
    end

    return ips
end

local function prefix_to_mask(prefix)
    local m = {0, 0, 0, 0}
    local full = math.floor(prefix / 8)
    local rest = prefix % 8

    for i = 1, 4 do
        if i <= full then
            m[i] = 255
        elseif rest ~= 0 and i == full + 1 then
            m[i] = 256 - (2 ^ (8 - rest))
        else
            m[i] = 0
        end
    end

    return m
end

local function calc_net(ip, mask)
    local a,b,c,d = ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
    a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)

    return string.format("%d.%d.%d.%d",
        math.floor(a / (256 - mask[1])) * (256 - mask[1]),
        math.floor(b / (256 - mask[2])) * (256 - mask[2]),
        math.floor(c / (256 - mask[3])) * (256 - mask[3]),
        math.floor(d / (256 - mask[4])) * (256 - mask[4])
    )
end

local function zone_to_netinfo(zone)
    local res = ubus:call("network.interface." .. zone, "status", {})
    if not res or not res["ipv4-address"] then
        return nil
    end

    local addr = res["ipv4-address"][1]
    if not addr or not addr.address or not addr.mask then
        return nil
    end

    local ip = addr.address
    local prefix = tonumber(addr.mask)

    local mask_arr = prefix_to_mask(prefix)
    local net = calc_net(ip, mask_arr)

    local mask = string.format("%d.%d.%d.%d",
        mask_arr[1], mask_arr[2], mask_arr[3], mask_arr[4]
    )

    return {
        net  = net,
        mask = mask,
        gw   = ip,
    }
end

for _, z in ipairs({"lan", "guest"}) do
    local info = zone_to_netinfo(z)
    if info then
        writeln(string.format(
            "zone %s %s %s %s",
            z, info.net, info.mask, info.gw
        ))
    end
end

writeln("clear")

local function dmz_enabled()
    local enabled = false
    uci:foreach("port_forward","redirect",function(s)
        if s.enabled ~= "1" then
            return
        end

        local proto = s.proto or ""

        if proto == "all"
           and not s.src_dport
           and not s.dest_port
        then
            enabled = true
            return false
        end

    end)

    return enabled
end

local function send_router_service_ports()
    if not dmz_enabled() then
        return
    end

    local services = {
        "ovpnserver_allow",
        "wgserver_allow",
        "https_wan",
        "ssh_wan"
    }

    for _,svc in ipairs(services) do
        local enabled = uci:get("firewall",svc,"enabled")
        if enabled == "1" then
            local proto = uci:get("firewall", svc, "proto") or ""
            local port  = uci:get("firewall", svc, "dest_port")

            if port then
                for p in proto:gmatch("%S+") do
                    writeln(string.format("svcport %s %s", p, port))
                end
            end
        end
    end
end

send_router_service_ports()

uci:foreach("port_forward", "redirect", function(s)
    if s.enabled ~= "1" then return end

    local dest_ip = s.dest_ip
    if not dest_ip then return end

    local proto = s.proto or "tcp"
    local zone  = s.src or "wan"
    if zone == "wan" then
        zone = {}
        uci:foreach("firewall", "zone", function(section)
            if section.name and section.name == "wan" then
                if section.network and type(section.network) == "table" then
                    for _, net in ipairs(section.network) do
                        if not net:match("6") then
                            zone[#zone + 1] = net
                        end
                    end
                end
                return
            end
        end)
    end

    local ip_list = zone_to_ips(zone)
    if #ip_list == 0 then return end

    local is_dmz = (proto == "all" and not s.src_dport and not s.dest_port)

    if is_dmz then
        for _, match_ip in ipairs(ip_list) do
            local cmd = string.format(
                "add all %s 0 0 %s 0 0",
                match_ip,
                dest_ip
            )
            writeln(cmd)
        end
        return
    end

    local src_s, src_e = parse_port_range(s.src_dport)
    local dst_s, dst_e = parse_port_range(s.dest_port)

    if not (src_s and src_e and dst_s and dst_e) then
        return
    end

    for _, match_ip in ipairs(ip_list) do
        for p in proto:gmatch("%S+") do
            local cmd = string.format(
                "add %s %s %d %d %s %d %d",
                p,
                match_ip,
                src_s, src_e,
                dest_ip,
                dst_s, dst_e
            )
            writeln(cmd)
        end
    end
end)

writeln("commit")
