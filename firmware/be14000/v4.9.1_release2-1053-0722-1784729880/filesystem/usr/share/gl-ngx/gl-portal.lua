local utils = require 'oui.utils'
local ubus = require 'oui.ubus'

local function get_web_http_port()
    local text = utils.readfile('/etc/nginx/conf.d/gl.conf')
    return text:match('listen (%d+);')
end

local function get_web_ssl_port()
    local text = utils.readfile('/etc/nginx/conf.d/gl.conf')
    return text:match('listen (%d+) ssl;')
end

local function get_iface_ipaddr(iface)
    local s = ubus.call('network.interface.' .. iface, 'status')
    if not s or not s.up then
        return nil
    end

    local ipaddrs = s['ipv4-address']
    if #ipaddrs == 0 then
        return nil
    end

    return ipaddrs[1].address
end

local scheme = ngx.var.scheme
local lanip = get_iface_ipaddr('lan')

local redirect_url = scheme .. '://' .. lanip
local port = scheme == 'http' and get_web_http_port() or get_web_ssl_port()

if port ~= '80' and port ~= '443' then
    redirect_url = redirect_url .. ':' .. port
end

ngx.redirect(redirect_url)
