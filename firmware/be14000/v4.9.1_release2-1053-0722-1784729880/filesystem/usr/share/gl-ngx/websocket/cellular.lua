local ubus = require 'oui.ubus'
local M = {}

function M.modems_status()
    return ubus.call('cellular.modem', 'status') or { modems_status = {} }
end

function M.modems_info()
    return ubus.call('cellular.modem', 'info') or { modems_info = {} }
end

function M.sims_status()
    return ubus.call('cellular.sim', 'status') or { sims_status = {} }
end

function M.sims_info()
    return ubus.call('cellular.sim', 'info') or { sims_info = {} }
end

function M.networks_status()
    return ubus.call('cellular.network', 'status') or { networks_status = {} }
end

function M.networks_info()
    return ubus.call('cellular.network', 'info') or { networks_info = {} }
end

return M
