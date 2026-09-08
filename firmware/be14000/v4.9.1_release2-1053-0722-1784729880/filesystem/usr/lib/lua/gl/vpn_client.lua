local M = {}

local uci = require "uci"

M.get_policy_group = function()
    local c = uci.cursor()

    -- v4.8
    local route_policy_enabled = c:get('route_policy', 'global', 'service_policy_en')
    if route_policy_enabled == '1' then
        return 'usevpn'
    end

    -- legacy
    local vpn_policy_enabled = c:get('vpnpolicy', 'global', 'service_policy')
    if vpn_policy_enabled == '1' then
        return 'nonevpn'
    end

    return nil
end

-- Calculate VPN DNS port based on instance type and index
local function get_vpn_dns_port(instance_type, index)
    if not index or index < 1 or index > 5 then
        return nil
    end

    if instance_type == "wgclient" then
        return 2054 + index * 100
    elseif instance_type == "ovpnclient" then
        return 4054 + index * 100
    end
    return nil
end

-- Handle local DNS service (stubby or dnscrypt-proxy)
local function handle_local_dns(server, instance_name)
    local result = {}
    for _, srv in ipairs(server) do
        if srv:match("^127.0.0.1#5453") then
            local instance_type = instance_name:match("^(wgclient)") or instance_name:match("^(ovpnclient)")
            local index = tonumber(instance_name:match("(%d+)$")) or 1
            local port = get_vpn_dns_port(instance_type, index)
            if port then
                table.insert(result, "127.0.0.1#" .. port)
            else
                table.insert(result, srv)
            end
        else
            table.insert(result, srv)
        end
    end
    return result
end

M.set_dns_override_vpn = function(c, enable)
    local main_noresolv = c:get("dhcp", "@dnsmasq[0]", "noresolv")
    local main_server = c:get("dhcp", "@dnsmasq[0]", "server")

    c:foreach("dhcp", "dnsmasq", function(s)
        if type(s) ~= "table" then return end

        local name = s[".name"]
        if not name then return end

        if name:match("^wgclient") or name:match("^ovpnclient") then
            if enable and main_noresolv == "1" and main_server then
                -- Handle local DNS service if needed
                local server = handle_local_dns(main_server, name)

                c:set("dhcp", name, "noresolv", "1")
                c:set("dhcp", name, "server", server)
            else
                c:delete("dhcp", name, "noresolv")
                c:delete("dhcp", name, "server")
            end
        end
    end)

    c:commit("dhcp")
end

return M
