local iwinfo = require 'iwinfo'

local M = {}

M.type = function(device)
    return iwinfo.type(device)
end

M.info = function(device, ...)
    if type(device) ~= "string" then
        return nil
    end

    local iwtype = M.type(device)

    if not iwtype then
        return nil
    end

    local arg = {...}

    return setmetatable({}, {
        __index = function(_, k)
            return iwinfo[iwtype][k] and iwinfo[iwtype][k](device, arg[1], arg[2], arg[3])
        end
    })
end

function M.assoclist(device)
   local info = device and M.info(device)
   return info and info['assoclist'] or {}
end

function M.scan(device, ssid, t)
    local list = {}
    local info = M.info(device, ssid, t)

    if not info then return list end
    local ss = info['scanlist_ssid'] or {}

    for _, s in ipairs(ss) do
        list[#list + 1] = s
    end

    return list
end

function M.freqlist(device)
    return M.info(device)['freqlist']
end

function M.txpwrlist(device)
    return M.info(device)['txpwrlist']
end

function M.countrylist(device)
    return M.info(device)['countrylist']
end

return M
