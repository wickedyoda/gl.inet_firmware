local M = {}

local function parse_ip4addr(value)
    if type(value) ~= 'string' then
        return nil
    end

    local octets = { value:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$') }
    if #octets ~= 4 then
        return nil
    end

    for i, octet in ipairs(octets) do
        local n = tonumber(octet)
        if n > 255 then
            return nil
        end

        octets[i] = n
    end

    return octets
end

local function ipv6_compress_check(address_compress, cal_symbol_num)
    if (cal_symbol_num > 2) then
        return false, address_compress
    elseif (cal_symbol_num == 2) then
        if (address_compress == true) then
            return false, address_compress
        else
            address_compress = true
        end
    end
    return true, address_compress
end

local function ipv6_hex_check(hex)
    return #hex <= 4 and hex:match('^[0-9a-fA-F]+$') ~= nil
end

local function parse_standard_ip6addr(value)
    if type(value) ~= 'string' then
        return nil
    end

    local n
    local splits = {}
    local octets = {}
    local status = 0
    local res
    local compress_num
    local address_compress = false
    local cal_symbol_num = 0
    local next_hex = ""

    -- 按照:将字符串分段，捕获十六进制部分和::
    for part in value:gmatch('.') do
        if status == 0 and part ~= ':' then
            res, address_compress = ipv6_compress_check(address_compress, cal_symbol_num)
            if res == false then
                return nil
            end
            if (cal_symbol_num == 2) then
                splits[#splits + 1] = '::'
            end
            cal_symbol_num = 0
            status = 1
        elseif status == 1 and part == ':' then
            if (ipv6_hex_check(next_hex) == false) then
                return nil
            end
            splits[#splits + 1] = next_hex
            status = 0
            next_hex = ""
        end
        if (status == 0) then
            cal_symbol_num = cal_symbol_num + 1
        elseif (status == 1) then
            next_hex = next_hex .. part
        end
    end
    if (status == 0) then
        res, address_compress = ipv6_compress_check(address_compress, cal_symbol_num)
        if res == false then
            return nil
        end
        if (cal_symbol_num == 2) then
            splits[#splits + 1] = '::'
        end
    elseif (status == 1) then
        if (ipv6_hex_check(next_hex) == false) then
            return nil
        end
        splits[#splits + 1] = next_hex
    end

    if address_compress == false then
        -- 如果没有压缩，则头尾不能是:，并且分段数要等于8
        if #splits ~= 8 or status == 0 or string.sub(value, 1, 1) == ':' then
            return nil
        end
    else
        -- 如果压缩
        if #splits > 8 then
            -- 分段数要小于等于8
            return nil
        elseif status == 0 and splits[#splits] ~= '::' then
            -- 如果以:结束，则结尾必须是::
            return nil
        elseif string.sub(value, 1, 1) == ':' and splits[1] ~= '::' then
            -- 如果是以:开头，则开头必须为::
            return nil
        end
    end

    compress_num = 8 - #splits + 1
    for _, hex_value in ipairs(splits) do
        if (hex_value ~= '::') then
            n = tonumber(hex_value, 16)
            octets[#octets + 1] = math.floor(n / 256)
            octets[#octets + 1] = math.floor(n % 256)
        else
            for _ = 1, compress_num do
                octets[#octets + 1] = 0
                octets[#octets + 1] = 0
            end
        end
    end

    return octets
end

local function parse_compatible_ip6addr(value)
    local octets = {}
    local ipv4_part = parse_ip4addr(value)

    if not ipv4_part then
        return nil
    end

    for _ = 1, 10 do
        octets[#octets + 1] = 0
    end
    octets[#octets + 1] = 255
    octets[#octets + 1] = 255
    for i = 1, 4 do
        octets[#octets + 1] = ipv4_part[i]
    end

    return octets
end

local function parse_ip6addr(value)
    if type(value) ~= 'string' then
        return nil
    end

    local ipv4_part = value:match('^::ffff:(%d+%.%d+%.%d+%.%d+)$')
    if ipv4_part then
        return parse_compatible_ip6addr(ipv4_part)
    else
        return parse_standard_ip6addr(value)
    end
end

local function is_ipaddr(value, family, cidr)
    if type(value) ~= 'string' then
        return false
    end

    local addr = value
    local prefix

    if cidr then
        addr, prefix = value:match('([%w%.:]+)/(%d+)$')
        if not addr then
            return false
        end

        prefix = tonumber(prefix)

        local prefix_max = family == 4 and 32 or 128
        if tonumber(prefix) > prefix_max then
            return false
        end
    end

    prefix = prefix or 0

    if family == 4 then
        if prefix > 32 then
            return false
        end
        return parse_ip4addr(addr) ~= nil
    elseif family == 6 then
        if prefix > 128 then
            return false
        end
        return parse_ip6addr(addr) ~= nil
    elseif parse_ip4addr(addr) then
        if prefix > 32 then
            return false
        end
        return true
    elseif parse_ip6addr(addr) then
        if prefix > 128 then
            return false
        end
        return true
    end

    return false
end

local function is_netmask(octets)
    if type(octets) ~= 'table' then
        return false
    end

    local check_0 = false

    for _, n in ipairs(octets) do
        if check_0 then
            if n ~= 0 then
                return false
            end
        elseif n ~= 255 then
            if n ~= 254 and n ~= 252 and n ~= 248 and n ~= 240 and n ~= 224 and n ~= 192 and n ~= 128 and n ~= 0 then
                return false
            end
            check_0 = true
        end
    end

    return true
end

--[[
    validator.ip4addr('192.168.8.1')
    validator.ip4addr('192.168.8.1/24', true)
--]]
function M.ip4addr(value, cidr)
    return is_ipaddr(value, 4, cidr)
end

--[[
local validator = require "gl.validator"

local function validator_ipv6(value)
    print(value .. " " .. tostring(validator.ip6addr(value, true)))
end

-- 合法示例
validator_ipv6("2001:db8::1/64")
validator_ipv6("fe80::202:b3ff:fe1e:8329/32")
validator_ipv6("f:f:f:f:f:f:f:f/32")
validator_ipv6("f:f:f:f:f:f:f::/32")
validator_ipv6("::1/128")
validator_ipv6("1::/128")
validator_ipv6("::/128")
validator_ipv6("::ffff:10.10.0.1/128")

-- 非法示例
validator_ipv6("f:f:f:f:f:f:f:f::/32")
validator_ipv6(":f:f:f:f:f:f:f:f/32")
validator_ipv6("f:f:f:f:f:f:f:f:/32")
validator_ipv6(":f::/32")
validator_ipv6("::f:/32")
validator_ipv6("2001:db8::1/130")
validator_ipv6("2001:db8::1/abc")
validator_ipv6("2001:db8::xyz/64")
validator_ipv6("2001::db8::1/64")
validator_ipv6("2001::db8:1::/64")
validator_ipv6("::ffff:777.10.0.1/128")
validator_ipv6("::ffff:777./128")
--]]
function M.ip6addr(value, cidr)
    return is_ipaddr(value, 6, cidr)
end

function M.ipaddr(value, cidr)
    return is_ipaddr(value, 0, cidr)
end

function M.netmask4(value)
    return is_netmask(parse_ip4addr(value))
end

function M.netmask6(value)
    return is_netmask(parse_ip6addr(value))
end

function M.netmask(value)
    return is_netmask(parse_ip4addr(value) or parse_ip6addr(value))
end

--[[
    validator.macaddr('00:15:5d:15:f0:87')
    validator.macaddr('00-15-5d-15-f0-87', '-')
    validator.macaddr('00155d15f087', '')
--]]
function M.macaddr(value, sep)
    if type(value) ~= 'string' then
        return false
    end

    local pattern = '^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$'

    assert(sep == nil or sep == '-' or sep == '')

    if sep == '-' then
        pattern = pattern:gsub(':', '%%-')
    elseif sep == '' then
        pattern = pattern:gsub(':', '')
    end

    return value:match(pattern) ~= nil
end

function M.local_ip4addr(value)
    local b = parse_ip4addr(value)
    if not b then
        return false
    end

    return b[1] == 169 and b[2] == 254 and b[3] >= 0 and b[3] <= 255 and b[4] >= 0 and b[4] <= 255
end

function M.wpakey(value)
    if type(value) ~= 'string' then
        return false
    end

    if #value == 64 then
        return value:match('^%x+$') ~= nil
    end

    return #value > 7 and #value < 64
end

function M.wg_base64_key(value)
    local LEN = 44

    if type(value) ~= 'string' then
        return false
    end

    value = value:match('^%s*(.-)%s*$')
    if value == '' then
        return true
    end

    if #value ~= LEN then
        return false
    end

    if not value:match('^[A-Za-z0-9+/]+=*$') then
        return false
    end

    local decoded = ngx.decode_base64(value)
    if not decoded or #decoded ~= 32 then
        return false
    end

    return true
end

function M.base(value, typ, optional, min, max)
    if not optional and value == nil then
        return false
    end

    if value == nil then
        return true
    end

    if typ == 'integer' then
        if type(value) ~= 'number' then
            return false
        end

        if min and value < min then
            return false
        end

        if max and value > max then
            return false
        end
        return value == math.floor(value)
    end

    if type(value) ~= typ then
        return false
    end

    if typ == 'number' then
        if min and value < min then
            return false
        end

        if max and value > max then
            return false
        end
    elseif typ == 'string' then
        if min and #value < min then
            return false
        end

        if max and #value > max then
            return false
        end
    end

    return true
end

return M
