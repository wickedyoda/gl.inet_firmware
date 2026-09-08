local utils = require 'oui.utils'
local ubus = require "oui.ubus"
local uci = require "uci"

local c = uci.cursor()
local redirect_https = c:get("oui-httpd", "main", "redirect_https") == "1"

local function get_ssl_port()
    local text = utils.readfile('/etc/nginx/conf.d/gl.conf')
    return text:match('listen (%d+) ssl;')
end

local function get_iface_ipaddr(iface)
    local s = ubus.call("network.interface." .. iface, "status")
    if not s or not s.up then
        return nil
    end

    local ipaddrs = s["ipv4-address"]
    if #ipaddrs == 0 then
        return nil
    end

    return ipaddrs[1].address
end

local host = ngx.var.host

if ngx.var.remote_addr == "127.0.0.1" or ngx.var.remote_addr == "::1" then
    return
end

if redirect_https and ngx.var.scheme == "http" then
    local ssl_port = get_ssl_port()
    if ssl_port ~= '443' then
        host = host .. ':' .. ssl_port
    end
    return ngx.redirect("https://" .. host .. ngx.var.request_uri)
end

if  c:get("oui-httpd", "main", "inited") then
    return
end

local lanip = get_iface_ipaddr("lan")
local wanip = get_iface_ipaddr("wan")

local hosts = {
    ['console.gl-inet.com'] = true,
    ['localhost'] = true,
    ['127.0.0.1'] = true
}

if lanip then
    hosts[lanip] = true
end

if wanip then
    hosts[wanip] = true
end

if not hosts[host] and lanip then
    return ngx.redirect(ngx.var.scheme .. "://" .. lanip)
end
