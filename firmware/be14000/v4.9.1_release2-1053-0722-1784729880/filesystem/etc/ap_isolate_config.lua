local uci = require "uci"
local utils = require "oui.utils"
local fs = require "oui.fs"
local glog = require "glog"

local interface = arg[1]
local ap_isolate = arg[2]

if interface == nil then
    glog.err("[ap_isolate_config]interface nil")
    os.exit(1)
end

if ap_isolate == nil then
    glog.err("[ap_isolate_config]ap_isolate nil")
    os.exit(1)
end

ap_isolate = tonumber(ap_isolate)

--- @param s  string|nil
local function trim(s)
    if s == nil then return "" end
    return tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
end

--- 先读 UCI device.ports，空则读 /sys/.../brif/members（与 vlan_subnet 有线绑定逻辑一致，避免 UCI 未列全时有线不隔离）。
--- @param c            uci.cursor
--- @param bridge_name  string
--- @return string[]
local function get_port_tokens_for_bridge(c, bridge_name)
    local tokens = {}
    local seen = {}
    local function add_one(name)
        if not name or name == "" then return end
        local base = tostring(name):match("^([^:]+)") or name
        if not seen[base] then
            seen[base] = true
            tokens[#tokens + 1] = base
        end
    end
    c:foreach("network", "device", function(s)
        if s.name == bridge_name and s.ports then
            local p = s.ports
            if type(p) == "string" then p = { p } end
            for _, v in ipairs(p) do
                for token in tostring(v):gmatch("%S+") do
                    add_one(token)
                end
            end
        end
    end)
    if #tokens > 0 then
        return tokens
    end
    if not bridge_name or not bridge_name:match("^[%w%-]+$") then
        return tokens
    end
    local fh = io.popen("ls /sys/class/net/" .. bridge_name .. "/brif 2>/dev/null")
    if fh then
        for line in fh:lines() do
            if line ~= "" then
                add_one(line)
            end
        end
        fh:close()
    end
    return tokens
end

--- 有线：各 DSA/物理口在 network.device 上写 isolate（跳过 WAN 口名）。
local function apply_device_isolate_for_port_names(c, port_tokens, wan_port, ap_isolate)
    for _, port in ipairs(port_tokens) do
        if port ~= wan_port and port ~= "" then
            c:foreach("network", "device", function(s)
                if s.name == port then
                    c:set("network", s[".name"], "isolate", ap_isolate)
                end
            end)
        end
    end
end

local c = uci.cursor()
c:foreach("wireless", "wifi-iface", function(s)
    local wiface = s['.name']
    local network = c:get("wireless", wiface, "network")
    if network == interface then
        c:set("wireless", wiface, "isolate", ap_isolate)
    end
end)

c:set("gl-black_white_list", interface, "ap_isolate", ap_isolate)

-- 通用于 ecm/非 ecm
c:set("network", interface, "isolate", ap_isolate)

local wan_port = trim(utils.readfile("/proc/gl-hw-info/wan", "*l"))

-- ECM 加速机型：主桥 lan 口、lan_dev（仅 lan 子网时随 interface=lan 配置）
if fs.access("/etc/config/ecm") then
    local lan_ports
    c:foreach("network", "device", function(s)
        if s.name == "br-lan" then
            lan_ports = s.ports
        end
        if s[".name"] == "lan_dev" and interface == "lan" then
            c:set("network", s[".name"], "isolate", ap_isolate)
        end
    end)

    c:foreach("network", "device", function(s)
        for _, port in ipairs(lan_ports or {}) do
            if s.name == port and interface == "lan" and s.name ~= wan_port then
                c:set("network", s[".name"], "isolate", ap_isolate)
            end
        end
    end)
end

-- 有线：br-guest / br-iot / br-vlan* 成员口。**不**放在仅 ecm 内，纯 MTK 无 ecm 时此前有线从不写 device.isolate
do
    local bridge_name
    if interface == "guest" then
        bridge_name = "br-guest"
    elseif interface == "iot" then
        bridge_name = "br-iot"
    else
        local vid = interface:match("^vlan(%d+)$")
        if vid then
            bridge_name = "br-vlan" .. vid
        end
    end
    if bridge_name then
        local port_tokens = get_port_tokens_for_bridge(c, bridge_name)
        apply_device_isolate_for_port_names(c, port_tokens, wan_port, ap_isolate)
    end
end

local function sync_zone_intra_forward(c, zone, ap_isolate)
    local sid = zone .. "_forward"
    if ap_isolate == 1 then
        c:delete("firewall", sid)
    else
        c:set("firewall", sid, "forwarding")
        c:set("firewall", sid, "src", zone)
        c:set("firewall", sid, "dest", zone)
    end
end

if interface == "guest" then
    sync_zone_intra_forward(c, "guest", ap_isolate)
elseif interface == "iot" then
    sync_zone_intra_forward(c, "iot", ap_isolate)
elseif interface:match("^vlan(%d+)$") then
    sync_zone_intra_forward(c, interface, ap_isolate)
end

c:commit("network")
c:commit("gl-black_white_list")
c:commit("wireless")
c:commit("firewall")

if fs.access("/usr/sbin/mwctl") then
    os.execute("wifi reload")
end
