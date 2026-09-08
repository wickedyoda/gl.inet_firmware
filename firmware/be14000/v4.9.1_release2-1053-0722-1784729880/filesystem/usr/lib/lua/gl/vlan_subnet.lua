--[[
    @object-name: vlan_subnet
    @object-desc: VLAN subnet management API (OR0089).
                  Covers main/guest/IOT/custom subnet CRUD, address reservation,
                  lifecycle events, client view, and VPN interface linkage.
                  DSA independent bridge model: br-lan / br-guest / br-iot / br-vlanN.
--]]


local uci = require "uci"
local bit = require "bit"
local ubus = require "oui.ubus"
local lnet = require "oui.network"
local fs = require "oui.fs"
local utils = require 'oui.utils'
local validator = require "gl.validator"
local libcable = require "libcable"

local hardware
do
    local ok, h = pcall(require, "hardware")
    hardware = ok and h or nil
end

local M = {}

local ERR_INVALID_PARAMS         = -1
local ERR_WAN_IP_CONFLICT        = -7
local ERR_LAN_IP_CONFLICT        = -8
local ERR_GUEST_IP_CONFLICT      = -9
local ERR_IOT_IP_CONFLICT        = -11
local ERR_VLAN_ID_OUT_OF_RANGE   = -12
local ERR_VLAN_ID_CONFLICT       = -13
local ERR_SUBNET_CONFLICT        = -14
local ERR_DHCP_INVALID           = -15
local ERR_DELETE_HAS_BINDINGS    = -16
local ERR_DELETE_FIXED_SUBNET    = -17
local ERR_SUBNET_LIMIT_EXCEEDED  = -18
local ERR_DISPLAY_NAME_CONFLICT  = -19
local ERR_SUBNET_NOT_FOUND              = -20
local ERR_STATIC_BIND_SUBNET_SELECTOR   = -21
local ERR_STATIC_BIND_IP_NOT_IN_SUBNET  = -22
local ERR_STATIC_BIND_GATEWAY_IP        = -23
local ERR_NO_PHYSICAL_WAN               = -4
local ERR_NO_VIRTUAL_WAN                = -5

--- Build a standardised RPC error response.
-- @param code  number   err_code value
-- @param msg   string   err_msg  value
-- @param extra table?   optional extra fields merged into the response
-- @return table  { err_code = code, err_msg = msg, ... }
local function rpc_error(code, msg, extra)
    local result = { err_code = code, err_msg = msg }
    if extra then
        for k, v in pairs(extra) do
            result[k] = v
        end
    end
    return result
end

local FIXED_SUBNETS = { "lan", "guest", "iot" }
local MAX_CUSTOM_SUBNETS = 20
local VLAN_ID_MIN = 9
local VLAN_ID_MAX = 4000

local DISPLAY_NAME_MAP = {
    lan   = "main",
    guest = "guest",
    iot   = "iot",
}

local NETWORK_MAP = {
    main  = "lan",
    guest = "guest",
    iot   = "iot",
}

local DEFAULT_SUBNET_CFG = {
    lan = {
        display_name = "main",
        vlan_id = 1,
        bridge = "br-lan",
        gateway = "192.168.8.1",
        netmask = "255.255.255.0",
        enabled = true,
        dhcp_enable = true,
        dhcp_start = 100,
        dhcp_limit = 150,
        leasetime = "12h",
        wan_access_mode = 0,
        isolate = false,
    },
    guest = {
        display_name = "guest",
        vlan_id = 9,
        bridge = "br-guest",
        gateway = "192.168.9.1",
        netmask = "255.255.255.0",
        enabled = false,
        dhcp_enable = true,
        dhcp_start = 100,
        dhcp_limit = 150,
        leasetime = "12h",
        wan_access_mode = 0,
        isolate = false,
    },
    iot = {
        display_name = "iot",
        vlan_id = 10,
        bridge = "br-iot",
        gateway = "192.168.10.1",
        netmask = "255.255.255.0",
        enabled = false,
        dhcp_enable = true,
        dhcp_start = 100,
        dhcp_limit = 150,
        leasetime = "12h",
        wan_access_mode = 0,
        isolate = false,
    },
}

local WIFI_IFACE_NAME = {
    lan   = "Main",
    guest = "Guest",
    iot   = "IoT",
}


--- 将点分十进制 IPv4 字符串转换为无符号 32 位整数（Lua double 表示）。
-- @param ip  string  点分十进制 IPv4 地址，如 "192.168.1.1"
-- @return number|nil  32 位无符号整数，格式非法时返回 nil
local function ip_to_number(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    return a * 16777216 + b * 65536 + c * 256 + d
end

--- 将 32 位无符号整数还原为点分十进制 IPv4 字符串。
local function number_to_ip(n)
    if not n then return nil end
    local d = n % 256; n = (n - d) / 256
    local c2 = n % 256; n = (n - c2) / 256
    local b = n % 256; n = (n - b) / 256
    local a = n % 256
    return string.format("%d.%d.%d.%d", a, b, c2, d)
end

--- 将有符号整数结果转换为无符号 32 位数（修正 LuaJIT bit 库可能产生的负值）。
-- @param n  number  可能为负的整数
-- @return number  0..4294967295 范围内的无符号值
local function to_u32(n)
    if n < 0 then
        return n + 0x100000000
    end
    return n
end

--- 无符号 32 位按位与（bit.band 结果可能为负，此函数保证返回非负值）。
-- @param a  number
-- @param b  number
-- @return number
local function band32(a, b)
    return to_u32(bit.band(a, b))
end

--- 根据网关/掩码和 DHCP 起始偏移量计算 DHCP 范围的起止 IP。
-- 偏移量相对于网络地址（如 start=100 表示 x.x.x.100）。
-- @param gateway  string  网关 IP
-- @param netmask  string  子网掩码
-- @param start    number  起始偏移量（相对网络地址）
-- @param limit    number  地址数量
-- @return string|nil, string|nil  起始 IP 和结束 IP
local function dhcp_offset_to_ips(gateway, netmask, start, limit)
    local gw_n = ip_to_number(gateway)
    local nm_n = ip_to_number(netmask)
    if not gw_n or not nm_n then return nil, nil end
    local net_addr = band32(gw_n, nm_n)
    return number_to_ip(net_addr + start), number_to_ip(net_addr + start + limit - 1)
end

--- 将绝对 IP 地址转换为相对于网络地址的 DHCP 偏移量。
-- 偏移量 < 1（即网络地址）视为无效，返回 nil。
-- @param ip       string  目标 IP
-- @param gateway  string  网关 IP（用于确定网络基址）
-- @param netmask  string  子网掩码
-- @return number|nil  偏移量，无效时返回 nil
local function ip_to_dhcp_offset(ip, gateway, netmask)
    local ip_n = ip_to_number(ip)
    local gw_n = ip_to_number(gateway)
    local nm_n = ip_to_number(netmask)
    if not ip_n or not gw_n or not nm_n then return nil end
    local network_addr = band32(gw_n, nm_n)
    local offset = ip_n - network_addr
    -- 允许偏移为 1（即 x.x.x.1）作为有效主机地址；仅 offset < 1 视为无效（网络地址）
    if offset < 1 then return nil end
    return offset
end

--- 根据起止 IP 计算 DHCP 地址池的 limit（地址数量）。
-- @param start_ip  string  起始 IP
-- @param end_ip    string  结束 IP
-- @param gateway   string  网关 IP
-- @param netmask   string  子网掩码
-- @return number|nil  地址数量，非法时返回 nil
local function calc_dhcp_limit(start_ip, end_ip, gateway, netmask)
    local start_offset = ip_to_dhcp_offset(start_ip, gateway, netmask)
    local end_offset = ip_to_dhcp_offset(end_ip, gateway, netmask)
    if not start_offset or not end_offset then return nil end
    if end_offset < start_offset then return nil end
    return end_offset - start_offset + 1
end

--- 判断 IP 是否属于 RFC 1918 私有地址段（10/8、172.16/12、192.168/16）。
-- @param ip  string  IPv4 地址
-- @return boolean
local function is_private_ip(ip)
    local parts = { ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)") }
    if #parts ~= 4 then return false end
    local b1, b2 = tonumber(parts[1]), tonumber(parts[2])
    if b1 == 10 then return true end
    if b1 == 172 and b2 >= 16 and b2 <= 31 then return true end
    if b1 == 192 and b2 == 168 then return true end
    return false
end

--- 将 CIDR 前缀长度转换为点分十进制掩码字符串。
-- @param prefix  number  前缀长度（1-32）
-- @return string|nil  掩码字符串，非法时返回 nil
local function prefix_to_netmask(prefix)
    prefix = tonumber(prefix)
    if not prefix or prefix < 1 or prefix > 32 then return nil end
    return number_to_ip(0xFFFFFFFF - (2 ^ (32 - prefix) - 1))
end

--- 检查两个子网是否存在重叠（取较小的公共掩码后比较网络地址）。
-- @param ip1    string  子网 1 的 IP（通常为网关）
-- @param mask1  string  子网 1 的掩码
-- @param ip2    string  子网 2 的 IP
-- @param mask2  string  子网 2 的掩码
-- @return boolean  true 表示存在重叠
local function network_overlap(ip1, mask1, ip2, mask2)
    local n1 = ip_to_number(ip1)
    local n2 = ip_to_number(ip2)
    local m1 = ip_to_number(mask1)
    local m2 = ip_to_number(mask2)
    if not n1 or not n2 or not m1 or not m2 then return false end
    local common_mask = m1 > m2 and m2 or m1
    return band32(n1, common_mask) == band32(n2, common_mask)
end

--- 验证 DHCP 起止 IP 是否合法：均在子网内、不是网络/广播地址（不禁止池内包含网关/接口 IP）。
-- @param start_ip  string  DHCP 起始 IP
-- @param end_ip    string  DHCP 结束 IP
-- @param gateway   string  用于确定子网边界的参考 IP（通常为接口地址）
-- @param netmask   string  子网掩码
-- @return boolean, string?  合法返回 true；非法返回 false 及错误描述
local function validate_dhcp_range(start_ip, end_ip, gateway, netmask)
    local start_n = ip_to_number(start_ip)
    local end_n = ip_to_number(end_ip)
    local gw_n = ip_to_number(gateway)
    local nm_n = ip_to_number(netmask)
    if not start_n or not end_n or not gw_n or not nm_n then
        return false, "invalid IP address"
    end
    local network_addr = band32(gw_n, nm_n)
    local broadcast = to_u32(bit.bor(network_addr, to_u32(bit.band(bit.bnot(nm_n), 0xFFFFFFFF))))
    if start_n <= network_addr or start_n >= broadcast then
        return false, "dhcp_start_ip is network/broadcast address"
    end
    if end_n <= network_addr or end_n >= broadcast then
        return false, "dhcp_end_ip is network/broadcast address"
    end
    if start_n > end_n then
        return false, "dhcp_start_ip must <= dhcp_end_ip"
    end
    if start_n <= gw_n and gw_n <= end_n then
        return false, "dhcp range must not include interface IP"
    end
    return true
end

--- RPC 字段是否算“有传值”（nil、空串、仅空白视为未传，避免前端关 DHCP 仍带 "" 触发半套 IP 校验）。
local function rpc_dhcp_field_present(v)
    if v == nil then return false end
    if type(v) == "string" and v:match("^%s*$") then return false end
    return true
end

--- 从 RPC 请求参数中解析 DHCP 范围，支持两种输入模式：
--   模式 A（IP 对）：dhcp_start_ip + dhcp_end_ip
--   模式 B（偏移对）：dhcp_start + dhcp_limit
-- 两种模式不能混用；任一模式只提供一半参数也视为错误。
-- 若请求中未携带任何 DHCP 参数，返回 nil, nil（调用方应使用现有配置或默认值）。
-- @param params   table   RPC 请求参数表
-- @param gateway  string  当前子网网关（用于换算和验证）
-- @param netmask  string  当前子网掩码
-- @return number|nil, number|nil, string|nil  start 偏移, limit 数量, 错误信息
local function parse_dhcp_range_params(params, gateway, netmask)
    local has_ip_range = rpc_dhcp_field_present(params.dhcp_start_ip) or rpc_dhcp_field_present(params.dhcp_end_ip)
    local has_offset_range = rpc_dhcp_field_present(params.dhcp_start) or rpc_dhcp_field_present(params.dhcp_limit)

    if has_ip_range and has_offset_range then
        return nil, nil, "cannot mix dhcp_start_ip/dhcp_end_ip with dhcp_start/dhcp_limit"
    end

    if has_ip_range or has_offset_range then
        -- 不可调用后面的 local validate_gateway（此处在其定义之前，会变成全局 nil）
        if not gateway or not validator.ip4addr(gateway) or not is_private_ip(gateway) then
            return nil, nil, "interface IP (gateway) required for DHCP pool"
        end
    end

    if has_ip_range then
        if not (params.dhcp_start_ip and params.dhcp_end_ip) then
            return nil, nil, "both dhcp_start_ip and dhcp_end_ip are required"
        end
        local ok, err = validate_dhcp_range(params.dhcp_start_ip, params.dhcp_end_ip, gateway, netmask)
        if not ok then return nil, nil, err end
        local start = ip_to_dhcp_offset(params.dhcp_start_ip, gateway, netmask)
        local limit = calc_dhcp_limit(params.dhcp_start_ip, params.dhcp_end_ip, gateway, netmask)
        if not start or not limit then
            return nil, nil, "failed to calculate DHCP range"
        end
        return start, limit
    end

    if has_offset_range then
        if params.dhcp_start == nil or params.dhcp_limit == nil then
            return nil, nil, "both dhcp_start and dhcp_limit are required"
        end
        local start = tonumber(params.dhcp_start)
        local limit = tonumber(params.dhcp_limit)
        if not start or not limit then
            return nil, nil, "invalid dhcp_start or dhcp_limit"
        end
        start = math.floor(start)
        limit = math.floor(limit)
        if start < 1 or limit < 1 then
            return nil, nil, "invalid dhcp_start or dhcp_limit"
        end

        local start_ip, end_ip = dhcp_offset_to_ips(gateway, netmask, start, limit)
        if not start_ip or not end_ip then
            return nil, nil, "failed to calculate DHCP range"
        end
        local ok, err = validate_dhcp_range(start_ip, end_ip, gateway, netmask)
        if not ok then return nil, nil, err end
        return start, limit
    end

    return nil, nil
end


--- 判断网络名称是否属于固定子网（lan / guest / iot）。
-- @param network  string
-- @return boolean
local function is_fixed_subnet(network)
    for _, name in ipairs(FIXED_SUBNETS) do
        if name == network then return true end
    end
    return false
end

--- 规范化网络接口状态字符串：只返回 "up" 或 "down"。
-- @param state  string
-- @return string
local function normalize_state(state)
    if state == "up" then return "up" end
    return "down"
end

--- 规范化 DHCP 租赁时长为标准格式字符串：
--   字符串格式: 若已带单位后缀（s/m/h/d）则直接返回；超大整数试转换。
--   数字: <= 0 返回 "12h"；副分钟并可整除 60 则为 h 单位；其余为 m 单位。
--   nil: 返回 nil（让调用方秘决是否覆盖）。
-- @param val  string|number|nil
-- @return string|nil
local function normalize_leasetime(val)
    if val == nil then return nil end
    if type(val) == "string" then
        if val:match("^%d+[smhd]$") then return val end
        local num = tonumber(val)
        if num then val = num else return "12h" end
    end
    if type(val) == "number" then
        if val <= 0 then return "12h" end
        if val >= 60 and val % 60 == 0 then
            return tostring(val / 60) .. "h"
        else
            return tostring(val) .. "m"
        end
    end
    return "12h"
end


--- 返回指定网络对应的桥设备名称。
-- lan -> br-lan，guest -> br-guest，iot -> br-iot，vlanN -> br-vlanN。
-- @param network  string  UCI 网络名（lan / guest / iot / vlan<id>）
-- @return string|nil
local function get_bridge_for_network(network)
    if network == "lan" then return "br-lan" end
    if network == "guest" then return "br-guest" end
    if network == "iot" then return "br-iot" end
    local vid = network:match("^vlan(%d+)$")
    if vid then return "br-vlan" .. vid end
    return nil
end

--- 根据 VLAN ID 返回自定义子网的 UCI 接口名称（vlan<id>）。
-- @param vlan_id  number
-- @return string
local function get_network_name_for_vlan(vlan_id)
    return "vlan" .. tostring(vlan_id)
end

--- 返回自定义子网对应的独立桥名（br-vlan<id>）。
-- @param vlan_id  number
-- @return string
local function get_bridge_for_custom(vlan_id)
    return "br-vlan" .. tostring(vlan_id)
end


--- 读取子网的显示名称。
-- 对于固定子网，若 UCI 未存 display_name 则回落到内置映射值。
-- 对于自定义子网，回落到接口名称。
-- @param c        uci.cursor
-- @param network  string
-- @return string
local function get_display_name(c, network)
    if DISPLAY_NAME_MAP[network] then
        return c:get("network", network, "display_name") or DISPLAY_NAME_MAP[network]
    end
    return c:get("network", network, "display_name") or network
end

--- 返回子网 Wi-Fi 接口在 UI 上的显示名称。
-- 固定子网使用 WIFI_IFACE_NAME 映射；自定义子网回落到 get_display_name。
-- @param c        uci.cursor
-- @param network  string
-- @return string
local function get_wifi_iface_display_name(c, network)
    if WIFI_IFACE_NAME[network] then
        return WIFI_IFACE_NAME[network]
    end
    return get_display_name(c, network)
end

--- 将显示名称解析为 UCI 网络接口名称。
-- 优先查 NETWORK_MAP（"main"->"lan" 等），再遍历固定子网 display_name（支持中文自定义名），
-- 最后遍历自定义子网。找不到返回 nil。
-- @param c             uci.cursor
-- @param display_name  string
-- @return string|nil  UCI 接口名称
local function resolve_display_name_to_network(c, display_name)
    if NETWORK_MAP[display_name] then
        return NETWORK_MAP[display_name]
    end

    -- 支持固定子网使用自定义 display_name（含中文）
    for _, net in ipairs(FIXED_SUBNETS) do
        if get_display_name(c, net) == display_name then
            return net
        end
    end

    local found = nil
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name:match("^vlan%d+$") then
            local dn = s.display_name or name
            if dn == display_name then
                found = name
                return false
            end
        end
    end)
    return found
end

--- 根据 IP 地址推断其所属的子网网络。
-- 遍历所有子网，匹配且唯一时返回网络名；匹配到多个或未匹配时返回 nil。
-- 用于静态绑定中省略 display_name 时按 IP 自动推断子网。
-- @param c   uci.cursor
-- @param ip  string  目标 IP 地址
-- @return string|nil  UCI 接口名称
local function resolve_network_by_ip(c, ip)
    local ip_num = ip_to_number(ip)
    if not ip_num then return nil end

    local matched = nil
    local matched_count = 0

    local function try_match(net)
        local gw = c:get("network", net, "ipaddr")
        local nm = c:get("network", net, "netmask")
        local gw_num = gw and ip_to_number(gw) or nil
        local nm_num = nm and ip_to_number(nm) or nil
        if not gw_num or not nm_num then return end

        if band32(gw_num, nm_num) == band32(ip_num, nm_num) then
            matched = net
            matched_count = matched_count + 1
        end
    end

    for _, net in ipairs(FIXED_SUBNETS) do
        try_match(net)
    end

    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name and name:match("^vlan%d+$") then
            try_match(name)
        end
    end)

    if matched_count == 1 then
        return matched
    end
    return nil
end

--- 检查指定显示名称在所有子网中是否已存在（可排除某个子网用于更新场景）。
-- @param c                uci.cursor
-- @param display_name     string
-- @param exclude_network  string|nil  排除的网络名
-- @return boolean
local function display_name_exists(c, display_name, exclude_network)
    for _, net in ipairs(FIXED_SUBNETS) do
        if net ~= exclude_network then
            if get_display_name(c, net) == display_name then return true end
        end
    end
    local exists = false
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name:match("^vlan%d+$") and name ~= exclude_network then
            local dn = s.display_name or name
            if dn == display_name then
                exists = true
                return false
            end
        end
    end)
    return exists
end


--- 获取指定网络接口的 VLAN ID。
-- lan 固定返回 1；guest/iot 优先读 UCI vlan_id 字段，否则回落到 DEFAULT_SUBNET_CFG；
-- 自定义子网优先读 UCI vlan_id，否则从接口名 vlanN 解析。
-- @param c        uci.cursor
-- @param network  string
-- @return number|nil
local function get_vlan_id_for_network(c, network)
    if network == "lan" then return 1 end
    local defaults = DEFAULT_SUBNET_CFG[network]
    if defaults then
        local uci_vid = c:get("network", network, "vlan_id")
        if uci_vid then return tonumber(uci_vid) end
        return defaults.vlan_id
    end
    local uci_vid = c:get("network", network, "vlan_id")
    if uci_vid then return tonumber(uci_vid) end
    local vid = network:match("^vlan(%d+)$")
    return vid and tonumber(vid) or nil
end

--- 返回当前所有子网的网络名称列表（固定 + 自定义）。
-- 顺序：先固定子网，再按 UCI 顺序追加自定义 vlanN。
-- @param c  uci.cursor
-- @return table  网络名称字符串数组
local function get_all_subnet_networks(c)
    local subnets = {}
    for _, name in ipairs(FIXED_SUBNETS) do
        if c:get("network", name) then
            subnets[#subnets + 1] = name
        end
    end
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name:match("^vlan%d+$") then
            subnets[#subnets + 1] = name
        end
    end)
    return subnets
end

--- 返回当前自定义子网（vlanN）的数量。
-- @param c  uci.cursor
-- @return number
local function count_custom_subnets(c)
    local count = 0
    c:foreach("network", "interface", function(s)
        if s[".name"]:match("^vlan%d+$") then
            count = count + 1
        end
    end)
    return count
end


--- 检查 VLAN ID 是否在允许范围内（VLAN_ID_MIN..VLAN_ID_MAX）。
-- @param vlan_id  number
-- @return boolean
local function check_vlan_id_range(vlan_id)
    return type(vlan_id) == "number" and vlan_id == math.floor(vlan_id) and vlan_id >= VLAN_ID_MIN and vlan_id <= VLAN_ID_MAX
end

--- 检查 VLAN ID 是否与现有子网或 WAN 配置冲突。
-- @param c               uci.cursor
-- @param vlan_id         number
-- @param exclude_network string|nil  更新场景下排除自身
-- @return boolean
local function check_vlan_id_conflict(c, vlan_id, exclude_network)
    local all = get_all_subnet_networks(c)
    for _, net in ipairs(all) do
        if net ~= exclude_network then
            if get_vlan_id_for_network(c, net) == vlan_id then return true end
        end
    end
    local wan_vlanid = c:get("glconfig", "general", "wan")
    if wan_vlanid and tonumber(wan_vlanid) == vlan_id then return true end
    local sw_vlanid = c:get("glconfig", "general", "secondwan")
    if sw_vlanid and tonumber(sw_vlanid) == vlan_id then return true end
    return false
end

--- 组装用于 ubus network.interface.<name> 的 GL WAN 逻辑接口名列表（与 get_wan_info 一致）。
-- 含中继场景下的 wwan、热点 tethering、USB 与蜂窝 modem_* 等，避免仅检查 wan/secondwan 漏检。
-- @param c uci.cursor
-- @return table 接口名字符串数组
local function build_wan_logical_interface_list(c)
    local wan_array = { "wan", "wwan", "tethering", "secondwan", "usbwan" }
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name:sub(1, 6) == "modem_" then
            local proto = c:get("network", name, "proto")
            if proto and proto ~= "dhcpv6" then
                if proto == "qcm" or proto == "qmi" then
                    wan_array[#wan_array + 1] = name .. "_4"
                else
                    wan_array[#wan_array + 1] = name
                end
            end
        end
    end)
    return wan_array
end

--- 检查新子网是否与已有子网或 WAN 地址段冲突。
-- 已禁用（disabled=1）的子网跳过不参与冲突检查。
-- WAN 侧与 get_wan_info 对齐：含 wwan（中继）、tethering、usbwan、modem_* 等已获 IPv4 的上行。
-- @param c               uci.cursor
-- @param gateway         string
-- @param netmask         string
-- @param exclude_network string|nil
-- @return boolean, string|nil  是否冲突、冲突对象（lan/guest/iot/vlanN/wan）
local function check_subnet_conflict(c, gateway, netmask, exclude_network)
    if not gateway or not netmask then return false end
    local all = get_all_subnet_networks(c)
    for _, net in ipairs(all) do
        if net ~= exclude_network then
            local other_gw = c:get("network", net, "ipaddr")
            if other_gw and other_gw ~= "" and other_gw == gateway and c:get("network", net, "disabled") ~= "1" then
                return true, net
            end
            local other_nm = c:get("network", net, "netmask")
            if other_gw and other_nm then
                local is_disabled = (c:get("network", net, "disabled") == "1")
                if not is_disabled then
                    if network_overlap(gateway, netmask, other_gw, other_nm) then
                        return true, net
                    end
                end
            end
        end
    end

    for _, wan_iface in ipairs(build_wan_logical_interface_list(c)) do
        local wan_status = ubus.call("network.interface." .. wan_iface, "status") or {}
        if wan_status["ipv4-address"] and wan_status["ipv4-address"][1] then
            local wa = wan_status["ipv4-address"][1]
            local wan_mask = prefix_to_netmask(wa.mask) or "255.255.255.0"
            if network_overlap(gateway, netmask, wa.address, wan_mask) then
                return true, "wan"
            end
        end
    end
    return false
end

local function subnet_conflict_rpc_error(c, conflict_network)
    if conflict_network == "wan" then
        return rpc_error(ERR_WAN_IP_CONFLICT, "conflict with wan ip")
    elseif conflict_network == "lan" then
        return rpc_error(ERR_LAN_IP_CONFLICT, "conflict with lan ip")
    elseif conflict_network == "guest" then
        return rpc_error(ERR_GUEST_IP_CONFLICT, "conflict with guest ip")
    elseif conflict_network == "iot" then
        return rpc_error(ERR_IOT_IP_CONFLICT, "conflict with iot ip")
    elseif conflict_network and conflict_network ~= "" then
        return rpc_error(ERR_SUBNET_CONFLICT, "conflict with " .. get_display_name(c, conflict_network) .. " ip")
    end
    return rpc_error(ERR_SUBNET_CONFLICT, "subnet conflict")
end

--- 验证网关 IP 是否合法：必须是有效 IPv4 且属于私有地址。
-- @param gateway  string
-- @return boolean
local function validate_gateway(gateway)
    if not gateway or not validator.ip4addr(gateway) then return false end
    return is_private_ip(gateway)
end

--- 验证子网掩码是否为合法的连续掩码（/1 ~ /30）。
-- 先用 validator.netmask4 做格式校验，再用位运算确认高位连续全 1、低位全 0。
-- @param netmask  string
-- @return boolean
local function validate_netmask(netmask)
    if not netmask or not validator.netmask4(netmask) then return false end
    local n = ip_to_number(netmask)
    if not n or n == 0 then return false end
    local inv = 0xFFFFFFFF - n
    if inv >= 0xFFFFFFFF then return false end
    return bit.band(inv, inv + 1) == 0
end

--- 检查当前是否激活了 TAP S2S 模式。
-- 若激活，返回对应错误响应；否则返回 nil。
-- @param c  uci.cursor
-- @return table|nil  err_code 20016008 的错误响应，或 nil
local function check_tap_s2s_blocked(c)
    local config_name = c:get("network", "ovpnclient", "config")
    local client_mode = config_name and c:get("ovpnclient", config_name, "mode") or ""
    if client_mode == "tap-s2s" then
        local tap_s2s_disabled = c:get("network", "ovpnclient", "disabled") or "1"
        if tap_s2s_disabled == "0" then
            return rpc_error(20016008, "function does not work because TAP-S2S Mode is enabled")
        end
    end
    return nil
end


--- 从 UCI network.device 配置中读取指定桥设备的端口列表。
-- 支持含空格的多元素字符串（拆半后添加）。
-- @param c       uci.cursor
-- @param bridge  string  桥设备名（如 "br-lan"）
-- @return table  端口名称字符串数组
local function get_bridge_ports_from_uci(c, bridge)
    local ports = {}
    c:foreach("network", "device", function(s)
        if s.name == bridge and s.ports then
            local p = s.ports
            if type(p) == "string" then p = { p } end
            for _, v in ipairs(p) do
                for token in tostring(v):gmatch("%S+") do
                    ports[#ports + 1] = token
                end
            end
        end
    end)
    return ports
end

--- 通过 /sys/class/net/<bridge>/brif/ 目录实时读取桥端口列表（运行时回落）。
-- 将桥名进行安全校验，防止路径注入。
-- @param bridge  string
-- @return table  端口名串数组
local function get_bridge_ports_runtime(bridge)
    local ports = {}
    if not bridge or type(bridge) ~= "string" or bridge == "" then return ports end
    if not bridge:match("^[%w%-]+$") then return ports end
    local brif_dir = "/sys/class/net/" .. bridge .. "/brif"
    local f = io.popen("ls " .. brif_dir .. " 2>/dev/null")
    if f then
        for name in f:lines() do
            if name ~= "" then
                ports[#ports + 1] = name
            end
        end
        f:close()
    end
    return ports
end

--- 获取桥端口列表：优先读 UCI，若为空则读 /sys/class/net/<bridge>/brif。
-- @param c       uci.cursor
-- @param bridge  string
-- @return table
local function get_bridge_ports(c, bridge)
    local uci_ports = get_bridge_ports_from_uci(c, bridge)
    if #uci_ports > 0 then return uci_ports end
    return get_bridge_ports_runtime(bridge)
end

--- 展示/链路状态：识别 ethX.N、lanX.N、lan.N、wan.N 的父口（含 wan，供 ifaces 与 carrier 回退）。
-- @param ifname  string
-- @return string|nil
local function vlan_subif_parent_display(ifname)
    if type(ifname) ~= "string" then return nil end
    local base = ifname:match("^([^%.]+)%.(%d+)$")
    if not base then return nil end
    if base:match("^eth%d+$") or base:match("^lan%d+$") or base == "lan" or base == "wan" then
        return base
    end
    return nil
end

--- 子网清理/迁移：仅识别 ethX.N、lanX.N、lan.N，**不含 wan.N**（避免误删 glconfig.general.wan 对应的 WAN VLAN 设备）。
-- @param ifname  string
-- @return string|nil
local function vlan_subif_parent_purge(ifname)
    if type(ifname) ~= "string" then return nil end
    local base = ifname:match("^([^%.]+)%.(%d+)$")
    if not base then return nil end
    if base:match("^eth%d+$") or base:match("^lan%d+$") or base == "lan" then
        return base
    end
    return nil
end

--- 清理路径用 VLAN ID 解析（范围同 vlan_subif_parent_purge）。
-- @param ifname  string
-- @return number|nil
local function vlan_subif_vid_purge(ifname)
    if type(ifname) ~= "string" then return nil end
    if not vlan_subif_parent_purge(ifname) then return nil end
    local vid = ifname:match("^[^%.]+%.(%d+)$")
    return vid and tonumber(vid) or nil
end

--- 读取有线端口的链路状态：依次尝试 operstate 、carrier 、父接口 carrier，均失败返回 "down"。
-- @param ifname  string  接口名
-- @return string  "up" 或 "down"
local function get_wired_link_state_fallback(ifname)
    if not ifname or ifname == "" then return "down" end
    local path_base = "/sys/class/net/" .. tostring(ifname)
    local f = io.open(path_base .. "/operstate", "r")
    if f then
        local state = f:read("*l")
        f:close()
        if state == "up" then return "up" end
        if state == "down" then return "down" end
    end
    f = io.open(path_base .. "/carrier", "r")
    if f then
        local carrier = f:read("*l")
        f:close()
        if carrier == "1" then return "up" end
        if carrier == "0" then return "down" end
    end
    local base = vlan_subif_parent_display(ifname)
    if base then
        f = io.open("/sys/class/net/" .. base .. "/carrier", "r")
        if f then
            local carrier = f:read("*l")
            f:close()
            if carrier == "1" then return "up" end
        end
    end
    return "down"
end

--- 返回子网目前绑定的有线端口列表和 WiFi 接口列表。
-- 有线端口通过 get_bridge_ports 获取；WiFi 接口遍历 wireless UCI 表。
-- @param c        uci.cursor
-- @param network  string
-- @return table  { ports: string[], wifi: string[] }
local function get_subnet_bindings(c, network)
    local bindings = { ports = {}, wifi = {} }
    local bridge = get_bridge_for_network(network)
    if not bridge then return bindings end
    bindings.ports = get_bridge_ports(c, bridge)
    c:foreach("wireless", "wifi-iface", function(s)
        if s.network == network then
            bindings.wifi[#bindings.wifi + 1] = s[".name"]
        end
    end)
    return bindings
end


local function read_tagged_vlans_from_map(c, sid)
    local tagged = {}
    if c.get_list then
        local list = c:get_list("eth_ports_config_map", sid, "tagged_vlans")
        if type(list) == "table" then
            for _, v in ipairs(list) do
                -- 拆分可能的逗号分隔字符串
                if type(v) == "string" then
                    for token in v:gmatch("[^,%s]+") do
                        tagged[#tagged + 1] = token
                    end
                end
            end
        end
    end
    if #tagged == 0 then
        local raw = c:get("eth_ports_config_map", sid, "tagged_vlans")
        if type(raw) == "table" then
            for _, v in ipairs(raw) do
                if type(v) == "string" then
                    for token in v:gmatch("[^,%s]+") do
                        tagged[#tagged + 1] = token
                    end
                end
            end
        elseif type(raw) == "string" and raw ~= "" then
            for token in raw:gmatch("[^,%s]+") do
                tagged[#tagged + 1] = token
            end
        end
    end
    local filtered = {}
    for _, v in ipairs(tagged) do
        if type(v) == "string" and v:match("^%d+$") then
            filtered[#filtered + 1] = v
        end
    end
    return filtered
end

--- 写回 eth_ports_config_map.tagged_vlans，统一为单行 option 'a b c'（先 delete，避免残留多条 list）。
-- @param c          uci.cursor
-- @param sid        string  port section id
-- @param id_strings table  VLAN 号字符串数组，如 { "9", "10" }
local function set_tagged_vlans_option(c, sid, id_strings)
    c:delete("eth_ports_config_map", sid, "tagged_vlans")
    if not id_strings or #id_strings == 0 then
        return
    end
    c:set("eth_ports_config_map", sid, "tagged_vlans", table.concat(id_strings, " "))
end

--- 从 eth_ports_config_map 中查询属于指定 VLAN ID 的网口名称列表。
-- 同时检查 pvid 和 tagged_vlans。只处理 VLAN_ID_MIN..VLAN_ID_MAX 范围内的 VLAN。
-- @param vlan_id  number
-- @return table  端口名字符串数组
local function get_ports_for_subnet_from_eth_ports_config_map(vlan_id)
    if not vlan_id or vlan_id < VLAN_ID_MIN or vlan_id > VLAN_ID_MAX then return {} end
    local vid_num = tonumber(vlan_id)
    if not vid_num then return {} end
    local ports = {}
    pcall(function()
        local c = uci.cursor()
        c:foreach("eth_ports_config_map", "port", function(s)
            local sid = s[".name"]
            local name = c:get("eth_ports_config_map", sid, "name") or s.name or sid
            local pvid = tonumber(c:get("eth_ports_config_map", sid, "pvid"))
            if pvid == vid_num then
                ports[#ports + 1] = name
                return
            end
            local tagged = read_tagged_vlans_from_map(c, sid)
            for _, v in ipairs(tagged) do
                if tonumber(v) == vid_num then
                    ports[#ports + 1] = name
                    return
                end
            end
        end)
        c:close()
    end)
    return ports
end

--- 检查自定义子网是否仍绑定有任何接口（eth_ports_config_map + 桥 ports + Wi-Fi）。
-- @param c        uci.cursor
-- @param network  string  必须为 vlanN 格式
-- @return boolean, table  是否有绑定; { ports: string[], wifi: string[] }
local function custom_subnet_has_interfaces(c, network)
    local vid = network:match("^vlan(%d+)$")
    local vid_num = vid and tonumber(vid)
    if not vid_num or vid_num < VLAN_ID_MIN or vid_num > VLAN_ID_MAX then
        return false, {}
    end
    local eth_ports = get_ports_for_subnet_from_eth_ports_config_map(vid_num)
    local bindings = get_subnet_bindings(c, network)
    local has_any = #eth_ports > 0 or #bindings.ports > 0 or #bindings.wifi > 0
    if not has_any then return false, {} end
    local all_ports, seen = {}, {}
    for _, p in ipairs(eth_ports) do
        if not seen[p] then seen[p] = true; all_ports[#all_ports + 1] = p end
    end
    for _, p in ipairs(bindings.ports) do
        if not seen[p] then seen[p] = true; all_ports[#all_ports + 1] = p end
    end
    return true, { ports = all_ports, wifi = bindings.wifi }
end

--- 列出 /sys/class/net/ 下所有 ethX.Y 格式的 GSW VLAN 子接口，按名升序排列。
-- @return table  接口名字符串数组
local function get_all_gsw_vlan_ifaces()
    local list = {}
    local f = io.popen("ls /sys/class/net/ 2>/dev/null")
    if f then
        for name in f:lines() do
            if name:match("^eth%d+%.%d+$") then
                list[#list + 1] = name
            end
        end
        f:close()
    end
    table.sort(list)
    return list
end

--- Return true when an interface is a frontend-hidden VLAN subinterface.
-- Only ethX.<vid> and lanX.<vid> with vid > VLAN_ID_MAX are hidden.
-- @param name any
-- @return boolean
local function is_hidden_vlan_iface_for_frontend(name)
    if type(name) ~= "string" or name == "" then return false end
    local vid = name:match("^eth%d+%.(%d+)$") or name:match("^lan%d+%.(%d+)$")
    vid = vid and tonumber(vid)
    return vid ~= nil and vid > VLAN_ID_MAX
end

--- Filter bindings for get_subnets display without changing source config.
-- @param bindings table
-- @return table
local function filter_bindings_for_frontend(bindings)
    local filtered = { ports = {}, wifi = (bindings and bindings.wifi) or {} }
    for _, p in ipairs((bindings and bindings.ports) or {}) do
        if not is_hidden_vlan_iface_for_frontend(p) then
            filtered.ports[#filtered.ports + 1] = p
        end
    end
    return filtered
end

--- 获取 GSW 精简端口信息列表（用于状态查询）。
-- 优先尝试 libcable.get_gsw_ports_for_status：若不可用则自行遍历 eth_ports_config_map。
-- @param c  uci.cursor
-- @return table  [{ name, port_group, port_num, switch, port_name }, ...]
local function get_gsw_ports_from_map(c)
    local ok, libcable = pcall(require, "libcable")
    if ok and libcable and libcable.get_gsw_ports_for_status then
        return libcable.get_gsw_ports_for_status()
    end
    local list = {}
    pcall(function()
        c:foreach("eth_ports_config_map", "port", function(s)
            if s.type ~= "gsw" then return end
            local sid = s[".name"]
            local port_num = tonumber(c:get("eth_ports_config_map", sid, "port"))
            if not port_num and sid then
                port_num = tonumber(sid:match("^port(%d+)$") or sid:match("^lan(%d+)$"))
            end
            if not port_num then
                port_num = tonumber(c:get("eth_ports_config_map", sid, "port_group"))
            end
            if not port_num then return end
            local name = s.silk or s.name or sid
            local port_group = c:get("eth_ports_config_map", sid, "port_group") or tostring(port_num)
            local dev = c:get("eth_ports_config_map", sid, "switch")
            list[#list + 1] = {
                name = name,
                port_group = port_group,
                port_num = port_num,
                switch = dev or "switch1",
                port_name = s.name or sid,
            }
        end)
    end)
    table.sort(list, function(a, b) return a.port_num < b.port_num end)
    return list
end

--- 从 network.switch_vlan 配置中解析属于指定 VLAN ID 的物理端口号集合。
-- @param c        uci.cursor
-- @param vlan_id  number
-- @return table  { [port_num] = true, ... }
local function parse_phys_from_vlan_section(c, vlan_id)
    local phys = {}
    if not vlan_id or vlan_id < 1 then return phys end
    local vid_str = tostring(vlan_id)
    c:foreach("network", "switch_vlan", function(s)
        if s.vlan == vid_str then
            local ports_val = s.ports
            if ports_val then
                local str = type(ports_val) == "table" and table.concat(ports_val, " ") or tostring(ports_val)
                for token in str:gmatch("%S+") do
                    local num = token:match("^(%d+)")
                    if num then phys[tonumber(num)] = true end
                end
            end
        end
    end)
    return phys
end

--- 获取指定子网在交换机上对应的物理端口号集合。
-- 将 bridge ports 中的 ethX.Y 子接口、eth_ports_config_map GSW pvid/tagged 信息合并查询。
-- @param c        uci.cursor
-- @param bindings table  get_subnet_bindings 返回的绑定数据
-- @param vlan_id  number|nil  VLAN ID，为 nil 时仅从子接口推断
-- @return table  { [port_num] = true, ... }
local function get_phys_ports_for_subnet(c, bindings, vlan_id)
    local phys = {}
    for _, p in ipairs(bindings.ports) do
        local vid = vlan_subif_vid_purge(p)
        if vid then
            local from_section = parse_phys_from_vlan_section(c, tonumber(vid))
            for k in pairs(from_section) do phys[k] = true end
        end
    end

    -- trunk/access on GSW ports are represented in eth_ports_config_map by pvid/tagged_vlans.
    if vlan_id then
        local vid_num = tonumber(vlan_id)
        pcall(function()
            c:foreach("eth_ports_config_map", "port", function(s)
                if s.type ~= "gsw" then return end
                local sid = s[".name"]
                if not sid then return end

                local port_num = tonumber(c:get("eth_ports_config_map", sid, "port"))
                if not port_num and sid then
                    port_num = tonumber(sid:match("^port(%d+)$") or sid:match("^lan(%d+)$"))
                end
                if not port_num then
                    port_num = tonumber(c:get("eth_ports_config_map", sid, "port_group"))
                end
                if not port_num then return end

                local pvid = tonumber(c:get("eth_ports_config_map", sid, "pvid"))
                if pvid == vid_num then
                    phys[port_num] = true
                    return
                end

                local tagged = read_tagged_vlans_from_map(c, sid)
                for _, v in ipairs(tagged) do
                    if tonumber(v) == vid_num then
                        phys[port_num] = true
                        return
                    end
                end
            end)
        end)
    end

    if next(phys) == nil and vlan_id then
        phys = parse_phys_from_vlan_section(c, vlan_id)
    end
    return phys
end

--- eth_ports_config_map 节上的交换机物理口编号（与 switch_vlan / pvid 对齐）。
local function eth_map_phys_port_num(c, sid)
    local n = tonumber(c:get("eth_ports_config_map", sid, "port"))
    if not n and sid then
        n = tonumber(sid:match("^port(%d+)$") or sid:match("^lan(%d+)$"))
    end
    if not n then
        n = tonumber(c:get("eth_ports_config_map", sid, "port_group"))
    end
    return n
end

--- 从 GSW 节解析 swconfig 设备名与端口索引；`port` 非纯数字时尝试 libcable 映射。
local function resolve_swconfig_port_for_gsw_section(c, sid)
    local switch_dev = c:get("eth_ports_config_map", sid, "switch")
    if not switch_dev or switch_dev == "" or not switch_dev:match("^[%w_%-]+$") then
        return nil, nil
    end
    local raw = c:get("eth_ports_config_map", sid, "port")
    if raw and tostring(raw):match("^%d+$") then
        return switch_dev, tonumber(raw)
    end
    local nm = c:get("eth_ports_config_map", sid, "name")
    local ok_lc, libcable = pcall(require, "libcable")
    if not ok_lc or not libcable or not libcable.get_ports_list_from_map or not nm or nm == "" then
        return nil, nil
    end
    for _, info in ipairs(libcable.get_ports_list_from_map()) do
        if info.type == "gsw" and info.name == nm and info.switch and info.switch ~= ""
            and info.port and tostring(info.port):match("^%d+$") then
            return tostring(info.switch), tonumber(info.port)
        end
    end
    return nil, nil
end

--- 子网对应的 GSW swconfig (switch, port) 列表（去重）；并补全 get_gsw_ports_from_map 里带默认 switch 的项。
local function collect_gsw_swconfig_targets(c, network)
    local out, seen = {}, {}
    local function add_target(sw, port)
        port = tonumber(port)
        if not sw or sw == "" or not port or port < 0 then return end
        local key = sw .. ":" .. tostring(port)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { switch = sw, port = port }
    end

    local vlan_id = get_vlan_id_for_network(c, network)
    local phys_set = get_phys_ports_for_subnet(c, get_subnet_bindings(c, network), vlan_id)
    if not next(phys_set) then return out end

    c:foreach("eth_ports_config_map", "port", function(s)
        if s.type ~= "gsw" then return end
        local sid = s[".name"]
        if not sid then return end
        local port_num = eth_map_phys_port_num(c, sid)
        if not port_num or not phys_set[port_num] then return end
        local swdev, swp = resolve_swconfig_port_for_gsw_section(c, sid)
        add_target(swdev, swp)
    end)

    local ok, gsw_list = pcall(get_gsw_ports_from_map, c)
    if ok and gsw_list then
        for _, gp in ipairs(gsw_list) do
            local pn = tonumber(gp.port_num)
            if pn and phys_set[pn] and gp.switch and gp.switch ~= "" then
                add_target(tostring(gp.switch), pn)
            end
        end
    end
    return out
end

local function sleep_reset_gsw()
    if ngx and ngx.sleep then
        ngx.sleep(1.0)
    else
        os.execute("sleep 1")
    end
end

local function swconfig_run(argv)
    os.execute(table.concat(argv, " ") .. " 2>/dev/null")
end

local function swconfig_set_port_disable(switch_dev, port_idx, disable)
    local pn = tonumber(port_idx)
    if not pn or pn < 0 then return end

    --裕泰微系列的switch 控制命令与标准不同，需要特殊处理
    if fs.access("/sys/module/ytswconfig") then
        local v = disable and "0" or "1"
        swconfig_run({
            "/sbin/swconfig", "dev", switch_dev, "port", tostring(pn), "set", "enable_port", v,
        })
    else
        local v = disable and "1" or "0"
        swconfig_run({
            "/sbin/swconfig", "dev", switch_dev, "port", tostring(pn), "set", "disable", v,
        })
    end
end

--- 对子网关联的 GSW 口执行 swconfig disable 抖动（与 gl_util / hardware 一致）。
-- @param c        uci.cursor
-- @param network  string  UCI 接口名
local function reset_gsw_ports(c, network)
    local targets = collect_gsw_swconfig_targets(c, network)
    if #targets == 0 then return end

    local by_switch = {}
    for _, t in ipairs(targets) do
        local plist = by_switch[t.switch]
        if not plist then
            plist = {}
            by_switch[t.switch] = plist
        end
        plist[#plist + 1] = t.port
    end
    for switch_dev, ports in pairs(by_switch) do
        for _, p in ipairs(ports) do
            swconfig_set_port_disable(switch_dev, p, true)
            sleep_reset_gsw()
            swconfig_set_port_disable(switch_dev, p, false)
            sleep_reset_gsw()
        end
    end
end


--- 在 dhcp UCI 配置中查找与指定网络对应的 DHCP 段名。
-- 优先查同名 section，再遍历 interface 字段匹配。
-- @param c        uci.cursor
-- @param network  string
-- @return string|nil  section 名称
local function find_dhcp_section(c, network)
    if c:get("dhcp", network) then
        return network
    end
    local found = nil
    c:foreach("dhcp", "dhcp", function(s)
        if s.interface == network then
            found = s[".name"]
            return false
        end
    end)
    return found
end

--- 读取子网的 DHCP 自定义选项：默认网关（option 3）、DNS（option 6）、LPR（option 9）。
-- 与 lan.get_dhcp_option / get_config_list 语义对齐：option 3 可与 network.ipaddr 不同。
-- @param c        uci.cursor
-- @param network  string
-- @return table, table, string  dns 列表，lpr 列表，dhcp_option 中的网关（无则为 ""）
local function get_dhcp_options(c, network)
    local dhcp_sid = find_dhcp_section(c, network)
    if not dhcp_sid then return {}, {}, "" end

    local dns = {}
    local lpr = {}
    local dhcp_gateway = ""

    local option_info = c:get("dhcp", dhcp_sid, "dhcp_option") or {}
    if type(option_info) == "string" then option_info = { option_info } end
    for _, v in ipairs(option_info) do
        local gw_str = v:match("^3,(.+)$")
        if gw_str then
            dhcp_gateway = gw_str
        end
        local dns_str = v:match("^6,(.+)$")
        if dns_str then
            for addr in dns_str:gmatch("[^,]+") do
                dns[#dns + 1] = addr
            end
        end
    end

    local force_info = c:get("dhcp", dhcp_sid, "dhcp_option_force") or {}
    if type(force_info) == "string" then force_info = { force_info } end
    for _, v in ipairs(force_info) do
        local lpr_str = v:match("^9,(.+)$")
        if lpr_str then
            for addr in lpr_str:gmatch("[^,]+") do
                lpr[#lpr + 1] = addr
            end
        end
    end

    return dns, lpr, dhcp_gateway
end

--- 写入扆/更新子网的 DHCP 配置，包括启用状态、地址池、租赁时长、DNS 和 LPR。
-- 若 DHCP section 不存在则自动创建。DNS/LPR 等于 nil 时不修改现有值。
-- @param c        uci.cursor
-- @param network  string
-- @param cfg      table  { dhcp_enable?, dhcp_start?, dhcp_limit?, leasetime?, dhcp_gateway?, dns?, lpr? }；dhcp_gateway 为 DHCP option 3，"" 表示删除该项
-- @return string|nil  校验失败时返回 "invalid dns" / "invalid lpr"（与 lan.set_config 对齐）
local function set_dhcp_config(c, network, cfg)
    local dhcp_sid = find_dhcp_section(c, network)
    if not dhcp_sid then
        c:set("dhcp", network, "dhcp")
        c:set("dhcp", network, "interface", network)
        dhcp_sid = network
    end

    if cfg.dhcp_enable ~= nil then
        if cfg.dhcp_enable then
            c:delete("dhcp", dhcp_sid, "ignore")
        else
            c:set("dhcp", dhcp_sid, "ignore", "1")
        end
    end

    if cfg.dhcp_start ~= nil then
        c:set("dhcp", dhcp_sid, "start", tostring(cfg.dhcp_start))
    end
    if cfg.dhcp_limit ~= nil then
        c:set("dhcp", dhcp_sid, "limit", tostring(cfg.dhcp_limit))
    end
    if cfg.leasetime ~= nil then
        c:set("dhcp", dhcp_sid, "leasetime", cfg.leasetime)
    end

    -- Router / default gateway (option 3)
    if cfg.dhcp_gateway ~= nil then
        local existing = c:get("dhcp", dhcp_sid, "dhcp_option") or {}
        if type(existing) == "string" then existing = { existing } end
        local kept = {}
        for _, v in ipairs(existing) do
            if not v:match("^3,") then
                kept[#kept + 1] = v
            end
        end
        if cfg.dhcp_gateway ~= "" then
            kept[#kept + 1] = "3," .. cfg.dhcp_gateway
        end
        if #kept > 0 then
            c:set("dhcp", dhcp_sid, "dhcp_option", kept)
        else
            c:delete("dhcp", dhcp_sid, "dhcp_option")
        end
    end

    -- DNS (option 6)
    if cfg.dns ~= nil then
        if type(cfg.dns) ~= "table" then
            return "invalid dns"
        end
        for _, addr in ipairs(cfg.dns) do
            if type(addr) == "string" and addr ~= "" and not validator.ip4addr(addr) then
                return "invalid dns"
            end
        end
        local existing = c:get("dhcp", dhcp_sid, "dhcp_option") or {}
        if type(existing) == "string" then existing = { existing } end
        local kept = {}
        for _, v in ipairs(existing) do
            if not v:match("^6,") then
                kept[#kept + 1] = v
            end
        end
        local valid_dns = {}
        for _, addr in ipairs(cfg.dns) do
            if type(addr) == "string" and addr ~= "" then
                valid_dns[#valid_dns + 1] = addr
            end
        end
        if #valid_dns > 0 then
            kept[#kept + 1] = "6," .. table.concat(valid_dns, ",")
        end
        if #kept > 0 then
            c:set("dhcp", dhcp_sid, "dhcp_option", kept)
        else
            c:delete("dhcp", dhcp_sid, "dhcp_option")
        end
    end

    -- LPR (option 9)
    if cfg.lpr ~= nil then
        if type(cfg.lpr) ~= "table" then
            return "invalid lpr"
        end
        for _, addr in ipairs(cfg.lpr) do
            if type(addr) == "string" and addr ~= "" and not validator.ip4addr(addr) then
                return "invalid lpr"
            end
        end
        local existing = c:get("dhcp", dhcp_sid, "dhcp_option_force") or {}
        if type(existing) == "string" then existing = { existing } end
        local kept = {}
        for _, v in ipairs(existing) do
            if not v:match("^9,") then
                kept[#kept + 1] = v
            end
        end
        local valid_lpr = {}
        for _, addr in ipairs(cfg.lpr) do
            if type(addr) == "string" and addr ~= "" then
                valid_lpr[#valid_lpr + 1] = addr
            end
        end
        if #valid_lpr > 0 then
            kept[#kept + 1] = "9," .. table.concat(valid_lpr, ",")
        end
        if #kept > 0 then
            c:set("dhcp", dhcp_sid, "dhcp_option_force", kept)
        else
            c:delete("dhcp", dhcp_sid, "dhcp_option_force")
        end
    end
    return nil
end


--- 将一个任意类型的布尔参数规范化为 Lua boolean。
-- 支持 true/false/1/0/"true"/"false"/"1"/"0"。nil 则保持 nil。
-- @param value  any
-- @return boolean|nil
local function normalize_bool_param(value)
    if value == nil then return nil end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then
        local lower = value:lower()
        if lower == "1" or lower == "true" then return true end
        if lower == "0" or lower == "false" then return false end
    end
    return value and true or false
end

--- 与 lan.set_config 对齐：前端可能传 ap_isolate；本模块 get_subnets 返回字段名为 isolate。
-- @param params  table
-- @return any|nil
local function resolve_isolate_param(params)
    if not params then return nil end
    if params.isolate ~= nil then return params.isolate end
    return params.ap_isolate
end

local function notify_mesh_lan_config_renew(c)
    if not fs.access("/etc/config/gl-mesh") then return end
    pcall(function()
        local mode
        if c then
            mode = c:get("gl-mesh", "@base[0]", "mode") or "controller"
        else
            local tc = uci.cursor()
            mode = tc:get("gl-mesh", "@base[0]", "mode") or "controller"
            tc:close()
        end
        if mode == "controller" then
            ubus.call("gl-mesh", "config_renew", { config_type = "NETWORK_CONFIG" })
        end
    end)
end

--- 读取子网当前 WAN 访问模式（三态）：
-- 0/1/2 与 set_wan_access_mode 落盘一致。模式 2 仅认专用段 <net>_transfer_enable（本模块 set_transfer_enable 写入）；
-- secure_option 上的 transfer_enable 与 lan/备份 里「访客上网」同源，与三态 2 的语义易混，不参与判定。
-- @param c        uci.cursor
-- @param network  string
-- @return number
local function get_wan_access_mode_state(c, network)
    if network == "lan" then return 0 end
    if not fs.access("/etc/config/gl-black_white_list") then
        return 0
    end
    local bwl_ded = network .. "_transfer_enable"
    local te_ded = c:get("gl-black_white_list", bwl_ded, "transfer_enable")
    if te_ded == "0" then
        return 2
    end
    local wi = c:get("gl-black_white_list", network, "wan_isolate")
    if wi == "1" then
        return 1
    end
    return 0
end

local function get_wan_ipaddr(exclude_modem)
    local c = uci.cursor()
    local wan_array = {"wan", "wwan", "tethering", "secondwan", "usbwan"}
    local wan_ipaddr = {}

    if not exclude_modem then
        c:foreach("network", "interface", function(s)
            local name = s['.name']
            if string.sub(name, 1, 6) == "modem_" then
                local proto = c:get("network", name, "proto")
                if proto and proto ~= "dhcpv6" then
                    if proto == "qcm" or proto == "qmi" then
                        wan_array[#wan_array+1] = name.."_4"
                    else
                        wan_array[#wan_array+1] = name
                    end
                end
            end
        end)
    end

    for i = 1, #wan_array do
        local s = ubus.call("network.interface."..wan_array[i], "status")

        if s and s['ipv4-address'] and s['ipv4-address'][1] and s['ipv4-address'][1]['address'] and s['ipv4-address'][1]['mask'] then
            local _wan_info = s['ipv4-address'][1]['address'].."/"..s['ipv4-address'][1]['mask']
            local wan_info = lnet.ipcalc(_wan_info)

            wan_ipaddr[#wan_ipaddr+1] = {
                interface = wan_array[i],
                info = wan_info
            }
        end
    end

    return wan_ipaddr
end

local function set_network_wan_isolate(c, network_name, wan_isolate)
    local wan_array = build_wan_logical_interface_list(c)

    for _, name in ipairs(wan_array) do
        c:delete("firewall", name.."_"..network_name.."_isolate")
    end

    if wan_isolate == 1 then
        local wan_addrs = get_wan_ipaddr(true)

        for _, addr in ipairs(wan_addrs) do
            local wan_info = addr.info
            local interface = addr.interface
            if wan_info and interface and is_private_ip(wan_info.network) then
                local section = interface.."_"..network_name.."_isolate"
                c:set("firewall", section, "rule")
                c:set("firewall", section, "gl_prio",'2')
                c:set("firewall", section, "src", network_name)
                c:set("firewall", section, "dest", "wan")
                c:set("firewall", section, "proto", "all")
                c:set("firewall", section, "target", "REJECT")
                c:set("firewall", section, "name", "isolate "..network_name.." and "..interface)
                c:set("firewall", section, "dest_ip", wan_info.network.."/"..wan_info.prefix)
                c:commit("firewall")
                utils.adjust_firewall_priority(section)
            end
        end
    end

    c:commit("firewall")
end

--- 写入子网的 WAN 转发和防火墙带配置：
--   gl-black_white_list transfer_enable、防火墙区域创建、WAN forwarding 管理。
-- AP 隔离由 set_ap_isolate 单独处理；此处不因 isolate 变更而写入任何字段。
-- @param c          uci.cursor
-- @param network    string
-- @param wan_access_mode  boolean|nil  nil 表示不修改 transfer / WAN forwarding（仍会确保防火墙 zone 等）
local function set_transfer_enable(c, network, wan_access_mode)
    -- gl-black_white_list
    if wan_access_mode ~= nil then
        local bwl_section = network .. "_transfer_enable"
        if not c:get("gl-black_white_list", bwl_section) then
            c:set("gl-black_white_list", bwl_section, "setting")
            c:set("gl-black_white_list", bwl_section, "network", network)
        end
        c:set("gl-black_white_list", bwl_section, "transfer_enable", wan_access_mode and "1" or "0")
    end

    -- Ensure firewall zone exists
    local zone_found = false
    c:foreach("firewall", "zone", function(s)
        if s.name == network then
            zone_found = true
            return false
        end
    end)
    if not zone_found then
        local zone_sid = c:add("firewall", "zone")
        c:set("firewall", zone_sid, "name", network)
        c:set("firewall", zone_sid, "network", { network })
        c:set("firewall", zone_sid, "input", "REJECT")
        c:set("firewall", zone_sid, "output", "ACCEPT")
        c:set("firewall", zone_sid, "forward", "REJECT")
    end

    -- Manage WAN forwarding
    if wan_access_mode ~= nil then
        local fwd_found = false
        c:foreach("firewall", "forwarding", function(s)
            if s.src == network and s.dest == "wan" then
                fwd_found = true
                if wan_access_mode then
                    c:set("firewall", s[".name"], "enabled", "1")
                else
                    c:set("firewall", s[".name"], "enabled", "0")
                end
            end
        end)
        if not fwd_found and wan_access_mode then
            local fwd_sid = c:add("firewall", "forwarding")
            c:set("firewall", fwd_sid, "src", network)
            c:set("firewall", fwd_sid, "dest", "wan")
        end
    end
end

--- 写入 gl-black_white_list.<network>.wan_isolate（与 lan.set_config、/etc/udhcpc.user.d/update_wan_isolate 一致）。
local function set_bwl_wan_isolate_option(c, network, on)
    if not fs.access("/etc/config/gl-black_white_list") then
        return
    end
    if not c:get("gl-black_white_list", network) then
        c:set("gl-black_white_list", network, "secure_option")
    end
    c:set("gl-black_white_list", network, "wan_isolate", on and "1" or "0")
end

--- 按三态 wan_access_mode 落盘：0=全放行，1=可上网但拦 WAN 私网，2=禁止上 WAN；nil 不改动 transfer/forwarding。
-- mode 为 1 或 2 时同步 wan_isolate=1，以便 update_wan_isolate 等逻辑识别；mode 0 时 wan_isolate=0。
local function set_wan_access_mode(c, network, wan_access_mode)
    local mode = tonumber(wan_access_mode)
    if mode == nil then
        set_transfer_enable(c, network, nil)
        return
    end

    if mode == 2 then
        set_transfer_enable(c, network, false)
    else
        set_transfer_enable(c, network, true)
        set_network_wan_isolate(c, network, mode)
    end

    if mode == 1 or mode == 2 then
        set_bwl_wan_isolate_option(c, network, true)
    else
        set_bwl_wan_isolate_option(c, network, false)
    end
end

--- 确保子网拥有 Allow-DHCP-<network> 和 Allow-DNS-<network> 防火墙规则。
-- @param c        uci.cursor
-- @param network  string
local function ensure_custom_firewall_rules(c, network)
    local dhcp_rule = "Allow-DHCP-" .. network
    local dns_rule = "Allow-DNS-" .. network
    local dhcp_found, dns_found = false, false
    c:foreach("firewall", "rule", function(s)
        if s.name == dhcp_rule then dhcp_found = true end
        if s.name == dns_rule then dns_found = true end
    end)
    if not dhcp_found then
        local sid = c:add("firewall", "rule")
        c:set("firewall", sid, "name", dhcp_rule)
        c:set("firewall", sid, "src", network)
        c:set("firewall", sid, "target", "ACCEPT")
        c:set("firewall", sid, "proto", "udp")
        c:set("firewall", sid, "dest_port", "67-68")
    end
    if not dns_found then
        local sid = c:add("firewall", "rule")
        c:set("firewall", sid, "name", dns_rule)
        c:set("firewall", sid, "src", network)
        c:set("firewall", sid, "target", "ACCEPT")
        c:set("firewall", sid, "proto", "tcp udp")
        c:set("firewall", sid, "dest_port", "53")
    end

    -- 主网 (lan) 入站访问「本子网在路由器上的网关 IP」时仍走 lan zone + input ACCEPT，不会命中
    -- 子网 zone 的 input REJECT；HTTP 服务常监听 0.0.0.0（含 8080/8443），导致可从主网用子网网关 IP 打开管理页。
    -- 显式拒绝：src=lan, dest_ip=本子网 ipaddr，端口含 LuCI/oui 常用端口。
    if network ~= "lan" then
        local gw = c:get("network", network, "ipaddr")
        local block_name = "Block-LAN-mgmt-" .. network
        local block_sid = nil
        c:foreach("firewall", "rule", function(s)
            if s.name == block_name then
                block_sid = s[".name"]
                return false
            end
        end)
        local lan_ip = c:get("network", "lan", "ipaddr")
        if not gw or gw == "" or gw == lan_ip then
            if block_sid then c:delete("firewall", block_sid) end
        else
            -- 须含 8080/8443 及 uhttpd 口；主网用子网网关 IP 打管理页时走 lan input。
            local dest_ports
            do
                local d_seen = { ["80"] = true, ["443"] = true, ["8080"] = true, ["8443"] = true }
                local d_list = { "80", "443", "8080", "8443" }
                pcall(function()
                    local v = c:get("uhttpd", "main", "listen_http")
                    if type(v) == "string" then
                        local p = v:match(":(%d+)")
                        if p and p:match("^%d+$") and not d_seen[p] then
                            d_seen[p] = true
                            d_list[#d_list + 1] = p
                        end
                    elseif type(v) == "table" then
                        for _, e in ipairs(v) do
                            local p = tostring(e):match(":(%d+)")
                            if p and p:match("^%d+$") and not d_seen[p] then
                                d_seen[p] = true
                                d_list[#d_list + 1] = p
                            end
                        end
                    end
                    v = c:get("uhttpd", "main", "listen_https")
                    if type(v) == "string" then
                        local p = v:match(":(%d+)")
                        if p and p:match("^%d+$") and not d_seen[p] then
                            d_seen[p] = true
                            d_list[#d_list + 1] = p
                        end
                    elseif type(v) == "table" then
                        for _, e in ipairs(v) do
                            local p = tostring(e):match(":(%d+)")
                            if p and p:match("^%d+$") and not d_seen[p] then
                                d_seen[p] = true
                                d_list[#d_list + 1] = p
                            end
                        end
                    end
                end)
                table.sort(d_list, function(a, b) return tonumber(a) < tonumber(b) end)
                dest_ports = table.concat(d_list, " ")
            end
            if block_sid then
                c:set("firewall", block_sid, "dest_ip", gw)
                c:set("firewall", block_sid, "dest_port", dest_ports)
            else
                block_sid = c:add("firewall", "rule")
                c:set("firewall", block_sid, "name", block_name)
                c:set("firewall", block_sid, "src", "lan")
                c:set("firewall", block_sid, "dest_ip", gw)
                c:set("firewall", block_sid, "proto", "tcp udp")
                c:set("firewall", block_sid, "dest_port", dest_ports)
                c:set("firewall", block_sid, "target", "REJECT")
            end
        end
    end
end

--- 对齐 lan.set_config 的 ngx.timer：reload 后再写 brport/isolated、mtkwifi、交换等（与 ap_isolate_config 的 UCI 互补）。
-- @param skip_switch_restart   boolean|nil  调用方已做过 reset_gsw_ports 时传 true，跳过 platform_switch_restart 避免双重 toggle
-- @param skip_network_reload   boolean|nil  调用方刚 apply_network_changes 时传 true，跳过 timer 内 network reload
local function schedule_ap_isolate_lan_post_actions(iface, ap_isolate, skip_switch_restart, skip_network_reload)
    if not iface or ap_isolate == nil then return end
    ngx.timer.at(1, function()
        local c = uci.cursor()
        if not skip_network_reload then
            pcall(function() ubus.call("network", "reload") end)
        end
        pcall(function() ngx.pipe.spawn(". /lib/functions/kmwan.sh;sync_route_netcell"):wait() end)
        ngx.sleep(2.0)
        pcall(function() ngx.pipe.spawn({ "/etc/init.d/firewall", "reload" }):wait() end)
        pcall(function() ngx.pipe.spawn({ "/etc/init.d/dnsmasq", "reload" }):wait() end)
        pcall(function() ngx.pipe.spawn({ "/etc/init.d/gl-black_white_list", "reload" }):wait() end)
        if iface == "lan" then
            local device = c:get("network", "lan", "device")
            if device then
                local ports
                c:foreach("network", "device", function(s)
                    if s.name == device then
                        if type(s.ports) == "string" then
                            s.ports = { s.ports }
                        end
                        ports = s.ports
                        return false
                    end
                end)
                for _, port in ipairs(ports or {}) do
                    pcall(function()
                        ngx.pipe.spawn({ "/sbin/ip", "link", "set", port, "down" }):wait()
                    end)
                end
                ngx.sleep(1.0)
                for _, port in ipairs(ports or {}) do
                    pcall(function()
                        ngx.pipe.spawn({ "/sbin/ip", "link", "set", port, "up" }):wait()
                    end)
                end
            end
        end

        ngx.pipe.spawn(". /lib/functions/gl_util.sh; restore_hairpin_mode " .. iface)

        if hardware then
            local run_switch = not skip_switch_restart
            -- 自定义 vlanN 无 WiFi 接口，不做 platform_switch_restart
            if run_switch and iface and iface:match("^vlan%d+$") then
                run_switch = false
            end
            if run_switch then
                hardware.platform_switch_restart()
            end
            hardware.platform_usb_lan_restart()
        end
        pcall(function()
            local ovpn_type = c:get("ovpnserver", "vpn", "dev_type")
            if ovpn_type == "tap-s2s" then
                ngx.pipe.spawn({ "sh", "-c", "kill -HUP $(cat /var/run/ovpnserver-ovpnserver.pid)" }):wait()
            end
        end)

        if fs.access("/etc/config/ecm") then
            c:foreach("wireless", "wifi-iface", function(s)
                if s.network == iface and s.ifname then
                    os.execute("echo " .. tostring(ap_isolate) .. " > /sys/class/net/"
                        .. s.ifname .. "/brport/isolated")
                end
            end)
        end
        c:close()
    end)
end

--- AP 隔离：UCI（含 ap_isolate_config.lua）+ 延后 timer（同 lan.set_config）。
-- @param skip_switch_restart  boolean|nil  调用方已做过 reset_gsw_ports 时传 true
-- @param skip_network_reload  boolean|nil  调用方刚 apply_network_changes 时传 true
local function set_ap_isolate(c, network, isolate, skip_switch_restart, skip_network_reload)
    if isolate == nil then return end
    local on = normalize_bool_param(isolate)
    if on == nil then return end
    local iso_num = on and 1 or 0
    if fs.access("/etc/config/gl-black_white_list") then
        if not c:get("gl-black_white_list", network) then
            c:set("gl-black_white_list", network, "secure_option")
        end
        c:set("gl-black_white_list", network, "ap_isolate", on and "1" or "0")
        c:commit("gl-black_white_list")
    end
    if fs.access("/etc/ap_isolate_config.lua") then
        ngx.pipe.spawn({"lua", "/etc/ap_isolate_config.lua", network, tostring(iso_num)}):wait()
        ngx.pipe.spawn({ "/etc/init.d/firewall", "reload" })
        pcall(function() ubus.call("network", "reload") end)
    end
    schedule_ap_isolate_lan_post_actions(network, iso_num, skip_switch_restart, skip_network_reload)
end

--- 确保 UCI network.device 中存在指定名称的桥设备配置。
-- 如果存在多个同名节点，保留第一个并删除多余的。
-- 如果不存在，创建 type=bridge 的设备节点。
-- br-lan 不处理：主桥由 netmode / libcable 等维护，避免本子网模块改写其 device 节。
-- @param c            uci.cursor
-- @param bridge_name  string
local function ensure_bridge_device(c, bridge_name)
    if bridge_name == "br-lan" then return end
    local found_sids = {}
    c:foreach("network", "device", function(s)
        if s.name == bridge_name then
            found_sids[#found_sids + 1] = s[".name"]
        end
    end)
    if #found_sids > 1 then
        for i = 2, #found_sids do
            c:delete("network", found_sids[i])
        end
    end
    if #found_sids == 0 then
        local sid = c:add("network", "device")
        c:set("network", sid, "name", bridge_name)
        c:set("network", sid, "type", "bridge")
    end
end

--- 将固定子网（lan/guest/iot）恢复到 VLAN 子网出厂默认配置。
-- lan/guest/iot 分别恢复到 br-lan/br-guest/br-iot，guest/iot 默认关闭。
-- lan 不覆盖 proto/ipaddr（与 netmode 切模式一致，保留用户主网地址与协议）。
-- 不修改各桥 device 的 ports（桥下成员是否恢复出厂由其它模块/用户配置决定）。
-- 须放在 ensure_bridge_device / set_transfer_enable / ensure_custom_firewall_rules 之后，避免 Lua 局部函数前向引用退化为全局 nil。
-- @param c  uci.cursor
local function restore_fixed_subnets_factory(c)
    for _, net in ipairs(FIXED_SUBNETS) do
        local defaults = DEFAULT_SUBNET_CFG[net]
        if defaults then
            ensure_bridge_device(c, defaults.bridge)

            if not c:get("network", net) then
                c:set("network", net, "interface")
            end

            if net ~= "lan" then
                c:set("network", net, "proto", "static")
                c:set("network", net, "ipaddr", defaults.gateway)
                c:set("network", net, "netmask", defaults.netmask)
            end
            c:set("network", net, "device", defaults.bridge)
            c:set("network", net, "display_name", defaults.display_name)
            c:set("network", net, "vlan_id", tostring(defaults.vlan_id))

            if defaults.enabled then
                c:delete("network", net, "disabled")
            else
                c:set("network", net, "disabled", "1")
            end

            set_dhcp_config(c, net, {
                dhcp_enable = defaults.dhcp_enable,
                dhcp_start = defaults.dhcp_start,
                dhcp_limit = defaults.dhcp_limit,
                leasetime = defaults.leasetime,
            })
        end
    end

    for _, net in ipairs({ "guest", "iot" }) do
        ensure_custom_firewall_rules(c, net)
        set_wan_access_mode(c, net, 0)
        c:delete("gl-black_white_list", net .. "_ap_isolate")
        c:delete("gl-black_white_list", net .. "_wan_isolate")
        c:delete("gl-black_white_list", net)
    end
end


--- 从 UCI 中删除指定子网的全部配置：接口、桥设备、bridge-vlan、DHCP、
-- DHCP 静态绑定、防火墙区域/转发/规则、gl-black_white_list。
-- 注意：此函数不进行 commit 和 reload。
-- @param c        uci.cursor
-- @param network  string
local function delete_subnet_config(c, network)
    local bridge = get_bridge_for_network(network)
    local vid = get_vlan_id_for_network(c, network)

    c:delete("network", network)

    if bridge then
        local dev_to_delete = {}
        c:foreach("network", "device", function(s)
            if s.name == bridge then dev_to_delete[#dev_to_delete + 1] = s[".name"] end
        end)
        for _, sid in ipairs(dev_to_delete) do c:delete("network", sid) end
    end

    -- DSA：删除与该子网 VLAN ID 对应的 ethX.V / lanX.V 设备节（否则仅删 interface 会残留）
    if vid then
        local vlan_dev_sids = {}
        c:foreach("network", "device", function(s)
            local n = s.name
            if n then
                local v = vlan_subif_vid_purge(n)
                if v == vid then vlan_dev_sids[#vlan_dev_sids + 1] = s[".name"] end
            end
        end)
        for _, sid in ipairs(vlan_dev_sids) do c:delete("network", sid) end
    end

    if vid then
        local bv_to_delete = {}
        c:foreach("network", "bridge-vlan", function(s)
            if tonumber(s.vlan) == vid then bv_to_delete[#bv_to_delete + 1] = s[".name"] end
        end)
        for _, sid in ipairs(bv_to_delete) do c:delete("network", sid) end
    end

    local dhcp_sid = find_dhcp_section(c, network)
    if dhcp_sid then c:delete("dhcp", dhcp_sid) end

    local host_to_delete = {}
    c:foreach("dhcp", "host", function(s)
        if s.network == network then host_to_delete[#host_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(host_to_delete) do c:delete("dhcp", sid) end

    local zone_to_delete = {}
    c:foreach("firewall", "zone", function(s)
        if s.name == network then zone_to_delete[#zone_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(zone_to_delete) do c:delete("firewall", sid) end

    local fwd_to_delete = {}
    c:foreach("firewall", "forwarding", function(s)
        if s.src == network or s.dest == network then fwd_to_delete[#fwd_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(fwd_to_delete) do c:delete("firewall", sid) end

    local rule_to_delete = {}
    c:foreach("firewall", "rule", function(s)
        if s.src == network or s.dest == network then
            if s.name and (s.name:match("^Allow%-" .. network) or s.name:match(network)) then
                rule_to_delete[#rule_to_delete + 1] = s[".name"]
            end
        end
    end)
    c:foreach("firewall", "rule", function(s)
        if s.name == "Block-LAN-mgmt-" .. network then
            rule_to_delete[#rule_to_delete + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(rule_to_delete) do c:delete("firewall", sid) end

    c:delete("gl-black_white_list", network .. "_transfer_enable")
    c:delete("gl-black_white_list", network .. "_ap_isolate")
    c:delete("gl-black_white_list", network .. "_wan_isolate")
    c:delete("gl-black_white_list", network)
end

--- 清理指定 VLAN 对应的 eth_ports_config_map 端口绑定：
-- 将 pvid 等于该 VLAN 的端口回退到 pvid=1，与该 VLAN 相关的 tagged_vlans 也一并移除。
-- 同时删除 br-vlanN 的 ports 列表和 bridge-vlan 节点。
-- @param vlan_id     number
-- @param ext_cursor  uci.cursor|nil  传入则复用，否则自建同时负责 commit/close
local function clear_eth_ports_config_map_for_vlan(vlan_id, ext_cursor)
    if not vlan_id then return end
    local vid_num = tonumber(vlan_id)
    if not vid_num then return end
    local c = ext_cursor or uci.cursor()
    local bridge = "br-vlan" .. tostring(vlan_id)
    c:foreach("network", "device", function(s)
        if s.name == bridge and s.ports then
            c:delete("network", s[".name"], "ports")
        end
    end)
    local bv_to_delete = {}
    c:foreach("network", "bridge-vlan", function(s)
        if tonumber(s.vlan) == vlan_id then bv_to_delete[#bv_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(bv_to_delete) do c:delete("network", sid) end

    local map_changed = false
    pcall(function()
        c:foreach("eth_ports_config_map", "port", function(s)
            local sid = s[".name"]
            if not sid then return end
            local pvid = tonumber(c:get("eth_ports_config_map", sid, "pvid"))
            if pvid == vid_num then
                c:set("eth_ports_config_map", sid, "pvid", "1")
                local mode = c:get("eth_ports_config_map", sid, "mode")
                if mode ~= "wan" then
                    c:set("eth_ports_config_map", sid, "vlan_mode", "access")
                end
                map_changed = true
            end
            local tagged = {}
            if c.get_list then
                local list = c:get_list("eth_ports_config_map", sid, "tagged_vlans")
                if type(list) == "table" then tagged = list end
            end
            if #tagged == 0 then
                local raw = c:get("eth_ports_config_map", sid, "tagged_vlans")
                if type(raw) == "string" and raw ~= "" then
                    for token in raw:gmatch("[^,%s]+") do
                        tagged[#tagged + 1] = token
                    end
                end
            end
            if #tagged > 0 then
                local filtered = {}
                for _, v in ipairs(tagged) do
                    if tonumber(v) ~= vid_num then
                        filtered[#filtered + 1] = tostring(v)
                    end
                end
                if #filtered ~= #tagged then
                    set_tagged_vlans_option(c, sid, filtered)
                    map_changed = true
                end
            end
        end)
    end)
    if map_changed then
        c:commit("eth_ports_config_map")
    end
    if not ext_cursor then
        c:commit("network")
        c:close()
    end
end

--- 将 eth_ports_config_map 中指定旧 VLAN ID 的 pvid 更新为新 VLAN ID。
-- 用于自定义子网 VLAN ID 变更时应用。通过展开 uci shell 命令实现。
-- @param old_vlan_id  number
-- @param new_vlan_id  number
-- @return boolean  是否有条目被更新
local function update_eth_ports_config_map_for_vlan_id_change(old_vlan_id, new_vlan_id)
    if not old_vlan_id or not new_vlan_id or old_vlan_id == new_vlan_id then return false end
    local vid_old = tonumber(old_vlan_id)
    local vid_new = tonumber(new_vlan_id)
    if not vid_old or not vid_new then return false end

    local c = uci.cursor()
    local updated = false

    c:foreach("eth_ports_config_map", "port", function(s)
        local sid = s[".name"]
        if not sid then return end

        local pvid_raw = c:get("eth_ports_config_map", sid, "pvid")
        local pvid
        if type(pvid_raw) == "string" or type(pvid_raw) == "number" then
            pvid = tonumber(pvid_raw)
            if pvid == vid_old then
                c:set("eth_ports_config_map", sid, "pvid", tostring(vid_new))
                updated = true
            end
        end

        local tagged = read_tagged_vlans_from_map(c, sid)
        if #tagged > 0 then
            local new_tagged = {}
            local changed = false
            for _, v in ipairs(tagged) do
                local vnum = nil
                if type(v) == "string" or type(v) == "number" then
                    vnum = tonumber(v)
                end
                if vnum and vnum == vid_old then
                    new_tagged[#new_tagged + 1] = tostring(vid_new)
                    changed = true
                elseif vnum then
                    new_tagged[#new_tagged + 1] = tostring(vnum)
                end
            end
            if changed then
                set_tagged_vlans_option(c, sid, new_tagged)
                updated = true
            end
        end
    end)

    if updated then
        c:commit("eth_ports_config_map")
    end
    c:close()
    return updated
end

--- 将 VLAN ID 变更应用到 eth_ports_config_map 并触发网络下发。
-- 如果 map 无需更新则直接返回。优先调用 libcable，其次通过 ubus RPC。
-- @param old_vlan_id  number
-- @param new_vlan_id  number
local function apply_cable_for_vlan_id_change(old_vlan_id, new_vlan_id)
    if not update_eth_ports_config_map_for_vlan_id_change(old_vlan_id, new_vlan_id) then return end
    local ok_lc, libcable = pcall(require, "libcable")
    if ok_lc and libcable and libcable.apply_network_from_eth_ports_config_map then
        pcall(libcable.apply_network_from_eth_ports_config_map)
    else
        pcall(ubus.call, "oui-httpd", "rpc_call", {
            object = "cable", method = "apply_network_from_eth_ports_config_map", params = {},
        })
    end
    -- Notify gl-mesh that VLAN IDs have changed so it can rebuild traffic separation
    pcall(ubus.send, "gl-vlan-subnet.vlan_changed", {})
end

--- 同步 parental_control UCI 配置中对应子网桥的 src_dev 列表。
-- action = "add" 时将桥加入各 global section，"remove" 时移除。
-- @param network  string
-- @param action   string  "add" | "remove"
local function update_parental_control(network, action, old_network)
    local cfg
    if fs.access("/etc/config/parental_control_v2") then
        cfg = "parental_control_v2"
    elseif fs.access("/etc/config/parental_control") then
        cfg = "parental_control"
    else
        return
    end

    local bridge = get_bridge_for_network(network)
    if not bridge then return end

    local old_bridge = nil
    if action == "modify" and old_network then
        old_bridge = get_bridge_for_network(old_network)
    end

    local c2 = uci.cursor()

    if action == "add" then
        c2:foreach(cfg, "global", function(s)
            local src_dev = s.src_dev or {}
            if type(src_dev) == "string" then src_dev = { src_dev } end
            for _, d in ipairs(src_dev) do
                if d == bridge then return end
            end

            src_dev[#src_dev + 1] = bridge
            local sid = s[".name"]

            if c2.add_list then
                pcall(function() c2:add_list(cfg, sid, "src_dev", bridge) end)
            elseif c2.set then
                pcall(function() c2:set(cfg, sid, "src_dev", src_dev) end)
            end
        end)
    elseif action == "remove" then
        c2:foreach(cfg, "global", function(s)
            local sid = s[".name"]
            local raw = s.src_dev or {}
            if type(raw) == "string" then raw = { raw } end

            local list = {}
            for _, v in ipairs(raw) do
                if v ~= bridge then
                    list[#list + 1] = v
                end
            end

            if #list == 0 then
                pcall(function() c2:delete(cfg, sid, "src_dev") end)
            else
                if c2.set then
                    pcall(function() c2:set(cfg, sid, "src_dev", list) end)
                elseif c2.add_list then
                    pcall(function() c2:delete(cfg, sid, "src_dev") end)
                    for _, v in ipairs(list) do
                        pcall(function() c2:add_list(cfg, sid, "src_dev", v) end)
                    end
                end
            end
        end)
    elseif action == "modify" then
        if old_bridge == bridge then
            ngx.log(ngx.ERR, "old and new bridges are the same, skip modify")
            c2:close()
            return
        end

        c2:foreach(cfg, "global", function(s)
            local sid = s[".name"]
            local raw = s.src_dev or {}
            if type(raw) == "string" then raw = { raw } end

            local list = {}
            local added = false

            for _, v in ipairs(raw) do
                if v ~= old_bridge then
                    if v == bridge then
                        added = true
                    end
                    list[#list + 1] = v
                end
            end

            if not added then
                list[#list + 1] = bridge
            end

            if c2.set then
                pcall(function() c2:set(cfg, sid, "src_dev", list) end)
            elseif c2.add_list then
                c2:delete(cfg, sid, "src_dev")
                for _, v in ipairs(list) do
                    pcall(function() c2:add_list(cfg, sid, "src_dev", v) end)
                end
            end
        end)
    end

    pcall(function() c2:commit(cfg) end)
    c2:close()
end

local function option_to_list(raw)
    local list = {}
    if type(raw) == "table" then
        for _, v in ipairs(raw) do
            if type(v) == "string" then
                for token in v:gmatch("[^%s]+") do
                    list[#list + 1] = token
                end
            end
        end
    elseif type(raw) == "string" then
        for token in raw:gmatch("[^%s]+") do
            list[#list + 1] = token
        end
    end
    return list
end

local function list_has_value(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

local function append_unique(list, value)
    if not list_has_value(list, value) then
        list[#list + 1] = value
    end
end

local function set_uci_list(c, cfg, sid, opt, list)
    c:delete(cfg, sid, opt)
    if not list or #list == 0 then return end
    if c.set_list then
        c:set_list(cfg, sid, opt, list)
    elseif c.add_list then
        for _, v in ipairs(list) do
            c:add_list(cfg, sid, opt, v)
        end
    else
        c:set(cfg, sid, opt, list)
    end
end

local function sync_route_policy_interface_from(old_network, new_network)
    if old_network == new_network or not fs.access("/etc/config/route_policy") then return false end

    local c2 = uci.cursor()
    local changed = false

    c2:foreach("route_policy", "rule", function(s)
        if s.from_type ~= "interface" then return end

        local from = option_to_list(s.from)
        if not list_has_value(from, old_network) then return end

        local list = {}
        for _, v in ipairs(from) do
            if v == old_network then
                append_unique(list, new_network)
                changed = true
            else
                append_unique(list, v)
            end
        end

        set_uci_list(c2, "route_policy", s[".name"], "from", list)
    end)

    if changed then c2:commit("route_policy") end
    c2:close()
    return changed
end

--- 删除所有自定义子网（vlanN）；eth_ports_config_map 由 libcable（如 apply_ap_mode_port_defaults）维护，不在此写 map。
-- @param c  uci.cursor
local function delete_all_custom_subnets(c)
    local custom_nets = {}
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name and name:match("^vlan%d+$") then
            custom_nets[#custom_nets + 1] = name
        end
    end)
    for _, name in ipairs(custom_nets) do
        update_parental_control(name, "remove")
        delete_subnet_config(c, name)
    end
    ngx.pipe.spawn({"/etc/init.d/parental_control", "restart"})
end

--- 强力清理所有自定义 VLAN 残留配置节点，覆盖 delete_all_custom_subnets 可能漏掉的情况：
--   network.interface vlanN、桥设备 br-vlanN/ethX.N、switch_vlan、bridge-vlan、
--   DHCP section、DHCP 静态绑定、防火墙区域/转发/规则。
-- @param c  uci.cursor
local function purge_custom_vlan_residue(c)
    -- guest/iot 当前使用的 VLAN ID：对应 DSA 子接口设备需保留，其余 >=VLAN_ID_MIN 的 eth*/lan* 视为可清理残留
    local protect_eth_vid = { [1] = true }
    for _, net in ipairs({ "guest", "iot" }) do
        if c:get("network", net) then
            local v = get_vlan_id_for_network(c, net)
            if v then protect_eth_vid[v] = true end
        end
    end

    -- network.interface: vlanN
    local if_to_delete = {}
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name and name:match("^vlan%d+$") then
            if_to_delete[#if_to_delete + 1] = name
        end
    end)
    for _, sid in ipairs(if_to_delete) do c:delete("network", sid) end

    -- network.device: br-vlanN, ethX.N / lanX.N (N>=VLAN_ID_MIN)
    local dev_to_delete = {}
    c:foreach("network", "device", function(s)
        local name = s.name
        if name and name:match("^br%-vlan%d+$") then
            dev_to_delete[#dev_to_delete + 1] = s[".name"]
        elseif name then
            local vid = vlan_subif_vid_purge(name)
            if vid and vid >= VLAN_ID_MIN and not protect_eth_vid[vid] then
                dev_to_delete[#dev_to_delete + 1] = s[".name"]
            end
        end
    end)
    for _, sid in ipairs(dev_to_delete) do c:delete("network", sid) end

    -- network.switch_vlan / bridge-vlan: vlan>=VLAN_ID_MIN
    local sv_to_delete = {}
    c:foreach("network", "switch_vlan", function(s)
        local vid = tonumber(s.vlan)
        if vid and vid >= VLAN_ID_MIN then sv_to_delete[#sv_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(sv_to_delete) do c:delete("network", sid) end

    local bv_to_delete = {}
    c:foreach("network", "bridge-vlan", function(s)
        local vid = tonumber(s.vlan)
        if vid and vid >= VLAN_ID_MIN then bv_to_delete[#bv_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(bv_to_delete) do c:delete("network", sid) end

    -- dhcp: interface=vlanN, host.network=vlanN
    local dhcp_to_delete = {}
    c:foreach("dhcp", "dhcp", function(s)
        if s.interface and s.interface:match("^vlan%d+$") then
            dhcp_to_delete[#dhcp_to_delete + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(dhcp_to_delete) do c:delete("dhcp", sid) end

    local host_to_delete = {}
    c:foreach("dhcp", "host", function(s)
        if s.network and s.network:match("^vlan%d+$") then
            host_to_delete[#host_to_delete + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(host_to_delete) do c:delete("dhcp", sid) end

    -- firewall: zone/forwarding/rule 里 vlanN 相关
    local zone_to_delete = {}
    c:foreach("firewall", "zone", function(s)
        if s.name and s.name:match("^vlan%d+$") then
            zone_to_delete[#zone_to_delete + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(zone_to_delete) do c:delete("firewall", sid) end

    local fwd_to_delete = {}
    c:foreach("firewall", "forwarding", function(s)
        if (s.src and s.src:match("^vlan%d+$")) or (s.dest and s.dest:match("^vlan%d+$")) then
            fwd_to_delete[#fwd_to_delete + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(fwd_to_delete) do c:delete("firewall", sid) end

    local rule_to_delete = {}
    c:foreach("firewall", "rule", function(s)
        local has_vlan = (s.src and s.src:match("^vlan%d+$"))
            or (s.dest and s.dest:match("^vlan%d+$"))
            or (s.name and s.name:match("vlan%d+"))
        if has_vlan then rule_to_delete[#rule_to_delete + 1] = s[".name"] end
    end)
    for _, sid in ipairs(rule_to_delete) do c:delete("firewall", sid) end
end

--- 子网配置变更后的后置动作：重新生成端口映射并同步 tertf 子网（与 hotplug 共用 init.d sync）。
local function post_subnet_change()
    os.execute("/etc/init.d/gl-vlan-port-map start >/dev/null 2>&1")
end

--- 自定义 br-vlan* 在 network reload 后才就绪；延迟重载 gl_eqos，避免与 DHCP 竞争且无需在 vlan ifup hotplug 上立刻 stop/start。
local function schedule_gl_eqos_restart_after_br_vlan_change()
    os.execute(
        "(sleep 22; test -n \"$(grep queue /etc/config/qos 2>/dev/null | grep -v '#')\" && test -x /etc/init.d/gl_eqos && /etc/init.d/gl_eqos restart) >/dev/null 2>&1 &"
    )
end

--- 提交所有相关 UCI 配置并执行网络/DHCP/防火墙重载。
-- @param c               uci.cursor
-- @param reload_firewall  boolean|nil  false 时跳过防火墙重载
-- @param before_reload    function|nil  UCI commit 后、network reload 前执行的回调
local function apply_network_changes(c, reload_firewall, before_reload)
    c:commit("network")
    c:commit("dhcp")
    c:commit("firewall")
    if fs.access("/etc/config/gl-black_white_list") then
        c:commit("gl-black_white_list")
    end
    fs.sync()
    post_subnet_change()
    if before_reload then
        before_reload(c)
    end

    os.execute("/etc/init.d/network reload >/dev/null 2>&1")
    os.execute("sleep 2")
    os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
    if reload_firewall ~= false then
        ngx.pipe.spawn({ "/etc/init.d/firewall", "reload" })
    end
    -- hotplug.d/iface 里异步 sync_port_map 可能在 reload 后仍读到短暂不一致状态；最后再生成一次覆盖竞态
    post_subnet_change()
end


--- 读取单个子网的完整信息（供 get_subnets 等 RPC 使用）。
-- **所有子网统一**：**ip**=接口 ipaddr；**gateway**=DHCP option 3（发给客户端的默认网关，无则 ""）。
-- **lan** 若 UCI 无 ipaddr，则先用合法 option 3、再用默认表回填 **ip**（展示用）。
-- **guest / iot** 若无 ipaddr，固定子网可用默认表回填 **ip**（与 UCI 默认一致）。
-- @param c        uci.cursor
-- @param network  string
-- @return table  子网信息对象
local function get_subnet_info(c, network)
    local ipaddr = c:get("network", network, "ipaddr")
    local netmask = c:get("network", network, "netmask")
    local disabled = c:get("network", network, "disabled")
    local vlan_id = get_vlan_id_for_network(c, network)
    local display_name = get_display_name(c, network)

    local defaults = DEFAULT_SUBNET_CFG[network]
    local gw = ipaddr or (defaults and defaults.gateway) or "192.168.8.1"
    local mask = netmask or "255.255.255.0"

    local enabled
    if network == "lan" then
        enabled = true
    else
        enabled = (disabled ~= "1")
    end

    -- DHCP
    local dhcp_sid = find_dhcp_section(c, network)
    local dhcp_enable = true
    local dhcp_start = 100
    local dhcp_limit = 150
    local leasetime = "12h"
    local dns, lpr = {}, {}
    local dhcp_client_gw = ""

    if dhcp_sid then
        dhcp_enable = (c:get("dhcp", dhcp_sid, "ignore") ~= "1")
        dhcp_start = tonumber(c:get("dhcp", dhcp_sid, "start")) or 100
        dhcp_limit = tonumber(c:get("dhcp", dhcp_sid, "limit")) or 150
        leasetime = c:get("dhcp", dhcp_sid, "leasetime") or "12h"
        dns, lpr, dhcp_client_gw = get_dhcp_options(c, network)
    end

    local dhcp_start_ip, dhcp_end_ip = dhcp_offset_to_ips(gw, mask, dhcp_start, dhcp_limit)

    -- Firewall
    local wan_access_mode = get_wan_access_mode_state(c, network)

    local isolate = false
    if fs.access("/etc/config/gl-black_white_list") then
        local ap_val = c:get("gl-black_white_list", network, "ap_isolate")
        if ap_val == "1" then isolate = true end
    end

    -- Ifaces
    local ifaces = {}
    local bindings = get_subnet_bindings(c, network)
    local display_bindings = filter_bindings_for_frontend(bindings)

    local gsw_map_ports = {}
    local ok_gsw, result_gsw = pcall(get_gsw_ports_from_map, c)
    if ok_gsw and result_gsw and #result_gsw > 0 then
        gsw_map_ports = result_gsw
    end

    local online_by_name = {}
    pcall(function()
        local libcable = require("libcable")
        local port_list = libcable.get_ports_list_from_map() or {}
        for _, info in ipairs(port_list) do
            if info.type == "gsw" then
                local sw_port = tonumber(info.port) or info.port
                local f = io.popen(string.format("swconfig dev %s port %s get link",
                    tostring(info.switch or "switch1"), tostring(sw_port)))
                if f then
                    local data = f:read("*l") or ""
                    f:close()
                    local key = (info.name and type(info.name) == "string") and info.name:lower() or info.name
                    online_by_name[key] = data:find("link:up") ~= nil
                end
            end
        end
    end)

    local ok_lc, libcable = pcall(require, "libcable")

    local skip_silk = {}
    if fs.access("/etc/config/eth_ports_config_map") then
        c:foreach("eth_ports_config_map", "port", function(s)
            local sid = s[".name"]
            local tp = c:get("eth_ports_config_map", sid, "type")
            if tp and tp ~= "" and tp ~= "dsa" then return end
            local pv, sk = c:get("eth_ports_config_map", sid, "port"), c:get("eth_ports_config_map", sid, "silk")
            if pv and sk and sk ~= "" then skip_silk[tostring(pv):lower()] = true end
        end)
    end

    if #gsw_map_ports > 0 then
        local phys_in_vlan = get_phys_ports_for_subnet(c, display_bindings, vlan_id)
        for _, gp in ipairs(gsw_map_ports) do
            local gp_port_num = tonumber(gp.port_num) or gp.port_num
            if phys_in_vlan[gp.port_num] or phys_in_vlan[gp_port_num] then
                local port_name = gp.port_name or gp.name
                local key = (port_name and type(port_name) == "string") and port_name:lower() or port_name
                local raw_state = (online_by_name[key] == true) and "up" or "down"
                if not is_hidden_vlan_iface_for_frontend(port_name) then
                    ifaces[#ifaces + 1] = {
                        name = gp.name,
                        port_group = gp.port_group,
                        conn_type = "wired",
                        state = normalize_state(raw_state),
                    }
                end
            end
        end
    else
        local gsw_all = get_all_gsw_vlan_ifaces()
        if #gsw_all > 0 then
            local ports_set = {}
            for _, p in ipairs(display_bindings.ports) do ports_set[p] = true end
            for _, p in ipairs(gsw_all) do
                if ports_set[p] then
                    local klit = (p and type(p) == "string") and p:lower() or p
                    local parlit = type(klit) == "string" and vlan_subif_parent_display(klit)
                    if not (skip_silk[klit] or (parlit and skip_silk[parlit])) then
                        local raw_state = "down"
                        if ok_lc and libcable and libcable.get_map_port_names_for_eth_vlan then
                            local map_names = libcable.get_map_port_names_for_eth_vlan(p)
                            for _, n in ipairs(map_names) do
                                local k = (n and type(n) == "string") and n:lower() or n
                                if online_by_name[k] then raw_state = "up"; break end
                            end
                        end
                        if raw_state == "down" then
                            raw_state = get_wired_link_state_fallback(p)
                        end
                        if not is_hidden_vlan_iface_for_frontend(p) then
                            ifaces[#ifaces + 1] = {
                                name = p,
                                conn_type = "wired",
                                state = normalize_state(raw_state),
                            }
                        end
                    end
                end
            end
        else
            local wifi_ifnames = {}
            c:foreach("wireless", "wifi-iface", function(s)
                if s.network == network and s.ifname then
                    wifi_ifnames[s.ifname] = true
                end
            end)
            for _, p in ipairs(display_bindings.ports) do
                if not wifi_ifnames[p] then
                    local k = (p and type(p) == "string") and p:lower() or p
                    local par = vlan_subif_parent_display(k)
                    if not (skip_silk[k] or (par and skip_silk[par])) then
                        local raw_state = (online_by_name[k] == true) and "up" or get_wired_link_state_fallback(p)
                        if not is_hidden_vlan_iface_for_frontend(p) then
                            ifaces[#ifaces + 1] = {
                                name = p,
                                conn_type = "wired",
                                state = normalize_state(raw_state),
                            }
                        end
                    end
                end
            end
        end
    end

    -- DSA ports from eth_ports_config_map
    local bindings_ports_set = {}
    for _, p in ipairs(display_bindings.ports) do
        if p and p ~= "" then
            local port_key = (tostring(p)):lower()
            bindings_ports_set[port_key] = true

            -- DSA trunk 场景下 bridge 里通常是 ethX.N / lanX.N 子接口，
            -- 展示时需要回映射到基础物理口 ethX / lanX。
            local base_port = port_key:match("^([^:]+)") or port_key
            local parent_port = vlan_subif_parent_display(base_port)
            if parent_port then
                bindings_ports_set[parent_port] = true
            end
        end
    end
    local is_main_net = (network == "lan" and vlan_id == 1)
    -- 对所有子网都从 eth_ports_config_map 查 DSA 端口（按 pvid/tagged_vlans 匹配）
    pcall(function()
        local cc = uci.cursor()
        cc:foreach("eth_ports_config_map", "port", function(s)
            local sid = s[".name"]
            local ptype = cc:get("eth_ports_config_map", sid, "type")
            local port_val = cc:get("eth_ports_config_map", sid, "port")
            local pvid = tonumber(cc:get("eth_ports_config_map", sid, "pvid"))
            if (ptype == "dsa" or not ptype or ptype == "") and port_val then
                local pvid_matches = (pvid and vlan_id and pvid == vlan_id)
                local tagged_matches = false
                local tagged = {}
                if vlan_id then
                    tagged = read_tagged_vlans_from_map(cc, sid)
                    for _, v in ipairs(tagged) do
                        if tonumber(v) == vlan_id then
                            tagged_matches = true
                            break
                        end
                    end
                end
                -- is_main_net 只收录无显式 VLAN 配置的传统端口
                if (is_main_net and not pvid and #tagged == 0) or pvid_matches or tagged_matches then
                    bindings_ports_set[(tostring(port_val)):lower()] = true
                end
            end
        end)
        cc:close()
    end)

    -- DSA：去重键为 eth_ports 段名；桥匹配用 ifname。iface.name 仅用 silk 展示，不参与去重。
    local dsa_by_section = {}
    local port_list = (ok_lc and libcable and libcable.get_ports_list_from_map and libcable.get_ports_list_from_map()) or {}
    for _, info in ipairs(port_list) do
        if info and info.type == "dsa" and info.name then
            local section_key = (tostring(info.name)):lower()
            if not dsa_by_section[section_key] then
                local ifname = info.port or info.name
                local ifname_key = ifname and (tostring(ifname)):lower() or ""
                if bindings_ports_set[ifname_key] and info.mode ~= "wan" then
                    dsa_by_section[section_key] = true
                    local raw_state = (online_by_name[section_key] == true) and "up" or get_wired_link_state_fallback(ifname)
                    ifaces[#ifaces + 1] = {
                        name = info.silk or info.name,
                        port_group = info.port_group or "",
                        conn_type = "wired",
                        state = normalize_state(raw_state),
                    }
                end
            end
        end
    end

    -- WiFi
    local wifi_any_enabled, has_wifi = false, false
    c:foreach("wireless", "wifi-iface", function(s)
        if s.network == network and s.ifname then
            has_wifi = true
            if s.disabled ~= "1" then wifi_any_enabled = true end
        end
    end)
    if has_wifi then
        ifaces[#ifaces + 1] = {
            name = get_wifi_iface_display_name(c, network),
            conn_type = "wifi",
            state = wifi_any_enabled and "up" or "down",
        }
    end

    -- Build result：get_subnets 全量子网字段语义一致（ip=接口，gateway=DHCP option 3）
    local out_ip = ipaddr or ""
    local out_gateway = dhcp_client_gw or ""
    if network == "lan" then
        if out_ip == "" and validate_gateway(dhcp_client_gw) then
            out_ip = dhcp_client_gw
        end
        if out_ip == "" and defaults and validate_gateway(defaults.gateway) then
            out_ip = defaults.gateway
        end
    elseif is_fixed_subnet(network) then
        if out_ip == "" and defaults and validate_gateway(defaults.gateway) then
            out_ip = defaults.gateway
        end
    end

    local info = {
        display_name   = display_name,
        name           = display_name,
        network        = network,
        enabled        = enabled,
        vlan_id        = vlan_id or 0,
        ip             = out_ip,
        gateway        = out_gateway,
        netmask        = mask,
        dhcp_enable    = dhcp_enable,
        dhcp_start_ip  = dhcp_start_ip,
        dhcp_end_ip    = dhcp_end_ip,
        dhcp_start     = dhcp_start,
        dhcp_limit     = dhcp_limit,
        leasetime      = leasetime,
        wan_access_mode = wan_access_mode,
        isolate        = isolate,
        dns            = dns,
        lpr            = lpr,
        ifaces         = ifaces,
    }

    return info
end

--- 将桥设备的 ports 列表写入 UCI，自动拆分含空格的元素。
-- 使用逐口 list ports（delete 后 add_list），避免 c:set 表变成单行 list 或 option。
-- @param c        uci.cursor
-- @param dev_sid  string  network.device section 名
-- @param ports    table   端口字符串数组
local function set_bridge_ports(c, dev_sid, ports)
    local clean = {}
    local seen = {}
    for _, p in ipairs(ports) do
        for token in tostring(p):gmatch("%S+") do
            if not seen[token] then
                seen[token] = true
                clean[#clean + 1] = token
            end
        end
    end
    c:delete("network", dev_sid, "ports")
    if #clean == 0 then return end
    if c.set_list then
        c:set_list("network", dev_sid, "ports", clean)
    elseif c.add_list then
        for _, token in ipairs(clean) do
            c:add_list("network", dev_sid, "ports", token)
        end
    else
        -- 无 set_list/add_list 时，libuci 的 c:set 接受 table 会写成 list
        c:set("network", dev_sid, "ports", clean)
    end
end

--- 处理 RPC 请求中的 ifaces 端口绑定变更，将指定有线端口迁移到目标桥。
-- 需要 libcable 提供端口名到设备的映射。
-- @param c        uci.cursor
-- @param network  string
-- @param ifaces   table  [{ conn_type, name }, ...]
-- @param vlan_id  number|nil
-- @return boolean  是否发生了变更
local function handle_port_binding(c, network, ifaces, vlan_id)
    local ok_lc, libcable = pcall(require, "libcable")
    if not ok_lc or not libcable then return false end
    local changed = false

    local port_map = libcable.get_ports_list_from_map and libcable.get_ports_list_from_map() or {}
    if #port_map == 0 then return false end

    local bridge = c:get("network", network, "device")
    if not bridge then return false end

    local name_to_dev = {}
    for _, info in ipairs(port_map) do
        if info.name then
            name_to_dev[info.name:upper()] = info.port or info.name
        end
        if info.silk then
            name_to_dev[info.silk:upper()] = info.port or info.name
        end
    end

    local wanted_ports = {}
    for _, iface in ipairs(ifaces) do
        if iface.conn_type == "wired" and iface.name then
            local dev = name_to_dev[iface.name:upper()]
            if dev then wanted_ports[dev] = true end
        end
    end

    local current_ports = {}
    c:foreach("network", "device", function(s)
        if s.name == bridge and s.ports then
            local ports = s.ports
            if type(ports) == "string" then ports = { ports } end
            for _, p in ipairs(ports) do
                for token in tostring(p):gmatch("%S+") do
                    local base = token:match("^([^:]+)")
                    if base then current_ports[base] = true end
                end
            end
        end
    end)

    for dev in pairs(wanted_ports) do
        if not current_ports[dev] then
            c:foreach("network", "device", function(s)
                if s.type == "bridge" and s.ports and s.name ~= bridge then
                    local ports = s.ports
                    if type(ports) == "string" then ports = { ports } end
                    local new_ports = {}
                    for _, p in ipairs(ports) do
                        if p ~= dev then new_ports[#new_ports + 1] = p end
                    end
                    if #new_ports ~= #ports then
                        set_bridge_ports(c, s[".name"], new_ports)
                    end
                end
            end)
            c:foreach("network", "device", function(s)
                if s.name == bridge then
                    local ports = s.ports or {}
                    if type(ports) == "string" then ports = { ports } end
                    ports[#ports + 1] = dev
                    set_bridge_ports(c, s[".name"], ports)
                end
            end)
            changed = true
        end
    end

    if network ~= "lan" then
        for dev in pairs(current_ports) do
            if not wanted_ports[dev] then
                c:foreach("network", "device", function(s)
                    if s.name == bridge and s.ports then
                        local ports = s.ports
                        if type(ports) == "string" then ports = { ports } end
                        local new_ports = {}
                        for _, p in ipairs(ports) do
                            if p ~= dev then new_ports[#new_ports + 1] = p end
                        end
                        set_bridge_ports(c, s[".name"], new_ports)
                    end
                end)
                c:foreach("network", "device", function(s)
                    if s.name == "br-lan" then
                        local ports = s.ports or {}
                        if type(ports) == "string" then ports = { ports } end
                        local found = false
                        for _, p in ipairs(ports) do
                            if p == dev then found = true; break end
                        end
                        if not found then
                            ports[#ports + 1] = dev
                            set_bridge_ports(c, s[".name"], ports)
                        end
                    end
                end)
                changed = true
            end
        end
    end

    return changed
end

--[[
@method-type: call
@method-name: get_subnets
@method-desc: Get all subnet list including fixed subnets (lan/guest/iot) and custom subnets (vlanN).

@out array   subnets                 Subnet info list
@out string  subnets.display_name    Display name of the subnet
@out string  subnets.network         UCI network interface name
@out boolean subnets.enabled         Whether the subnet is enabled
@out number  subnets.vlan_id         VLAN ID
@out string  subnets.ip              Interface IPv4 address (all subnet types; empty if L2-only / unset)
@out string  subnets.gateway        DHCP option 3 (default gateway for clients)
@out string  subnets.netmask         Subnet mask
@out boolean subnets.dhcp_enable     Whether DHCP server is enabled
@out string  subnets.dhcp_start_ip   DHCP pool start IP
@out string  subnets.dhcp_end_ip     DHCP pool end IP
@out number  subnets.dhcp_start      DHCP pool start offset
@out number  subnets.dhcp_limit      DHCP pool address count
@out string  subnets.leasetime       DHCP lease time
@out number  subnets.wan_access_mode       WAN access mode: 0=full, 1=block WAN private, 2=block all WAN
@out boolean subnets.isolate         Whether AP isolation is enabled
@out array   subnets.dns             Custom DNS server list
@out array   subnets.lpr             Custom LPR server list
@out array   subnets.ifaces          Bound interfaces list
@out string  subnets.ifaces.name     Interface display name
@out string  subnets.ifaces.conn_type Connection type: "wired" or "wifi"
@out string  subnets.ifaces.state    Link state: "up" or "down"
@out number  ?err_code               Error code
@out string  ?err_msg                Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","get_subnets",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{"subnets":[{"display_name":"main","network":"lan","enabled":true,"vlan_id":1,"ip":"192.168.8.1","gateway":"","netmask":"255.255.255.0","dhcp_enable":true,"dhcp_start_ip":"192.168.8.100","dhcp_end_ip":"192.168.8.249","dhcp_start":100,"dhcp_limit":150,"leasetime":"12h","wan_access_mode":0,"isolate":false,"dns":[],"lpr":[],"ifaces":[]}]}]}
--]]
function M.get_subnets()
    local c = uci.cursor()
    local subnets = {}

    for _, network in ipairs(FIXED_SUBNETS) do
        if c:get("network", network) then
            subnets[#subnets + 1] = get_subnet_info(c, network)
        end
    end

    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name:match("^vlan%d+$") then
            subnets[#subnets + 1] = get_subnet_info(c, name)
        end
    end)

    c:close()
    return { subnets = subnets }
end

--[[
@method-type: call
@method-name: sync_port_map
@method-desc: Manually trigger port map regeneration and tertf subnet synchronization.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","sync_port_map",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.sync_port_map()
    post_subnet_change()
    return {}
end

--[[
@method-type: call
@method-name: list_all
@method-desc: List all subnets with display_name and vlan_id (used as library function).

@out array   subnets               Subnet summary list
@out string  subnets.display_name  Display name of the subnet
@out number  subnets.vlan_id       VLAN ID

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","list_all",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[ [{"display_name":"main","vlan_id":1},{"display_name":"guest","vlan_id":9},{"display_name":"iot","vlan_id":10}] ]}
--]]
function M.list_all()
    local c = uci.cursor()
    local list = {}
    for _, name in ipairs(FIXED_SUBNETS) do
        if c:get("network", name) then
            list[#list + 1] = {
                display_name = get_display_name(c, name),
                vlan_id = get_vlan_id_for_network(c, name) or 0,
            }
        end
    end
    c:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name:match("^vlan%d+$") then
            list[#list + 1] = {
                display_name = get_display_name(c, name),
                vlan_id = get_vlan_id_for_network(c, name) or 0,
            }
        end
    end)
    c:close()
    return list
end

--[[
@method-type: call
@method-name: vlan_id_exists
@method-desc: Check whether a VLAN ID is already occupied by any subnet or WAN configuration (used as library function).

@in number  vlan_id  VLAN ID to check

@out boolean  result  true if VLAN ID is already in use

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","vlan_id_exists",{"vlan_id":9}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[true]}
--]]
function M.vlan_id_exists(vlan_id)
    if not vlan_id or type(vlan_id) ~= "number" then return false end
    local c = uci.cursor()
    local all = get_all_subnet_networks(c)
    for _, net in ipairs(all) do
        if get_vlan_id_for_network(c, net) == vlan_id then
            c:close()
            return true
        end
    end
    local wan_vlanid = c:get("glconfig", "general", "wan")
    if wan_vlanid and tonumber(wan_vlanid) == vlan_id then c:close(); return true end
    local sw_vlanid = c:get("glconfig", "general", "secondwan")
    c:close()
    return sw_vlanid and tonumber(sw_vlanid) == vlan_id
end

--[[
@method-type: call
@method-name: set_fixed_subnet
@method-desc: Modify a fixed subnet (lan/guest/iot). **ip** always means the interface address when present. **gateway** always means DHCP option 3 when **ip** is also present (guest/iot); for **lan** it is always DHCP option 3. Legacy: guest/iot with **gateway** only still sets both interface and option 3 to that value. When **ip** is omitted, lan may use **gateway** to set the interface if ipaddr is still empty. "" on guest/iot clears L2 when only one of ip/gateway is sent (see code paths).

@in string   display_name       Subnet identifier: "main", "guest" or "iot"
@in string   ?ip                Interface IP (lan / guest / iot); takes precedence over gateway for the interface on guest/iot
@in string   ?gateway           DHCP option 3 for clients; on lan also used to seed interface ipaddr if empty and ip omitted; legacy guest/iot-only gateway updates interface + option 3
@in string   ?netmask           Subnet mask (any valid contiguous mask /1-/30)
@in number   ?vlan_id           New VLAN ID (guest/iot only, 9-4000)
@in boolean  ?enabled           Enable/disable the subnet (not applicable to lan)
@in boolean  ?dhcp_enable       Enable/disable DHCP server
@in string   ?dhcp_start_ip     DHCP pool start IP (mutually exclusive with dhcp_start/dhcp_limit)
@in string   ?dhcp_end_ip       DHCP pool end IP (mutually exclusive with dhcp_start/dhcp_limit)
@in number   ?dhcp_start        DHCP pool start offset (mutually exclusive with dhcp_start_ip/dhcp_end_ip)
@in number   ?dhcp_limit        DHCP pool address count (mutually exclusive with dhcp_start_ip/dhcp_end_ip)
@in string   ?leasetime         DHCP lease time, e.g. "12h", "30m"
@in array    ?dns               Custom DNS server list
@in array    ?lpr               Custom LPR server list
@in number   ?wan_access_mode         WAN access mode: 0=full, 1=block WAN private, 2=block all WAN
@in boolean  ?isolate           Enable AP isolation (alias: ap_isolate)
@in array    ?ifaces            Port binding list
@in string   ?ifaces.conn_type  Connection type: "wired" or "wifi"
@in string   ?ifaces.name       Port display name

@out number  ?err_code          Error code
@out string  ?err_msg           Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","set_fixed_subnet",{"display_name":"main","ip":"192.168.8.1","netmask":"255.255.255.0","dhcp_enable":true}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.set_fixed_subnet(params)
    -- ===== 阶段1: 参数解析与校验 =====
    local c = uci.cursor()

    -- 1.1 display_name 映射为 UCI 网络名（main->lan, guest->guest, iot->iot）
    local display_name = params.display_name or params.name
    local network = NETWORK_MAP[display_name]
    if not network then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid display_name")
    end

    -- 1.2 S2S/TAP 阻塞检查
    local blocked = check_tap_s2s_blocked(c)
    if blocked then c:close(); return blocked end

    -- 1.3 读取当前 UCI 中的 IP 和掩码
    local current_gw = c:get("network", network, "ipaddr") or ""
    local current_nm = c:get("network", network, "netmask") or ""

    -- 1.4 判定是否动了 L3 配置（ip/gateway/netmask 任一非 nil）
    local l3_touch
    if network == "lan" then
        l3_touch = (params.ip ~= nil) or (params.gateway ~= nil) or rpc_dhcp_field_present(params.netmask)
    else
        l3_touch = (params.ip ~= nil) or (params.gateway ~= nil) or rpc_dhcp_field_present(params.netmask)
    end

    -- 1.5 确定新 IP
    --     lan:      params.ip 优先 → params.gateway 兜底（仅当前无 ipaddr 时）
    --     guest/iot: params.ip 优先 → params.gateway 兜底 → "" 表示清空 L3
    local new_gw
    if network == "lan" then
        if params.ip ~= nil then
            if type(params.ip) == "string" and params.ip:match("^%s*$") then
                new_gw = ""
            else
                new_gw = params.ip
            end
        elseif rpc_dhcp_field_present(params.gateway) and (not current_gw or current_gw == "") then
            -- 与客用子网一致：仅传 gateway 时视为接口地址；仅在当前尚无 ipaddr 时采用（避免把 DHCP option 3 误写成接口 IP）
            new_gw = params.gateway
        else
            new_gw = current_gw
        end
    else
        if params.ip ~= nil then
            if type(params.ip) == "string" and params.ip:match("^%s*$") then
                new_gw = ""
            else
                new_gw = params.ip
            end
        elseif params.gateway ~= nil then
            if type(params.gateway) == "string" and params.gateway:match("^%s*$") then
                new_gw = ""
            else
                new_gw = params.gateway
            end
        else
            new_gw = current_gw
        end
    end
    local new_nm = params.netmask or current_nm

    -- 1.6 guest/iot 清空 L3 的判断（ip 或 gateway 传了空字符串）
    local gw_clear_guest = network ~= "lan" and (
        (params.ip ~= nil and type(params.ip) == "string" and params.ip:match("^%s*$"))
        or (params.ip == nil and params.gateway ~= nil and type(params.gateway) == "string" and params.gateway:match("^%s*$"))
    )

    if gw_clear_guest and params.dhcp_enable == true then
        c:close()
        return rpc_error(ERR_DHCP_INVALID, "DHCP requires interface IP")
    end

    -- 1.7 校验: IP 格式 + 私有地址 + 子网冲突（WAN + 所有子网）
    if l3_touch then
        if network == "lan" then
            if not new_gw or new_gw == "" then
                c:close()
                return rpc_error(ERR_INVALID_PARAMS, "requires ip for L3 update")
            end
        end
        if new_gw and new_gw ~= "" then
            if not validate_gateway(new_gw) then
                c:close()
                return rpc_error(ERR_INVALID_PARAMS, network == "lan" and "invalid ip" or "invalid gateway")
            end
            if network == "lan" and params.gateway ~= nil and params.gateway ~= "" then
                if not validate_gateway(params.gateway) then
                    c:close()
                    return rpc_error(ERR_INVALID_PARAMS, "invalid gateway")
                end
            end
            local has_conflict, conflict_network = check_subnet_conflict(c, new_gw, new_nm, network)
            if has_conflict then
                local err = subnet_conflict_rpc_error(c, conflict_network)
                c:close()
                return err
            end
        end
    end

    -- 1.8 校验: 掩码格式（连续掩码 /1~30）
    if params.netmask and not gw_clear_guest and not validate_netmask(params.netmask) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid netmask")
    end

    -- 1.9 校验: VLAN ID 范围 + 冲突（仅 guest/iot）
    local new_vlan_id = params.vlan_id and tonumber(params.vlan_id) or nil
    local old_vlan_id = get_vlan_id_for_network(c, network)
    if new_vlan_id then
        if network == "lan" then
            c:close()
            return rpc_error(ERR_INVALID_PARAMS, "cannot change vlan_id for main network")
        end
        if not check_vlan_id_range(new_vlan_id) then
            c:close()
            return rpc_error(ERR_VLAN_ID_OUT_OF_RANGE, "vlan_id out of range")
        end
        if new_vlan_id ~= old_vlan_id and check_vlan_id_conflict(c, new_vlan_id, network) then
            c:close()
            return rpc_error(ERR_VLAN_ID_CONFLICT, "vlan_id conflict")
        end
    end

    -- 1.10 校验: DHCP 地址池范围
    -- DHCP 关闭时前端仍可能带旧网段绝对起止 IP；勿用新接口 IP 校验，沿用 UCI start/limit。
    local dhcp_start, dhcp_limit
    -- DHCP 关闭时前端仍可能带旧网段绝对起止 IP；勿用新接口 IP 校验，沿用 UCI start/limit。
    local skip_dhcp_pool_rpc = params.dhcp_enable == false
    if not skip_dhcp_pool_rpc and params.dhcp_enable == nil then
        local dhcp_sid_ignore = find_dhcp_section(c, network)
        skip_dhcp_pool_rpc = dhcp_sid_ignore and c:get("dhcp", dhcp_sid_ignore, "ignore") == "1"
    end
    local parsed_start, parsed_limit, parsed_err
    if skip_dhcp_pool_rpc then
        parsed_start, parsed_limit, parsed_err = nil, nil, nil
    else
        parsed_start, parsed_limit, parsed_err = parse_dhcp_range_params(params, new_gw, new_nm)
    end
    if parsed_err then
        c:close()
        return rpc_error(ERR_DHCP_INVALID, parsed_err)
    end
    if parsed_start and parsed_limit then
        dhcp_start, dhcp_limit = parsed_start, parsed_limit
    else
        local dhcp_sid = find_dhcp_section(c, network)
        dhcp_start = dhcp_sid and tonumber(c:get("dhcp", dhcp_sid, "start")) or nil
        dhcp_limit = dhcp_sid and tonumber(c:get("dhcp", dhcp_sid, "limit")) or nil
    end

    local leasetime = normalize_leasetime(params.leasetime)

    local wan_access_mode = tonumber(params.wan_access_mode)
    local isolate_req = resolve_isolate_param(params)

    -- ===== 阶段2: UCI 写入 =====

    -- 2.1 写入 network.<net>.ipaddr / netmask / proto
    if network == "lan" then
        if params.ip ~= nil then
            if type(params.ip) == "string" and params.ip:match("^%s*$") then
                c:close()
                return rpc_error(ERR_INVALID_PARAMS, "requires ip for L3 update")
            elseif params.ip ~= current_gw then
                c:set("network", network, "proto", "static")
                c:set("network", network, "ipaddr", params.ip)
            end
        elseif rpc_dhcp_field_present(params.gateway) and (not current_gw or current_gw == "") then
            if params.gateway ~= current_gw then
                c:set("network", network, "proto", "static")
                c:set("network", network, "ipaddr", params.gateway)
            end
        end
    else
        if params.ip ~= nil then
            if type(params.ip) == "string" and params.ip:match("^%s*$") then
                c:set("network", network, "proto", "none")
                c:delete("network", network, "ipaddr")
                c:delete("network", network, "netmask")
            elseif params.ip ~= current_gw then
                c:set("network", network, "proto", "static")
                c:set("network", network, "ipaddr", params.ip)
            end
        end
        if params.gateway ~= nil and params.ip == nil then
            if type(params.gateway) == "string" and params.gateway:match("^%s*$") then
                c:set("network", network, "proto", "none")
                c:delete("network", network, "ipaddr")
                c:delete("network", network, "netmask")
            elseif params.gateway ~= current_gw then
                c:set("network", network, "proto", "static")
                c:set("network", network, "ipaddr", params.gateway)
            end
        end
    end

    -- 2.2 写入 VLAN ID + enable/disable
    if params.netmask and params.netmask ~= current_nm and not gw_clear_guest then
        c:set("network", network, "netmask", params.netmask)
    end
    if new_vlan_id and new_vlan_id ~= old_vlan_id then
        c:set("network", network, "vlan_id", tostring(new_vlan_id))
    end
    if params.enabled ~= nil and network ~= "lan" then
        if params.enabled then
            c:delete("network", network, "disabled")
        else
            c:set("network", network, "disabled", "1")
        end
    end

    -- 2.3 写入 DHCP 配置（ignore/start/limit/leasetime/option 3/6/9）
    if params.dhcp_enable ~= nil or dhcp_start or dhcp_limit or
       leasetime or params.dns or params.lpr or l3_touch or params.gateway ~= nil or params.ip ~= nil then
        local dhcp_err = set_dhcp_config(c, network, {
            dhcp_enable = gw_clear_guest and false or params.dhcp_enable,
            dhcp_start = dhcp_start,
            dhcp_limit = dhcp_limit,
            leasetime = leasetime,
            dns = params.dns,
            lpr = params.lpr,
            dhcp_gateway = (params.gateway ~= nil) and params.gateway or nil,
        })
        if dhcp_err then
            c:close()
            return rpc_error(ERR_INVALID_PARAMS, dhcp_err)
        end
    end

    -- ===== 阶段3: 防火墙规则、端口绑定、Tor 重定向 =====

    -- 3.1 WAN 访问模式 + firewall zone/forwarding
    local fw_changed = false
    if wan_access_mode ~= nil or isolate_req ~= nil then
        set_wan_access_mode(c, network, wan_access_mode)
        fw_changed = true
    end

    -- 3.2 端口绑定（ifaces -> handle_port_binding）
    if params.ifaces and type(params.ifaces) == "table" then
        handle_port_binding(c, network, params.ifaces, params.vlan_id)
    end

    -- 3.3 [仅 lan] Tor redirect src_ip/src_dip 同步
    -- tor.lua 的 tor_on 使用 lan.ipaddr/netmask 生成规则，IP/掩码变化后需更新
    if network == "lan" and l3_touch and new_gw and new_gw ~= "" and new_nm and new_nm ~= "" then
        local lan_info = lnet.ipcalc({ new_gw, new_nm })
        local prefix = lan_info and lan_info.prefix or nil
        if prefix then
            local src_ip = new_gw .. "/" .. tostring(prefix)
            local tor_fw_touched = false
            for _, sid in ipairs({
                "tor_allow_http",
                "tor_allow_https",
                "tor_allow_luci_http",
                "tor_allow_luci_https",
                "tor_allow_adguardhome",
                "tor_allow_ssh",
            }) do
                if c:get("firewall", sid) then
                    c:set("firewall", sid, "src_ip", src_ip)
                    c:set("firewall", sid, "src_dip", new_gw)
                    tor_fw_touched = true
                end
            end
            if tor_fw_touched then fw_changed = true end
        end
    end

    -- 3.4 [L3 变动] 自定义防火墙 block_forward_to_* 规则更新
    --     lan: 更新所有非 lan 子网的规则
    --     非lan: 仅更新当前子网的规则
    if l3_touch then
        if network == "lan" then
            for _, net in ipairs(get_all_subnet_networks(c)) do
                if net ~= "lan" then
                    ensure_custom_firewall_rules(c, net)
                end
            end
            fw_changed = true
        else
            ensure_custom_firewall_rules(c, network)
            fw_changed = true
        end
    end

    -- 3.5 [VLAN ID 变动] 提前 commit + post_subnet_change + cable 联动
    if new_vlan_id and old_vlan_id and new_vlan_id ~= old_vlan_id then
        c:commit("network")
        fs.sync()
        post_subnet_change()
        apply_cable_for_vlan_id_change(old_vlan_id, new_vlan_id)
    end

    -- ===== 阶段4: 根据变化类型走不同分支 =====
    local lan_ip_changed = network == "lan" and l3_touch and new_gw and new_gw ~= "" and new_gw ~= current_gw
    if lan_ip_changed then
        -- ===== 分支 A: LAN IP 变化 =====
        -- A.1 若传了 isolate 参数，同步 AP isolate UCI (gl-black_white_list.lan.ap_isolate)
        local iso = isolate_req
        local iso_num = nil
        if iso ~= nil then
            local on = normalize_bool_param(iso)
            if on ~= nil then
                iso_num = on and 1 or 0
                if fs.access("/etc/config/gl-black_white_list") then
                    if not c:get("gl-black_white_list", "lan") then
                        c:set("gl-black_white_list", "lan", "secure_option")
                    end
                    c:set("gl-black_white_list", "lan", "ap_isolate", on and "1" or "0")
                end
                c:set("network", "lan", "isolate", tostring(iso_num))
            end
        end

        -- A.2 commit 所有 UCI 配置
        c:set("dhcp", "@domain[0]", "ip", new_gw)
        c:set("dhcp", "@domain[1]", "ip", '::ffff:' .. new_gw)
        c:commit("network")
        c:commit("dhcp")
        c:commit("firewall")
        if fs.access("/etc/config/gl-black_white_list") then
            c:commit("gl-black_white_list")
        end

        -- A.3 MCU 通知
        ngx.pipe.spawn(". /lib/functions/gl_util.sh;mcu_send_message \"LAN IP change\"")

        -- A.5 重新签发 SSL 证书（nginx + webdav）
        do
            local gl_conf = "/etc/ssl/gl.conf"
            if fs.access(gl_conf) then
                os.execute(string.format(
                    "sed -i 's/^IP\\.1[[:space:]]*=.*/IP.1                = %s/' %s 2>/dev/null",
                    new_gw, gl_conf
                ))
            end
            local genkey
            if fs.access("/usr/bin/openssl") then
                genkey = "/usr/bin/openssl req -x509 -nodes"
            elseif fs.access("/usr/sbin/px5g") then
                genkey = "/usr/sbin/px5g selfsigned"
            end
            if genkey then
                local exec_result = os.execute(string.format(
                    '%s -days 730 -newkey rsa:2048 -keyout "/etc/nginx/nginx.key" -out "/etc/nginx/nginx.cer" -config "/etc/ssl/gl.conf" >/dev/null 2>&1',
                    genkey
                ))
                if exec_result == 0 and fs.access("/etc/config/gl_nas/ssl_webdav.pem") then
                    os.execute("cat /etc/nginx/nginx.key /etc/nginx/nginx.cer > /etc/config/gl_nas/ssl_webdav.pem")
                end
            end
        end
        fs.sync()
        post_subnet_change()

        -- A.6 若有 isolate 参数，同步调用 ap_isolate_config.lua
        if iso_num ~= nil and fs.access("/etc/ap_isolate_config.lua") then
            ngx.pipe.spawn({ "lua", "/etc/ap_isolate_config.lua", "lan", tostring(iso_num) }):wait()
        end

        -- A.7 延迟 1 秒后异步执行服务重载和客户端踢出
        local ap_iso_reload = iso_num == 1
        ngx.timer.at(1, function()
            local tc = uci.cursor()

            -- a. network reload（接口应用新 IP，bridge 重建）
            pcall(function() ubus.call("network", "reload") end)

            -- b. 同步路由
            pcall(function() ngx.pipe.spawn(". /lib/functions/kmwan.sh;sync_route_netcell"):wait() end)
            if ngx and ngx.sleep then
                ngx.sleep(2.0)
            else
                os.execute("sleep 2")
            end

            -- c. firewall reload
            pcall(function() ngx.pipe.spawn({ "/etc/init.d/firewall", "reload" }):wait() end)

            -- d. dnsmasq reload（DHCP/DNS 应用新配置）
            pcall(function() ngx.pipe.spawn({ "/etc/init.d/dnsmasq", "reload" }):wait() end)
            if ap_iso_reload then
                pcall(function() ngx.pipe.spawn({ "/etc/init.d/gl-black_white_list", "reload" }):wait() end)
            end

            -- d2. 通知 Mesh 同步配置（dnsmasq 已 reload，Agent 拉取的是新配置）
            notify_mesh_lan_config_renew(tc)

            -- e. LAN 口 down/up（有线客户端链路重置，触发 DHCP 重获取）
            do
                local device = tc:get("network", "lan", "device")
                if device then
                    local ports
                    tc:foreach("network", "device", function(s)
                        if s.name == device then
                            if type(s.ports) == "string" then
                                s.ports = { s.ports }
                            end
                            ports = s.ports
                            return false
                        end
                    end)
                    for _, port in ipairs(ports or {}) do
                        pcall(function() ngx.pipe.spawn({ "/sbin/ip", "link", "set", port, "down" }):wait() end)
                    end
                    if ngx and ngx.sleep then
                        ngx.sleep(1.0)
                    else
                        os.execute("sleep 1")
                    end
                    for _, port in ipairs(ports or {}) do
                        pcall(function() ngx.pipe.spawn({ "/sbin/ip", "link", "set", port, "up" }):wait() end)
                    end
                end
            end

            -- f. WiFi 客户端踢出 + hairpin_mode 恢复
            ngx.pipe.spawn(". /lib/functions/gl_util.sh; kick_ap_clients_by_network lan; restore_hairpin_mode lan")

            -- g. 交换机/ USB LAN 重启
            if hardware then
                hardware.platform_switch_restart()
                hardware.platform_usb_lan_restart()
            end

            -- h. [tap-s2s] HUP ovpnserver 重启
            pcall(function()
                local ovpn_type = tc:get("ovpnserver", "vpn", "dev_type")
                if ovpn_type == "tap-s2s" then
                    ngx.pipe.spawn({ "sh", "-c", "kill -HUP $(cat /var/run/ovpnserver-ovpnserver.pid)" }):wait()
                end
            end)

            -- i. [ecm] 向 sysfs 写入 brport/isolated 隔离状态
            if fs.access("/etc/config/ecm") and iso_num ~= nil then
                local v = iso_num
                tc:foreach("wireless", "wifi-iface", function(s)
                    if s.network == "lan" and s.ifname then
                        os.execute("echo " .. v .. " > /sys/class/net/" .. s.ifname .. "/brport/isolated")
                    end
                end)
            end
            post_subnet_change()
            tc:close()
        end)
    else
        -- ===== 分支 B: 非 LAN IP 变化（掩码/isolate 变化、guest/iot 配置变化等） =====
        if network == "lan" and isolate_req ~= nil then
            local on = normalize_bool_param(isolate_req)
            if on ~= nil then
                local iso_num = on and 1 or 0
                if fs.access("/etc/config/gl-black_white_list") then
                    if not c:get("gl-black_white_list", "lan") then
                        c:set("gl-black_white_list", "lan", "secure_option")
                    end
                    c:set("gl-black_white_list", "lan", "ap_isolate", on and "1" or "0")
                end
                c:set("network", "lan", "isolate", tostring(iso_num))
            end
        end

        -- commit + network reload + dnsmasq restart + firewall reload
        apply_network_changes(c, fw_changed)

        if isolate_req ~= nil then
            set_ap_isolate(c, network, isolate_req, true, true)
        end

        notify_mesh_lan_config_renew(c)

        ngx.timer.at(1, function()
            -- WiFi客户端踢出
            ngx.pipe.spawn(". /lib/functions/gl_util.sh; kick_ap_clients_by_network " .. network)

            -- 交换机端口复位
            local tc = uci.cursor()
            reset_gsw_ports(tc, network)
            tc:close()
        end)
    end

    c:close()
    return {}
end

local function utf8_char_len(s)
    local i = 1
    local len = #s
    local count = 0

    while i <= len do
        local c = s:byte(i)

        -- 1-byte: 0xxxxxxx
        if c <= 0x7F then
            i = i + 1

        -- 2-byte: 110xxxxx 10xxxxxx
        elseif c >= 0xC2 and c <= 0xDF then
            if i + 1 > len then return nil end
            local c2 = s:byte(i + 1)
            if c2 < 0x80 or c2 > 0xBF then return nil end
            i = i + 2

        -- 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
        elseif c >= 0xE0 and c <= 0xEF then
            if i + 2 > len then return nil end
            local c2 = s:byte(i + 1)
            local c3 = s:byte(i + 2)
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then
                return nil
            end
            i = i + 3

        -- 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        elseif c >= 0xF0 and c <= 0xF4 then
            if i + 3 > len then return nil end
            local c2 = s:byte(i + 1)
            local c3 = s:byte(i + 2)
            local c4 = s:byte(i + 3)
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then
                return nil
            end
            i = i + 4

        else
            return nil
        end

        count = count + 1
    end

    return count
end

--[[
@method-type: call
@method-name: add_custom_subnet
@method-desc: Create a custom subnet (vlanN). Pass **ip** or **gateway** (mutually exclusive unless equal) for the interface address when L3 is needed. Omit both for L2-only (proto none, DHCP off).

@in number   vlan_id            VLAN ID (9-4000, required)
@in string   ?ip                Interface IP (optional; alias of gateway)
@in string   ?gateway           Interface IP (optional; legacy alias of ip)
@in string   ?netmask           Subnet mask (default "255.255.255.0")
@in string   ?display_name      Display name (default: vlanN)
@in boolean  ?enabled           Enable the subnet (default true)
@in boolean  ?dhcp_enable       Enable DHCP server (default true)
@in string   ?dhcp_start_ip     DHCP pool start IP (mutually exclusive with dhcp_start/dhcp_limit)
@in string   ?dhcp_end_ip       DHCP pool end IP (mutually exclusive with dhcp_start/dhcp_limit)
@in number   ?dhcp_start        DHCP pool start offset (mutually exclusive with dhcp_start_ip/dhcp_end_ip)
@in number   ?dhcp_limit        DHCP pool address count (mutually exclusive with dhcp_start_ip/dhcp_end_ip)
@in string   ?leasetime         DHCP lease time, e.g. "12h"
@in array    ?dns               Custom DNS server list
@in array    ?lpr               Custom LPR server list
@in number   ?wan_access_mode         WAN access mode: 0=full, 1=block WAN private, 2=block all WAN (default 0)
@in boolean  ?isolate           Enable AP isolation (alias: ap_isolate)

@out number  ?err_code          Error code
@out string  ?err_msg           Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","add_custom_subnet",{"vlan_id":100,"display_name":"office"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.add_custom_subnet(params)
    local c = uci.cursor()

    local blocked = check_tap_s2s_blocked(c)
    if blocked then c:close(); return blocked end

    if count_custom_subnets(c) >= MAX_CUSTOM_SUBNETS then
        c:close()
        return rpc_error(ERR_SUBNET_LIMIT_EXCEEDED, "max " .. MAX_CUSTOM_SUBNETS .. " custom subnets")
    end

    local vlan_id = tonumber(params.vlan_id)
    if not vlan_id or not check_vlan_id_range(vlan_id) then
        c:close()
        return rpc_error(ERR_VLAN_ID_OUT_OF_RANGE, "vlan_id must be " .. VLAN_ID_MIN .. "-" .. VLAN_ID_MAX)
    end
    if check_vlan_id_conflict(c, vlan_id) then
        c:close()
        return rpc_error(ERR_VLAN_ID_CONFLICT, "vlan_id conflict")
    end

    if rpc_dhcp_field_present(params.ip) and rpc_dhcp_field_present(params.gateway) and params.ip ~= params.gateway then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "ip and gateway conflict for interface address")
    end
    local iface_for_subnet = rpc_dhcp_field_present(params.ip) and params.ip
        or rpc_dhcp_field_present(params.gateway) and params.gateway
        or nil
    local has_l3 = iface_for_subnet ~= nil
    if has_l3 and not validate_gateway(iface_for_subnet) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid ip or gateway")
    end
    if not has_l3 and params.dhcp_enable == true then
        c:close()
        return rpc_error(ERR_DHCP_INVALID, "DHCP requires interface IP (gateway)")
    end

    local netmask = params.netmask or "255.255.255.0"
    if has_l3 and not validate_netmask(netmask) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid netmask")
    end

    local network = get_network_name_for_vlan(vlan_id)
    local bridge = get_bridge_for_custom(vlan_id)

    if has_l3 then
        local has_conflict, conflict_network = check_subnet_conflict(c, iface_for_subnet, netmask, network)
        if has_conflict then
            local err = subnet_conflict_rpc_error(c, conflict_network)
            c:close()
            return err
        end
    end

    local display_name = params.display_name or params.name or network
    local name_len = utf8_char_len(display_name)

    if name_len and name_len > 32 then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "display_name length must be less than 32")
    end

    if display_name_exists(c, display_name) then
        c:close()
        return rpc_error(ERR_DISPLAY_NAME_CONFLICT, "display_name conflict")
    end

    local dhcp_start, dhcp_limit
    local gw_for_dhcp = has_l3 and iface_for_subnet or ""
    local parsed_start, parsed_limit, parsed_err
    if params.dhcp_enable == false then
        parsed_start, parsed_limit, parsed_err = nil, nil, nil
    else
        parsed_start, parsed_limit, parsed_err = parse_dhcp_range_params(params, gw_for_dhcp, netmask)
    end
    if parsed_err then
        c:close()
        return rpc_error(ERR_DHCP_INVALID, parsed_err)
    end
    if parsed_start and parsed_limit then
        dhcp_start, dhcp_limit = parsed_start, parsed_limit
    else
        dhcp_start = 100
        dhcp_limit = 150
    end

    local leasetime = normalize_leasetime(params.leasetime) or "12h"

    -- 只创建独立桥，不在 br-lan 上创建 bridge-vlan
    ensure_bridge_device(c, bridge)

    c:set("network", network, "interface")
    c:set("network", network, "device", bridge)
    if has_l3 then
        c:set("network", network, "proto", "static")
        c:set("network", network, "ipaddr", iface_for_subnet)
        c:set("network", network, "netmask", netmask)
    else
        c:set("network", network, "proto", "none")
        c:delete("network", network, "ipaddr")
        c:delete("network", network, "netmask")
    end
    c:set("network", network, "display_name", display_name)
    c:set("network", network, "vlan_id", tostring(vlan_id))

    if params.enabled == false then
        c:set("network", network, "disabled", "1")
    end

    do
        local dhcp_err = set_dhcp_config(c, network, {
            dhcp_enable = has_l3 and (params.dhcp_enable ~= false) or false,
            dhcp_start = dhcp_start,
            dhcp_limit = dhcp_limit,
            leasetime = leasetime,
            dns = params.dns,
            lpr = params.lpr,
        })
        if dhcp_err then
            c:close()
            return rpc_error(ERR_INVALID_PARAMS, dhcp_err)
        end
    end

    local wan_access_mode = tonumber(params.wan_access_mode) or 0

    set_wan_access_mode(c, network, wan_access_mode)
    ensure_custom_firewall_rules(c, network)

    local isolate_req_add = resolve_isolate_param(params)

    update_parental_control(network, "add")
    ngx.pipe.spawn({"/etc/init.d/parental_control", "restart"})
    -- 与 iot 一致：新建自定义子网时在 route_policy.global 增加 append_source_if。
    if fs.access("/etc/config/route_policy") and c:get("route_policy", "global") then
        os.execute("uci -q delete route_policy.gl_vlan_custom_subnet_novpn 2>/dev/null; uci -q commit route_policy")
        local dup = false
        local pr = io.popen("uci show route_policy.global 2>/dev/null")
        if pr then
            for line in pr:lines() do
                local v = line:match("append_source_if='([^']+)'")
                if v == network then
                    dup = true
                    break
                end
            end
            pr:close()
        end
        if not dup then
            os.execute(
                "uci -q add_list route_policy.global.append_source_if='" .. network .. "' && uci -q commit route_policy"
            )
        end
    end
    apply_network_changes(c)
    if fs.access("/etc/init.d/vpn-client") then
        os.execute("/etc/init.d/vpn-client enabled >/dev/null 2>&1 && /etc/init.d/vpn-client start >/dev/null 2>&1")
    end
    schedule_gl_eqos_restart_after_br_vlan_change()

    if normalize_bool_param(isolate_req_add) == true then
        set_ap_isolate(c, network, true, false, true)
    end

    c:close()
    return {}
end


--[[
@method-type: call
@method-name: update_custom_subnet
@method-desc: Update a custom subnet. Locate by name/display_name. **ip** sets the interface address when present (preferred); **gateway** is DHCP option 3 when **ip** is also set; legacy gateway-only updates interface and option 3 together. Same L2 clear rules as set_fixed_subnet guest/iot.

@in string   name               Current display name to locate the subnet (required)
@in string   ?display_name      New display name (for renaming)
@in string   ?ip                Interface IP (optional; preferred for writes matching get_subnets)
@in string   ?gateway           DHCP option 3, or legacy combined interface+option3 when ip omitted
@in string   ?netmask           New subnet mask
@in number   ?vlan_id           New VLAN ID (9-4000, triggers re-creation if changed)
@in boolean  ?enabled           Enable/disable the subnet
@in boolean  ?dhcp_enable       Enable/disable DHCP server
@in string   ?dhcp_start_ip     DHCP pool start IP (mutually exclusive with dhcp_start/dhcp_limit)
@in string   ?dhcp_end_ip       DHCP pool end IP (mutually exclusive with dhcp_start/dhcp_limit)
@in number   ?dhcp_start        DHCP pool start offset (mutually exclusive with dhcp_start_ip/dhcp_end_ip)
@in number   ?dhcp_limit        DHCP pool address count (mutually exclusive with dhcp_start_ip/dhcp_end_ip)
@in string   ?leasetime         DHCP lease time
@in array    ?dns               Custom DNS server list
@in array    ?lpr               Custom LPR server list
@in number   ?wan_access_mode         WAN access mode: 0=full, 1=block WAN private, 2=block all WAN
@in boolean  ?isolate           Enable AP isolation (alias: ap_isolate)

@out number  ?err_code          Error code
@out string  ?err_msg           Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","update_custom_subnet",{"name":"office","gateway":"192.168.100.1","netmask":"255.255.255.0"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.update_custom_subnet(params)
    local c = uci.cursor()

    -- name 是当前子网标识（用于查找），display_name 可能是新名称
    -- 优先用 name 查找，如果 name 找不到再尝试 display_name
    local lookup_name = params.name or params.display_name
    if not lookup_name then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "display_name or name required")
    end

    local network = resolve_display_name_to_network(c, lookup_name)
    -- 如果用 name 找不到，且 display_name 存在且不同于 name，再尝试 display_name
    if not network and params.display_name and params.display_name ~= lookup_name then
        network = resolve_display_name_to_network(c, params.display_name)
    end
    if not network then
        c:close()
        return rpc_error(ERR_SUBNET_NOT_FOUND, "subnet not found")
    end
    if is_fixed_subnet(network) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "use set_fixed_subnet for fixed subnets")
    end

    -- 记录当前子网的 display_name，用于 VLAN ID 变更时保留
    local current_display_name = get_display_name(c, network)

    local blocked = check_tap_s2s_blocked(c)
    if blocked then c:close(); return blocked end

    local current_gw = c:get("network", network, "ipaddr")
    local current_nm = c:get("network", network, "netmask")

    local l3_touch = (params.ip ~= nil) or (params.gateway ~= nil) or rpc_dhcp_field_present(params.netmask)
    local new_gw
    if params.ip ~= nil then
        if type(params.ip) == "string" and params.ip:match("^%s*$") then
            new_gw = ""
        else
            new_gw = params.ip
        end
    elseif params.gateway ~= nil then
        if type(params.gateway) == "string" and params.gateway:match("^%s*$") then
            new_gw = ""
        else
            new_gw = params.gateway
        end
    else
        new_gw = current_gw
    end
    local new_nm = params.netmask or current_nm

    local gw_clear_custom = (params.ip ~= nil and type(params.ip) == "string" and params.ip:match("^%s*$"))
        or (params.ip == nil and params.gateway ~= nil and type(params.gateway) == "string" and params.gateway:match("^%s*$"))

    if gw_clear_custom and params.dhcp_enable == true then
        c:close()
        return rpc_error(ERR_DHCP_INVALID, "DHCP requires interface IP")
    end

    if l3_touch and new_gw and new_gw ~= "" and not validate_gateway(new_gw) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid gateway")
    end
    if params.netmask and not gw_clear_custom and not validate_netmask(params.netmask) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid netmask")
    end

    local new_vlan_id = params.vlan_id and tonumber(params.vlan_id) or nil
    local old_vlan_id = get_vlan_id_for_network(c, network)

    if new_vlan_id then
        if not check_vlan_id_range(new_vlan_id) then
            c:close()
            return rpc_error(ERR_VLAN_ID_OUT_OF_RANGE, "vlan_id out of range")
        end
        if new_vlan_id ~= old_vlan_id and check_vlan_id_conflict(c, new_vlan_id, network) then
            c:close()
            return rpc_error(ERR_VLAN_ID_CONFLICT, "vlan_id conflict")
        end
    end

    local effective_vlan = new_vlan_id or old_vlan_id
    local new_network = get_network_name_for_vlan(effective_vlan)

    if l3_touch and validate_gateway(new_gw) then
        local has_conflict, conflict_network = check_subnet_conflict(c, new_gw, new_nm, network)
        if has_conflict then
            local err = subnet_conflict_rpc_error(c, conflict_network)
            c:close()
            return err
        end
    end

    -- 需求约定：name 用于查找，display_name 用于重命名
    local new_display_name
    local name_len
    if params.display_name and params.display_name ~= lookup_name then
        new_display_name = params.display_name
        name_len = utf8_char_len(new_display_name)

        if name_len and name_len > 32 then
            c:close()
            return rpc_error(ERR_INVALID_PARAMS, "display_name length must be less than 32")
        end
    end

    if new_display_name and display_name_exists(c, new_display_name, new_network) then
        c:close()
        return rpc_error(ERR_DISPLAY_NAME_CONFLICT, "display_name conflict")
    end

    local dhcp_start, dhcp_limit
    -- DHCP 关闭时前端仍可能带旧网段绝对起止 IP；勿用新接口 IP 校验，沿用 UCI start/limit。
    local skip_dhcp_pool_rpc = params.dhcp_enable == false
    if not skip_dhcp_pool_rpc and params.dhcp_enable == nil then
        local dhcp_sid_ignore = find_dhcp_section(c, network)
        skip_dhcp_pool_rpc = dhcp_sid_ignore and c:get("dhcp", dhcp_sid_ignore, "ignore") == "1"
    end
    local parsed_start, parsed_limit, parsed_err
    if skip_dhcp_pool_rpc then
        parsed_start, parsed_limit, parsed_err = nil, nil, nil
    else
        parsed_start, parsed_limit, parsed_err = parse_dhcp_range_params(params, new_gw, new_nm)
    end
    if parsed_err then
        c:close()
        return rpc_error(ERR_DHCP_INVALID, parsed_err)
    end
    if parsed_start and parsed_limit then
        dhcp_start, dhcp_limit = parsed_start, parsed_limit
    else
        local old_dhcp_sid = find_dhcp_section(c, network)
        dhcp_start = old_dhcp_sid and tonumber(c:get("dhcp", old_dhcp_sid, "start")) or nil
        dhcp_limit = old_dhcp_sid and tonumber(c:get("dhcp", old_dhcp_sid, "limit")) or nil
    end

    local leasetime = normalize_leasetime(params.leasetime)

    local wan_access_mode = tonumber(params.wan_access_mode)
    local isolate_req = resolve_isolate_param(params)
    local ap_isolate_network = network

    if new_vlan_id and new_vlan_id ~= old_vlan_id then
        local old_dhcp_sid = find_dhcp_section(c, network)
        local old_start = dhcp_start or (old_dhcp_sid and tonumber(c:get("dhcp", old_dhcp_sid, "start")) or 100)
        local old_limit = dhcp_limit or (old_dhcp_sid and tonumber(c:get("dhcp", old_dhcp_sid, "limit")) or 150)
        local old_leasetime = old_dhcp_sid and c:get("dhcp", old_dhcp_sid, "leasetime") or "12h"
        local old_dns, old_lpr = get_dhcp_options(c, network)

        delete_subnet_config(c, network)

        local new_bridge = get_bridge_for_custom(effective_vlan)
        ensure_bridge_device(c, new_bridge)

        c:set("network", new_network, "interface")
        c:set("network", new_network, "device", new_bridge)
        if validate_gateway(new_gw) then
            c:set("network", new_network, "proto", "static")
            c:set("network", new_network, "ipaddr", new_gw)
            c:set("network", new_network, "netmask", new_nm)
        else
            c:set("network", new_network, "proto", "none")
            c:delete("network", new_network, "ipaddr")
            c:delete("network", new_network, "netmask")
        end
        c:set("network", new_network, "display_name", new_display_name or current_display_name)
        c:set("network", new_network, "vlan_id", tostring(effective_vlan))

        if params.enabled == false then
            c:set("network", new_network, "disabled", "1")
        end

        do
            local dhcp_err = set_dhcp_config(c, new_network, {
                dhcp_enable = gw_clear_custom and false or params.dhcp_enable,
                dhcp_start = dhcp_start or old_start,
                dhcp_limit = dhcp_limit or old_limit,
                leasetime = leasetime or old_leasetime,
                dns = params.dns or (old_dns and #old_dns > 0 and old_dns or nil),
                lpr = params.lpr or (old_lpr and #old_lpr > 0 and old_lpr or nil),
                dhcp_gateway = (params.gateway ~= nil) and params.gateway or nil,
            })
            if dhcp_err then
                c:close()
                return rpc_error(ERR_INVALID_PARAMS, dhcp_err)
            end
        end

        local eff_wan_access_mode = wan_access_mode
        if eff_wan_access_mode == nil then eff_wan_access_mode = 0 end
        set_wan_access_mode(c, new_network, eff_wan_access_mode)
        ensure_custom_firewall_rules(c, new_network)

        ap_isolate_network = new_network

        c:commit("network")
        fs.sync()
        post_subnet_change()
        apply_cable_for_vlan_id_change(old_vlan_id, effective_vlan)
        apply_network_changes(c)
        schedule_gl_eqos_restart_after_br_vlan_change()
        update_parental_control(new_network, "modify", network)
        ngx.pipe.spawn({"/etc/init.d/parental_control", "restart"})
    else
        if params.ip ~= nil then
            if type(params.ip) == "string" and params.ip:match("^%s*$") then
                c:set("network", network, "proto", "none")
                c:delete("network", network, "ipaddr")
                c:delete("network", network, "netmask")
            elseif params.ip ~= current_gw then
                c:set("network", network, "proto", "static")
                c:set("network", network, "ipaddr", params.ip)
            end
        end
        if params.gateway ~= nil and params.ip == nil then
            if type(params.gateway) == "string" and params.gateway:match("^%s*$") then
                c:set("network", network, "proto", "none")
                c:delete("network", network, "ipaddr")
                c:delete("network", network, "netmask")
            elseif params.gateway ~= current_gw then
                c:set("network", network, "proto", "static")
                c:set("network", network, "ipaddr", params.gateway)
            end
        end
        if params.netmask and not gw_clear_custom then
            c:set("network", network, "netmask", params.netmask)
        end
        if new_display_name then c:set("network", network, "display_name", new_display_name) end
        if params.enabled ~= nil then
            if params.enabled then
                c:delete("network", network, "disabled")
            else
                c:set("network", network, "disabled", "1")
            end
        end

        do
            local dhcp_err = set_dhcp_config(c, network, {
                dhcp_enable = gw_clear_custom and false or params.dhcp_enable,
                dhcp_start = dhcp_start,
                dhcp_limit = dhcp_limit,
                leasetime = leasetime,
                dns = params.dns,
                lpr = params.lpr,
                dhcp_gateway = (params.gateway ~= nil) and params.gateway or nil,
            })
            if dhcp_err then
                c:close()
                return rpc_error(ERR_INVALID_PARAMS, dhcp_err)
            end
        end

        if wan_access_mode ~= nil or isolate_req ~= nil then
            set_wan_access_mode(c, network, wan_access_mode)
            ensure_custom_firewall_rules(c, network)
        end

        apply_network_changes(c)
        schedule_gl_eqos_restart_after_br_vlan_change()
    end

    -- 同步 route_policy.global.append_source_if：与新建子网语义一致（novpn、dups、vpn-client）。
    local rp_old = network
    local rp_new = (new_vlan_id and new_vlan_id ~= old_vlan_id) and new_network or network
    if rp_new and rp_new:match("^vlan%d+$") and fs.access("/etc/config/route_policy") then
        if c:get("route_policy", "global") then
            os.execute(
                "uci -q delete route_policy.gl_vlan_custom_subnet_novpn 2>/dev/null; uci -q commit route_policy"
            )
            if rp_old and rp_old:match("^vlan%d+$") and rp_old ~= rp_new then
                os.execute(
                    "uci -q del_list route_policy.global.append_source_if='"
                        .. rp_old
                        .. "' 2>/dev/null; uci -q commit route_policy"
                )
            end
            local need_add = true
            local pr = io.popen("uci show route_policy.global 2>/dev/null")
            if pr then
                for line in pr:lines() do
                    local v = line:match("append_source_if='([^']+)'")
                    if v == rp_new then
                        need_add = false
                        break
                    end
                end
                pr:close()
            end
            if need_add then
                os.execute(
                    "uci -q add_list route_policy.global.append_source_if='"
                        .. rp_new
                        .. "' && uci -q commit route_policy"
                )
            end
        end

        if rp_old and rp_old:match("^vlan%d+$") and rp_old ~= rp_new then
            sync_route_policy_interface_from(rp_old, rp_new)
        end

        if fs.access("/etc/init.d/vpn-client") then
            os.execute(
                "/etc/init.d/vpn-client enabled >/dev/null 2>&1 && /etc/init.d/vpn-client start >/dev/null 2>&1"
            )
        end
    end

    reset_gsw_ports(c, network)

    -- reset_gsw_ports 已完成端口抖动，skip_switch_restart=true 避免 platform_switch_restart 再做一次
    if isolate_req ~= nil then
        set_ap_isolate(c, ap_isolate_network, isolate_req, true, true)
    end

    c:close()
    return {}
end


--[[
@method-type: call
@method-name: remove_custom_subnet
@method-desc: Remove a custom subnet. Rejects deletion if the subnet still has bound ports or interfaces.

@in string  name  Display name of the subnet to remove

@out number  ?err_code           Error code
@out string  ?err_msg            Error message
@out object  ?bindings           Bound interfaces detail (when err_msg indicates bound interfaces)
@out array   ?bindings.ports     Bound port names
@out array   ?bindings.wifi      Bound WiFi interface names

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","remove_custom_subnet",{"name":"office"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.remove_custom_subnet(params)
    if not params.name then
        return rpc_error(ERR_INVALID_PARAMS, "name required")
    end

    local c = uci.cursor()

    local tap_err = check_tap_s2s_blocked(c)
    if tap_err then c:close(); return tap_err end

    local network = resolve_display_name_to_network(c, params.name)
    if not network then
        c:close()
        return rpc_error(ERR_SUBNET_NOT_FOUND, "subnet not found")
    end
    if is_fixed_subnet(network) then
        c:close()
        return rpc_error(ERR_DELETE_FIXED_SUBNET, "fixed subnet cannot be deleted")
    end

    local vid = network:match("^vlan(%d+)$")
    local vid_num = vid and tonumber(vid)
    if vid_num and vid_num >= VLAN_ID_MIN and vid_num <= VLAN_ID_MAX then
        local bound_ports = get_ports_for_subnet_from_eth_ports_config_map(vid_num)
        if #bound_ports > 0 then
            c:close()
            return rpc_error(ERR_DELETE_HAS_BINDINGS,
                "Cannot delete: port(s) " .. table.concat(bound_ports, ", ") .. " bound to this subnet",
                { bindings = { ports = bound_ports } })
        end
        local switch_vlan_phys = parse_phys_from_vlan_section(c, vid_num)
        if next(switch_vlan_phys) then
            c:close()
            return rpc_error(ERR_DELETE_HAS_BINDINGS,
                "Cannot delete: subnet has interfaces (switch_vlan)",
                { bindings = { ports = {} } })
        end
    end

    local has_ifaces, bindings_info = custom_subnet_has_interfaces(c, network)
    if has_ifaces then
        c:close()
        return rpc_error(ERR_DELETE_HAS_BINDINGS,
            "subnet has interfaces, migrate first",
            { bindings = bindings_info })
    end

    if vid_num then clear_eth_ports_config_map_for_vlan(vid_num) end
    update_parental_control(network, "remove")
    ngx.pipe.spawn({"/etc/init.d/parental_control", "restart"})
    if network:match("^vlan%d+$") and fs.access("/etc/config/route_policy") then
        os.execute(
            "uci -q del_list route_policy.global.append_source_if='"
                .. network
                .. "' 2>/dev/null; uci -q commit route_policy"
        )
    end
    delete_subnet_config(c, network)

    apply_network_changes(c)
    if network:match("^vlan%d+$") and fs.access("/etc/init.d/vpn-client") then
        os.execute("/etc/init.d/vpn-client enabled >/dev/null 2>&1 && /etc/init.d/vpn-client start >/dev/null 2>&1")
    end
    schedule_gl_eqos_restart_after_br_vlan_change()
    c:close()
    return {}
end


local function validate_static_bind_name(name)
    if not validator.base(name, "string", true, 0, 256) then
        return false
    end
    if name and name ~= "" and (string.find(name, '"', 1, true) or string.find(name, ",", 1, true)) then
        return false
    end
    return true
end

local function validate_static_bind_hostname(hostname)
    if not validator.base(hostname, "string", true, 0, 63) then
        return false
    end
    if hostname and hostname ~= "" then
        if (not string.match(hostname, '^[a-zA-Z0-9][a-zA-Z0-9%-]*[a-zA-Z0-9]$')) or hostname:match("^%d+$") then
            return false
        end
    end
    return true
end

--[[
@method-type: call
@method-name: add_static_bind
@method-desc: Add or overwrite a static DHCP address reservation. If display_name is not provided, the subnet is inferred from the IP address.

@in string  mac                MAC address
@in string  ip                 IP address to reserve
@in string  ?display_name      Subnet display name (e.g. "main", "guest"); if absent, inferred from IP
@in string  ?name              Client alias / tag
@in string  ?hostname          DHCP hostname (alias: host_name); omit to keep existing on update, "" to clear
@in bool   ?one_click         If true, skip hostname validation/conflict and do not set dhcp host name (same as lan.add_static_bind)

@out number  ?err_code         Error code (-1: invalid params; -21: subnet selector; -22: IP not in subnet; -23: gateway IP)
@out string  ?err_msg          Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","add_static_bind",{"mac":"AA:BB:CC:DD:EE:FF","ip":"192.168.8.100","display_name":"main","name":"my-pc"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.add_static_bind(params)
    local c = uci.cursor()
    local mac = params.mac
    local ip = params.ip
    local name = params.name or ""
    local hostname_raw = params.hostname
    if hostname_raw == nil then hostname_raw = params.host_name end
    local hostname_present = hostname_raw ~= nil
    local input_hostname = hostname_present and hostname_raw or ""
    local one_click = params.one_click
    local dn = params.display_name

    if not validator.macaddr(mac) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid mac")
    end
    if not validator.ip4addr(ip) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid ip")
    end
    if not validate_static_bind_name(name) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid name")
    end
    if one_click ~= nil and type(one_click) ~= "boolean" then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid one_click")
    end
    if not one_click and hostname_present and not validate_static_bind_hostname(input_hostname) then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "invalid hostname")
    end

    name = name or ""
    mac = mac:upper()

    local network
    if dn and dn ~= "" then
        network = NETWORK_MAP[dn] or resolve_display_name_to_network(c, dn)
    else
        network = resolve_network_by_ip(c, ip)
    end

    if not network then
        c:close()
        return rpc_error(ERR_STATIC_BIND_SUBNET_SELECTOR, "invalid or missing subnet selector")
    end

    local gw = c:get("network", network, "ipaddr")
    local nm = c:get("network", network, "netmask")
    if gw and nm then
        local gw_num = ip_to_number(gw)
        local nm_num = ip_to_number(nm)
        local ip_num = ip_to_number(ip)
        if gw_num and nm_num and ip_num then
            if band32(gw_num, nm_num) ~= band32(ip_num, nm_num) then
                c:close()
                return rpc_error(ERR_STATIC_BIND_IP_NOT_IN_SUBNET, "IP not in subnet")
            end
            if ip_num == gw_num then
                c:close()
                return rpc_error(ERR_STATIC_BIND_GATEWAY_IP, "cannot bind gateway IP")
            end
        end
    end

    local old_hostname = nil
    local conflict = false
    local conflict_mac = ""
    local to_delete = {}
    c:foreach("dhcp", "host", function(s)
        if type(s.mac) == "table" then return end
        local s_mac = type(s.mac) == "string" and s.mac:upper() or nil
        if s_mac and s_mac == mac then
            old_hostname = old_hostname or s.name
            to_delete[#to_delete + 1] = s[".name"]
        elseif s.ip == ip and (s.network or "lan") == network then
            old_hostname = old_hostname or s.name
            to_delete[#to_delete + 1] = s[".name"]
        end

        if not one_click and hostname_present and input_hostname ~= "" and s.name == input_hostname then
            conflict = true
            conflict_mac = s_mac or ""
        end
    end)

    if not one_click and hostname_present and input_hostname ~= "" and conflict and conflict_mac ~= mac then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "hostname already exists")
    end

    for _, sid in ipairs(to_delete) do c:delete("dhcp", sid) end

    local sid = c:add("dhcp", "host")
    c:set("dhcp", sid, "mac", mac)
    c:set("dhcp", sid, "ip", ip)
    c:set("dhcp", sid, "network", network)
    if name ~= "" then c:set("dhcp", sid, "tag", name) end

    pcall(function()
        ubus.call("gl-session", "call", { module = "clients", func = "set_info", params = { mac = mac, alias = name } })
    end)

    if not one_click then
        local final_hostname
        if not hostname_present then
            final_hostname = old_hostname
        elseif input_hostname ~= "" then
            final_hostname = input_hostname
        end
        if final_hostname and final_hostname ~= "" then
            c:set("dhcp", sid, "name", final_hostname)
        end
    end

    c:commit("dhcp")
    c:close()
    os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
    return {}
end

--[[
@method-type: call
@method-name: set_static_bind
@method-desc: Alias for add_static_bind. Add or overwrite a static DHCP address reservation.

@in string  mac                MAC address
@in string  ip                 IP address to reserve
@in string  ?display_name      Subnet display name; if absent, inferred from IP
@in string  ?name              Client alias / tag
@in string  ?hostname          DHCP hostname (alias: host_name); omit to keep existing on update, "" to clear
@in bool   ?one_click         If true, skip hostname validation/conflict and do not set dhcp host name (same as lan)

@out number  ?err_code         Error code (-1: invalid params; -21: subnet selector; -22: IP not in subnet; -23: gateway IP)
@out string  ?err_msg          Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","set_static_bind",{"mac":"AA:BB:CC:DD:EE:FF","ip":"192.168.8.100"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.set_static_bind(params)
    return M.add_static_bind(params)
end

--[[
@method-type: call
@method-name: get_static_bind_list
@method-desc: Query the list of static DHCP address reservations. If display_name is provided, only return bindings for that subnet.

@in string  ?display_name                    Filter by subnet display name

@out array   static_bind_list                Static binding list
@out string  static_bind_list.mac            MAC address
@out string  static_bind_list.ip             Reserved IP address
@out string  ?static_bind_list.name          Client alias / tag
@out string  ?static_bind_list.hostname      DHCP hostname
@out string  static_bind_list.display_name   Subnet display name
@out number  ?err_code                       Error code
@out string  ?err_msg                        Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","get_static_bind_list",{"display_name":"main"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{"static_bind_list":[{"mac":"AA:BB:CC:DD:EE:FF","ip":"192.168.8.100","name":"my-pc","hostname":"my-pc","display_name":"main"}]}]}
--]]
function M.get_static_bind_list(params)
    params = params or {}
    local filter_dn = params.display_name
    local c = uci.cursor()
    local filter_net = nil
    if filter_dn then
        filter_net = NETWORK_MAP[filter_dn] or resolve_display_name_to_network(c, filter_dn)
    end
    local res = {}
    c:foreach("dhcp", "host", function(s)
        if type(s.mac) == "table" or type(s.tag) == "table" then return end
        local host_net = s.network or "lan"
        if filter_net and host_net ~= filter_net then return end
        res[#res + 1] = {
            mac = s.mac,
            ip = s.ip,
            name = (s.tag and s.tag ~= "") and s.tag or nil,
            hostname = (s.name and s.name ~= "") and s.name or nil,
            display_name = get_display_name(c, host_net),
        }
    end)
    c:close()
    return { static_bind_list = res }
end

--[[
@method-type: call
@method-name: remove_static_bind
@method-desc: Remove static DHCP address reservations. mode=0: delete by MAC address; mode=1: batch delete by subnet (optionally filtered by display_name).

@in number  mode               Delete mode: 0=by MAC, 1=by subnet
@in string  ?mac               MAC address (required when mode=0)
@in string  ?display_name      Subnet display name filter (only used when mode=1)

@out number  ?err_code         Error code
@out string  ?err_msg          Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","remove_static_bind",{"mode":0,"mac":"AA:BB:CC:DD:EE:FF"}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.remove_static_bind(params)
    local c = uci.cursor()
    local mode = params.mode
    if mode ~= 0 and mode ~= 1 then
        c:close()
        return rpc_error(ERR_INVALID_PARAMS, "mode must be 0 or 1")
    end

    local to_delete = {}
    if mode == 0 then
        local mac = params.mac
        if not validator.macaddr(mac) then c:close(); return rpc_error(ERR_INVALID_PARAMS, "invalid mac") end
        mac = mac:upper()
        c:foreach("dhcp", "host", function(s)
            if type(s.mac) == "string" and s.mac:upper() == mac then
                to_delete[#to_delete + 1] = s[".name"]
            end
        end)
    else
        local filter_net = nil
        if params.display_name then
            filter_net = NETWORK_MAP[params.display_name] or resolve_display_name_to_network(c, params.display_name)
        end
        c:foreach("dhcp", "host", function(s)
            if type(s.mac) == "table" or type(s.tag) == "table" then return end
            local host_net = s.network or "lan"
            if filter_net and host_net ~= filter_net then return end
            to_delete[#to_delete + 1] = s[".name"]
        end)
    end

    for _, sid in ipairs(to_delete) do c:delete("dhcp", sid) end
    c:commit("dhcp")
    c:close()
    os.execute("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
    return {}
end

--- 修复 bridge device 的 ports 列表中含得空格分隔多端口的语法错误。
-- @param c  uci.cursor
-- @return boolean  是否进行了修备
local function fix_bridge_ports_syntax(c)
    local dirty = false
    c:foreach("network", "device", function(s)
        if s.type == "bridge" and s.ports then
            local ports = s.ports
            if type(ports) == "string" then ports = { ports } end
            local needs_fix = false
            for _, p in ipairs(ports) do
                if tostring(p):find("%s") then
                    needs_fix = true
                    break
                end
            end
            if needs_fix then
                set_bridge_ports(c, s[".name"], ports)
                dirty = true
            end
        end
    end)
    return dirty
end

--[[
@method-type: call
@method-name: migrate_to_subnet
@method-desc: Migrate from classic single-bridge mode to VLAN subnet mode. Creates independent bridge devices for lan/guest/iot and initializes VLAN IDs and firewall rules.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","migrate_to_subnet",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.migrate_to_subnet()
    local c = uci.cursor()

    -- 先修复 ports 语法，避免中间 commit 导致状态不一致
    fix_bridge_ports_syntax(c)

    c:set("network", "lan", "device", "br-lan")
    c:set("network", "lan", "display_name", "main")
    c:set("network", "lan", "vlan_id", "1")

    ensure_bridge_device(c, "br-guest")
    if not c:get("network", "guest") then
        c:set("network", "guest", "interface")
        c:set("network", "guest", "proto", "static")
        c:set("network", "guest", "ipaddr", "192.168.9.1")
        c:set("network", "guest", "netmask", "255.255.255.0")
        c:set("network", "guest", "disabled", "1")
    end
    c:set("network", "guest", "device", "br-guest")
    c:set("network", "guest", "display_name", "guest")
    c:set("network", "guest", "vlan_id", "9")

    ensure_bridge_device(c, "br-iot")
    if not c:get("network", "iot") then
        c:set("network", "iot", "interface")
        c:set("network", "iot", "proto", "static")
        c:set("network", "iot", "ipaddr", "192.168.10.1")
        c:set("network", "iot", "netmask", "255.255.255.0")
        c:set("network", "iot", "disabled", "1")
    end
    c:set("network", "iot", "device", "br-iot")
    c:set("network", "iot", "display_name", "iot")
    c:set("network", "iot", "vlan_id", "10")

    for _, net in ipairs({ "guest", "iot" }) do
        local dhcp_sid = find_dhcp_section(c, net)
        if not dhcp_sid then
            c:set("dhcp", net, "dhcp")
            c:set("dhcp", net, "interface", net)
            c:set("dhcp", net, "ignore", "1")
            c:set("dhcp", net, "start", "100")
            c:set("dhcp", net, "limit", "150")
            c:set("dhcp", net, "leasetime", "12h")
        end
    end

    for _, net in ipairs({ "guest", "iot" }) do
        local zone_exists = false
        c:foreach("firewall", "zone", function(s)
            if s.name == net then
                zone_exists = true
                return false
            end
        end)
        if not zone_exists then
            local zone_sid = c:add("firewall", "zone")
            c:set("firewall", zone_sid, "name", net)
            c:set("firewall", zone_sid, "network", { net })
            c:set("firewall", zone_sid, "input", "REJECT")
            c:set("firewall", zone_sid, "output", "ACCEPT")
            c:set("firewall", zone_sid, "forward", "REJECT")

            local rule_sid = c:add("firewall", "rule")
            c:set("firewall", rule_sid, "name", "Allow-" .. net .. "-DHCP-DNS")
            c:set("firewall", rule_sid, "src", net)
            c:set("firewall", rule_sid, "proto", "udp")
            c:set("firewall", rule_sid, "dest_port", "53 67 68")
            c:set("firewall", rule_sid, "target", "ACCEPT")

            local fwd_sid = c:add("firewall", "forwarding")
            c:set("firewall", fwd_sid, "src", net)
            c:set("firewall", fwd_sid, "dest", "wan")
        end
        -- 初始化 transfer_enable
        set_wan_access_mode(c, net, 0)
    end

    apply_network_changes(c)
    c:close()
    return {}
end

--[[
@method-type: call
@method-name: migrate_from_subnet
@method-desc: Revert from VLAN subnet mode back to classic single-bridge mode. Deletes all custom subnets and cleans up residual configuration.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","migrate_from_subnet",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.migrate_from_subnet()
    local c = uci.cursor()

    delete_all_custom_subnets(c)
    purge_custom_vlan_residue(c)

    c:set("network", "lan", "device", "br-lan")
    c:delete("network", "lan", "display_name")
    c:delete("network", "lan", "vlan_id")

    for _, net in ipairs({ "guest", "iot" }) do
        if c:get("network", net) then
            c:set("network", net, "device", "br-lan")
            c:set("network", net, "disabled", "1")
            c:delete("network", net, "display_name")
            c:delete("network", net, "vlan_id")
        end
    end

    local to_delete = {}
    c:foreach("network", "device", function(s)
        if s.name and s.name:match("^br%-vlan%d+$") then
            to_delete[#to_delete + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(to_delete) do
        c:delete("network", sid)
    end

    local bridge_del = {}
    c:foreach("network", "device", function(s)
        if s.name == "br-guest" or s.name == "br-iot" then
            bridge_del[#bridge_del + 1] = s[".name"]
        end
    end)
    for _, sid in ipairs(bridge_del) do
        c:delete("network", sid)
    end

    local switch_vlan_to_delete = {}
    pcall(function()
        c:foreach("network", "switch_vlan", function(s)
            local vid = tonumber(s.vlan)
            if vid and vid >= VLAN_ID_MIN then
                switch_vlan_to_delete[#switch_vlan_to_delete + 1] = s[".name"]
            end
        end)
    end)
    for _, sid in ipairs(switch_vlan_to_delete) do
        c:delete("network", sid)
    end

    local eth_devs_to_delete = {}
    c:foreach("network", "device", function(s)
        if s.name then
            local vid = vlan_subif_vid_purge(s.name)
            if vid and vid >= VLAN_ID_MIN then
                eth_devs_to_delete[#eth_devs_to_delete + 1] = s[".name"]
            end
        end
    end)
    for _, sid in ipairs(eth_devs_to_delete) do
        c:delete("network", sid)
    end

    c:foreach("network", "device", function(s)
        if s.name == "br-lan" and s.ports then
            local ports = s.ports
            if type(ports) == "string" then ports = { ports } end
            local clean = {}
            for _, p in ipairs(ports) do
                for token in tostring(p):gmatch("%S+") do
                    local vid = vlan_subif_vid_purge(token)
                    if not vid or vid < VLAN_ID_MIN then
                        clean[#clean + 1] = token
                    end
                end
            end
            set_bridge_ports(c, s[".name"], clean)
        end
    end)

    for _, net in ipairs({ "guest", "iot" }) do
        c:delete("gl-black_white_list", net .. "_transfer_enable")
        c:delete("gl-black_white_list", net .. "_ap_isolate")
        c:delete("gl-black_white_list", net .. "_wan_isolate")
        c:delete("gl-black_white_list", net)
    end

    for _, net in ipairs({ "guest", "iot" }) do
        update_parental_control(net, "remove")
    end
    ngx.pipe.spawn({"/etc/init.d/parental_control", "restart"})
    apply_network_changes(c)
    c:close()
    return {}
end

--- libcable 全量下发后，map 仍可能把原 WAN 口按 WAN 处理而未加入 br-lan；仅 **AP 桥接模式**（netmode_to_ap）需要把物理 WAN 并进 br-lan。
-- TAP-S2S 需保留 WAN 作 OpenVPN 等三层上行，不应调用本函数。
-- 与 netmode.set_wan_port_to_bridge 语义对齐（含无 ports 时用 secondwan 占位）。
-- @param c  uci.cursor
local function ensure_wan_phy_on_br_lan(c)
    local wan_if = c:get("network", "wan", "device")
    if not wan_if or wan_if == "" then return end

    local br_sid
    c:foreach("network", "device", function(s)
        if s.name == "br-lan" then br_sid = s[".name"] end
    end)
    if not br_sid then return end

    local ports = get_bridge_ports_from_uci(c, "br-lan")
    local filtered = {}
    for _, p in ipairs(ports) do
        if p ~= wan_if then filtered[#filtered + 1] = p end
    end

    if #filtered == 0 then
        local second = ""
        local ok_lf, lfactory = pcall(require, "lfactory")
        if ok_lf and lfactory and type(lfactory.get_secondwan_port) == "function" then
            second = lfactory.get_secondwan_port() or ""
        end
        if second ~= "" and second ~= wan_if then
            filtered[#filtered + 1] = second
        end
    end
    filtered[#filtered + 1] = wan_if

    set_bridge_ports(c, br_sid, filtered)
end

--- 将 VLAN 子网相关 UCI 恢复为出厂状态（不含 apply_network_changes / 不重载服务）。
-- 顺序：1) libcable.apply_ap_mode_port_defaults（由 libcable 维护 eth_ports_config_map 与 network 下发）；
-- 2) delete_all_custom_subnets + purge_custom_vlan_residue 去掉自定义子网及残留（不在此写 map）；
-- 3) restore_fixed_subnets_factory 恢复 lan/guest/iot；4) 补齐 guest/iot WAN forwarding 与 gl-black_white_list。
-- apply_ap 可能已 commit network；其后新建 cursor，在同一 cursor 上完成子网出厂 UCI 修改并返回供调用方 commit/apply。
-- @return uci.cursor
local function apply_vlan_subnet_factory_uci(mode)
    local ok_lc, libcable = pcall(require, "libcable")
    if ok_lc and libcable and type(libcable.apply_ap_mode_port_defaults) == "function" then
        pcall(libcable.apply_ap_mode_port_defaults, mode)
    end
    local c = uci.cursor()
    delete_all_custom_subnets(c)
    purge_custom_vlan_residue(c)
    restore_fixed_subnets_factory(c)
    for _, name in ipairs(FIXED_SUBNETS) do
        if name ~= "lan" then
            local fwd_found = false
            c:foreach("firewall", "forwarding", function(s)
                if s.src == name and s.dest == "wan" then
                    fwd_found = true
                    c:set("firewall", s[".name"], "enabled", "1")
                end
            end)
            if not fwd_found then
                local fwd_sid = c:add("firewall", "forwarding")
                c:set("firewall", fwd_sid, "src", name)
                c:set("firewall", fwd_sid, "dest", "wan")
                c:set("firewall", fwd_sid, "enabled", "1")
            end
        end
    end
    for _, name in ipairs(FIXED_SUBNETS) do
        c:delete("gl-black_white_list", name .. "_transfer_enable")
        c:delete("gl-black_white_list", name .. "_ap_isolate")
        c:delete("gl-black_white_list", name .. "_wan_isolate")
        c:delete("gl-black_white_list", name)
    end
    return c
end

--- 提交 AP 相关包并刷新端口映射（netmode_to_ap / tap_s2s_enter 共用）。
local function commit_vlan_subnet_ap_cursor(c)
    c:commit("network")
    c:commit("dhcp")
    c:commit("firewall")
    c:commit("glconfig")
    if fs.access("/etc/config/gl-black_white_list") then
        c:commit("gl-black_white_list")
    end
    c:close()
    post_subnet_change()
end

--[[
@method-type: call
@method-name: netmode_to_ap
@method-desc: Switch network mode to AP (bridge) mode. Restores VLAN subnet UCI to factory defaults and merges the physical WAN port into br-lan. Only commits UCI; network reload is handled by the outer netmode caller.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","netmode_to_ap",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.netmode_to_ap()
    local c = apply_vlan_subnet_factory_uci()
    ensure_wan_phy_on_br_lan(c)
    commit_vlan_subnet_ap_cursor(c)
    return {}
end

--[[
@method-type: call
@method-name: netmode_to_router
@method-desc: Switch network mode from AP back to router mode. Restores independent bridge devices for fixed subnets and initializes guest/iot WAN forwarding rules.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","netmode_to_router",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.netmode_to_router()
    local c = uci.cursor()

    -- AP 阶段若未落盘，自定义子网与 DSA 设备节会残留；切回路由时再次清理并提交
    delete_all_custom_subnets(c)
    purge_custom_vlan_residue(c)

    if fix_bridge_ports_syntax(c) then
        c:commit("network")
    end
    -- 恢复固定子网的独立桥
    for _, net in ipairs(FIXED_SUBNETS) do
        if c:get("network", net) then
            local cfg = DEFAULT_SUBNET_CFG[net]
            if cfg then
                ensure_bridge_device(c, cfg.bridge)
                c:set("network", net, "device", cfg.bridge)
                c:set("network", net, "display_name", cfg.display_name)
                c:set("network", net, "vlan_id", tostring(cfg.vlan_id))
            end
        end
    end

    local wan_array = { "wan", "wwan", "tethering", "secondwan", "usbwan" }
    for _, net in ipairs({ "guest", "iot" }) do
        if c:get("network", net) then
            c:set("network", net, "disabled", "1")
            ensure_custom_firewall_rules(c, net)
            set_wan_access_mode(c, net, 0)
        end
        -- wan_isolate: remove firewall REJECT rules created by lan.set_network_wan_isolate
        for _, wif in ipairs(wan_array) do
            c:delete("firewall", wif .. "_" .. net .. "_isolate")
        end
        if fs.access("/etc/config/gl-black_white_list") then
            c:delete("gl-black_white_list", net .. "_wan_isolate")
        end
    end
    for _, net in ipairs({ "guest", "iot" }) do
        if c:get("network", net) then
            local cfg = DEFAULT_SUBNET_CFG[net]
            if cfg then
                set_dhcp_config(c, net, {
                    dhcp_enable = true,
                    dhcp_start = cfg.dhcp_start,
                    dhcp_limit = cfg.dhcp_limit,
                    leasetime = cfg.leasetime,
                })
            end
        end
    end
    libcable.on_netmode_to_router(c)
    c:commit("network")
    c:commit("dhcp")
    c:commit("firewall")
    if fs.access("/etc/config/gl-black_white_list") then
        c:commit("gl-black_white_list")
    end
    post_subnet_change()
    c:close()
    return {}
end

--[[
@method-type: call
@method-name: tap_s2s_enter
@method-desc: Enter TAP S2S mode. Shares the same factory-reset UCI logic as netmode_to_ap but does NOT merge the physical WAN port into br-lan (WAN is reserved for VPN uplink).

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","tap_s2s_enter",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.tap_s2s_enter()
    local c = apply_vlan_subnet_factory_uci('s2s')
    commit_vlan_subnet_ap_cursor(c)
    return {}
end

--[[
@method-type: call
@method-name: tap_s2s_exit
@method-desc: Exit TAP S2S mode. Re-enables guest/iot DHCP server (clears dhcp ignore). Does not auto-enable guest/iot network or WiFi.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","tap_s2s_exit",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.tap_s2s_exit()
    local c = uci.cursor()

    for _, net in ipairs({ "guest", "iot" }) do
        if c:get("network", net) then
            set_dhcp_config(c, net, { dhcp_enable = true })
        end
    end
    c:commit("dhcp")
    c:close()
    post_subnet_change()
    return {}
end

--[[
@method-type: call
@method-name: network_reset
@method-desc: Full subnet configuration reset. Deletes all custom subnets, restores fixed subnets to factory defaults, and cleans up all black_white_list residual entries.

@out number  ?err_code  Error code
@out string  ?err_msg   Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","network_reset",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{}]}
--]]
function M.network_reset()
    local c = apply_vlan_subnet_factory_uci()
    apply_network_changes(c)
    c:close()
    os.remove("/tmp/vlan_port_map")
    return {}
end

--[[
@method-type: call
@method-name: get_client_view
@method-desc: Get connected clients across all subnets, inferred from the ARP table.

@out array   clients            Client list
@out string  clients.mac        MAC address (uppercase)
@out string  clients.network    Subnet network name (e.g. "lan", "guest", "vlan100")
@out string  clients.conn_type  Connection type: "wifi" or "wired"
@out string  clients.band       WiFi band: "2.4g", "5g", "6g" or "" (wired)
@out number  ?err_code          Error code
@out string  ?err_msg           Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","get_client_view",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{"clients":[{"mac":"AA:BB:CC:DD:EE:FF","network":"lan","conn_type":"wired","band":""}]}]}
--]]
function M.get_client_view()
    local c = uci.cursor()
    local clients = {}

    local port_to_network = {}
    local all = get_all_subnet_networks(c)
    for _, net in ipairs(all) do
        local bridge = get_bridge_for_network(net)
        if bridge then
            port_to_network[bridge] = net
        end
        local bindings_data = get_subnet_bindings(c, net)
        for _, p in ipairs(bindings_data.ports) do
            port_to_network[p] = net
        end
    end

    local wifi_to_network = {}
    local wifi_to_band = {}
    c:foreach("wireless", "wifi-iface", function(s)
        if s.ifname and s.network then
            wifi_to_network[s.ifname] = s.network
            local device = s.device or ""
            local band = "2.4g"
            if device:match("5g") or device:match("radio1") then
                band = "5g"
            elseif device:match("6g") or device:match("radio2") then
                band = "6g"
            end
            wifi_to_band[s.ifname] = band
        end
    end)

    local arp_list = {}
    local f = io.popen("ip neigh show nud reachable nud stale nud delay nud probe 2>/dev/null")
    if f then
        for line in f:lines() do
            local _, dev, mac = line:match("(%S+)%s+dev%s+(%S+).-(%x%x:%x%x:%x%x:%x%x:%x%x)")
            if mac then
                arp_list[#arp_list + 1] = { mac = mac:upper(), dev = dev }
            end
        end
        f:close()
    end

    for _, entry in ipairs(arp_list) do
        local net = wifi_to_network[entry.dev] or port_to_network[entry.dev]
        local conn_type = wifi_to_network[entry.dev] and "wifi" or "wired"
        local band = wifi_to_band[entry.dev] or ""

        if not net then
            for _, subnet in ipairs(all) do
                local bridge = get_bridge_for_network(subnet)
                if bridge and (entry.dev == bridge or entry.dev:match("^" .. bridge:gsub("%-", "%%-"))) then
                    net = subnet
                    break
                end
            end
        end

        if net then
            clients[#clients + 1] = {
                mac = entry.mac,
                network = net,
                conn_type = conn_type,
                band = band,
            }
        end
    end

    c:close()
    return { clients = clients }
end

--[[
@method-type: call
@method-name: get_vpn_interfaces
@method-desc: Get summary of currently active (enabled) subnets for VPN interface selection. Only returns subnets that are not disabled.

@out array   interfaces               Active subnet list
@out string  interfaces.network       UCI network interface name
@out string  interfaces.display_name  Display name
@out string  interfaces.ipaddr        Interface IP address
@out number  ?err_code                Error code
@out string  ?err_msg                 Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","get_vpn_interfaces",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{"interfaces":[{"network":"lan","display_name":"main","ipaddr":"192.168.8.1"}]}]}
--]]
function M.get_vpn_interfaces()
    local c = uci.cursor()
    local interfaces = {}

    local all = get_all_subnet_networks(c)
    for _, net in ipairs(all) do
        local ipaddr = c:get("network", net, "ipaddr")
        local disabled = c:get("network", net, "disabled")
        if ipaddr and disabled ~= "1" then
            interfaces[#interfaces + 1] = {
                network = net,
                display_name = get_display_name(c, net),
                ipaddr = ipaddr,
            }
        end
    end

    c:close()
    return { interfaces = interfaces }
end

--[[
@method-type: call
@method-name: get_wan_info
@method-desc: Get current WAN interface address information. Checks wan, wwan, tethering, secondwan, usbwan and modem_* interfaces. Returns err_code -4 if no physical WAN port exists, or -5 if no virtual WAN is up.

@out array   wan_info              WAN interface info list
@out string  wan_info.interface    WAN interface name (e.g. "wan", "wwan", "modem_xxx_4")
@out object  wan_info.info         IP calculation result from ipcalc (network, prefix, broadcast, etc.)
@out number  ?err_code             Error code (-4: no physical WAN, -5: no virtual WAN)
@out string  ?err_msg              Error message

@in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","vlan_subnet","get_wan_info",{}]}
@out-example: {"id":1,"jsonrpc":"2.0","result":[{"wan_info":[{"interface":"wan","info":{"NETWORK":"192.168.1.0","PREFIX":"24"}}]}]}
--]]
function M.get_wan_info()
    local c = uci.cursor()
    local wan_ipaddr = {}

    -- Check physical WAN port existence
    local has_physical_wan = false
    pcall(function()
        local cc = uci.cursor()
        if cc:get("network", "wan") then
            local wan_dev = cc:get("network", "wan", "device") or cc:get("network", "wan", "ifname")
            if wan_dev and wan_dev ~= "" then
                has_physical_wan = fs.access("/sys/class/net/" .. wan_dev)
            end
        end
        cc:close()
    end)
    if not has_physical_wan then
        c:close()
        return rpc_error(ERR_NO_PHYSICAL_WAN, "this device doesn't have the physical WAN port")
    end

    local wan_array = build_wan_logical_interface_list(c)

    -- Check virtual WAN port (at least one WAN interface must be up)
    local has_virtual_wan = false
    for i = 1, #wan_array do
        local s = ubus.call("network.interface." .. wan_array[i], "status")
        if s and s["ipv4-address"] and s["ipv4-address"][1]
            and s["ipv4-address"][1]["address"] and s["ipv4-address"][1]["mask"] then
            has_virtual_wan = true
            local _wan_info = s["ipv4-address"][1]["address"] .. "/" .. s["ipv4-address"][1]["mask"]
            local wan_info = lnet.ipcalc(_wan_info)
            wan_ipaddr[#wan_ipaddr + 1] = {
                interface = wan_array[i],
                info = wan_info,
            }
        end
    end

    if not has_virtual_wan then
        c:close()
        return rpc_error(ERR_NO_VIRTUAL_WAN, "this device doesn't have the virtual WAN port")
    end

    c:close()
    return { wan_info = wan_ipaddr }
end

return M
