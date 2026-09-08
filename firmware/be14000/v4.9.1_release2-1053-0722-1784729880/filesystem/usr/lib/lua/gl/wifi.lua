local M = {}

local scan = require "gl.scan"
local uci = require "uci"
local reg = require "regulatory"
local utils = require "oui.utils"
local cjson = require "cjson"
local fs = require "oui.fs"

function M.devices(band)
    local c = uci.cursor()
    local devices = {}

    c:foreach("wireless", "wifi-device", function(s)
        if s.disabled == "1" then return end

        if band == "2g" then
            if s.hwmode:match("a") then return end
        elseif band == "5g" then
            if not s.hwmode:match("a") then return end
        end

        local sid = s[".name"]
        local dev = sid

        if sid == "mt7615e5" or sid == "mt7628" then
            dev = "ra0"
        elseif sid == "mt7615e2" then
            dev = "rax0"
        end

        devices[sid] = dev
    end)

    return devices
end

M.fix_sta_ifname = function()
    local c = uci.cursor()
    local device = c:get("wireless", "sta", "device")
    local ifname

    if device == "mt7615e2" then
        ifname = "apclix0"
    elseif device == "mt7615e5" or device == "mt7628" then
        ifname = "apcli0"
    else
        ifname = "wlan-sta"
    end

    c:set("wireless", "sta", "ifname", ifname)

    c:commit("wireless")
end

M.connect = function(params)
    local c = uci.cursor()

    local device = params.device
    local ssid = params.ssid
    local encryption = params.encryption
    local key = params.key
    local bssid = params.bssid
    local band = params.band
    local wds = params.wds

    if type(ssid) ~= "string" then
        error("ssid required")
    end

    c:delete("wireless", "sta")

    c:set("wireless", "sta", "wifi-iface")
    c:set("wireless", "sta", "mode", "sta")
    c:set("wireless", "sta", "device", device or "")
    c:set("wireless", "sta", "ssid", ssid)
    c:set("wireless", "sta", "bssid", bssid or "")
    c:set("wireless", "sta", "band", band or "")
    c:set("wireless", "sta", "encryption", encryption or "none")
    c:set("wireless", "sta", "key", key or "")

    if wds then
        c:set("wireless", "sta", "network", "lan")
        c:set("wireless", "sta", "wds", "1")
    else
        c:set("wireless", "sta", "network", "wwan")
    end

    c:commit("wireless")

    M.fix_sta_ifname()
end

local function mtk_scan_dump(ifname)
    local iwpriv = require 'iwpriv'
    local index = 0
    local survey = {}
    local total

    while true do
        local data = iwpriv.get_site_survey2(ifname, index) or ""

        if data:find("No BssInfo") then
            break
        end

        if not total then
            total = tonumber(data:match("Total=(%d+)"))
        end

        data = data:sub((data:find("No")))

        local widths = {}

        widths.ch = {data:find("Ch "), 3}
        widths.ssid = {data:find("SSID "), 32}
        widths.bssid = {data:find("BSSID "), 17}
        widths.security = {data:find("Security "), 22}
        widths.signal = {data:find("Rssi"), 3}
        widths.wmode = {data:find("W%-Mode"), 11}
        widths.nt = {data:find("NT"), 2}

        if data:match("SSID_Len") then
            widths.ssid_len = {data:find("SSID_Len"), 2}
        else
            widths.ssid_len = {data:find("Len"), 2}
        end

        data = data:sub((data:find("%d+")))
        if not data then
            break
        end

        local function get_field(line, width, no_trim)
            local value = line:sub(width[1], width[1] + width[2])
            if no_trim then
                return value
            end

            return value:match("%S+")
        end

        local nindex = index
        while true do
            if not data:match('^%d+') then
                break
            end
            nindex = tonumber(data:match("^%d+"))
            local channel = tonumber(get_field(data, widths.ch))
            local ssid = get_field(data, widths.ssid, true)
            local bssid = get_field(data, widths.bssid)
            local security = get_field(data, widths.security)
            local signal = tonumber(get_field(data, widths.signal))
            --local wmode = get_field(data, widths.wmode)
            local nt = get_field(data, widths.nt)
            local ssid_len = tonumber(get_field(data, widths.ssid_len))

            if security == "NONE" then
                security = "OPEN"
            end

            local authmode, encrypttype = security:match("([%w-]+)/?(%w*)")

            if not encrypttype then
                encrypttype = "NONE"
            end

            if nt == "In" and (authmode:match("PSK") or authmode == "OPEN") then
                local auth_suites = {}
                local encryption = {
                    enabled = false
                }

                if authmode ~= "OPEN" then
                    encryption.enabled = true

                    if authmode:match("WPAPSK") or authmode:match("WPA2PSK") then
                        auth_suites[#auth_suites + 1] = "PSK"
                    end

                    if authmode:match("WPA3PSK") then
                        auth_suites[#auth_suites + 1] = "SAE"
                    end
                end

                encryption.auth_suites = auth_suites
                encryption.description = security

                survey[#survey + 1] = {
                    bssid = bssid,
                    ssid = ssid:sub(0, ssid_len),
                    channel = channel,
                    signal = signal,
                    encryption = encryption,
                    authmode = authmode,
                    encrypttype = encrypttype,
                    mode = "Master"
                }
            end

            data = data:sub(widths.ssid_len[1])

            local off = data:find('\n')
            if not off then
                break
            end

            data = data:sub(off + 1)
        end

        if nindex == index or index + 1 == total then
            break
        end

        index = nindex
    end

    return survey
end

M.scan_trigger = function(ifname, ssid)
    if ifname:match("^ra") or ifname:match("^apcli") then
        local iwpriv = require 'iwpriv'

        local c = uci.cursor()
        local dev = c:get("wireless", "@wifi-iface[0]", "device")

        if dev == "mt7628" then
            iwpriv.set(ifname, "SiteSurvey", ssid or '')
        else
            iwpriv.set(ifname, "ScanSSID", ssid or '')
            iwpriv.set(ifname, "PartialScanNumOfCh", '5')
            iwpriv.set(ifname, "PartialScan", '1')
        end
        return true
    else
        return scan.scan_trigger(ifname, ssid)
    end
end

M.scan_dump = function(ifname)
    if ifname:match("^ra") or ifname:match("^apcli") then
        return mtk_scan_dump(ifname)
    else
        return scan.scan_dump(ifname)
    end
end

M.disable_guest_during_scan_wifi = function()
    return fs.access("/sys/module/ath11k")
end

local function reg_match(channel, freq, ranges, country)
    if country == "US" and channel > 11 and channel < 36 then
        return false
    end

    for _, range in ipairs(ranges) do
        if range.power > 10 then
            if freq > range.start and freq < range["end"] then
                return true, range.dfs
            end
        end
    end
end

M.get_channel_list = function(country, filter)
    local ranges = reg.get(country)

    filter = filter or {}

    local chan2g_freq = {
        { 1, 2412 },
        { 2, 2417 },
        { 3, 2422 },
        { 4, 2427 },
        { 5, 2432 },
        { 6, 2437 },
        { 7, 2442 },
        { 8, 2447 },
        { 9, 2452 },
        { 10, 2457 },
        { 11, 2462 },
        { 12, 2467 },
        { 13, 2472 }
    }

    local chan5g_freq = {
        { 36, 5180 },
        { 40, 5200 },
        { 44, 5220 },
        { 48, 5240 },

        { 52, 5260 },
        { 56, 5280 },
        { 60, 5300 },
        { 64, 5320 },

        { 100, 5500 },
        { 104, 5520 },
        { 108, 5540 },
        { 112, 5560 },
        { 116, 5580 },
        { 120, 5600 },
        { 124, 5620 },
        { 128, 5640 },
        { 132, 5660 },
        { 136, 5680 },
        { 140, 5700 },
        { 144, 5720 },

        { 149, 5745 },
        { 153, 5765 },
        { 157, 5785 },
        { 161, 5805 },
        { 165, 5825 }
    }

    local chan2g = {}
    local chan5g = {}

    for _, ch in ipairs(chan2g_freq) do
        if reg_match(ch[1], ch[2], ranges, country) and not filter[ch[1]] then
            chan2g[#chan2g + 1] = { channel = ch[1], dfs = false }
        end
    end

    for _, ch in ipairs(chan5g_freq) do
        local ok, dfs = reg_match(ch[1], ch[2], ranges, country)
        if ok and not filter[ch[1]] then
            chan5g[#chan5g + 1] = { channel = ch[1], dfs = dfs }
        end
    end

    return chan2g, chan5g
end

function M.channel_is_dfs(channel, country)
    local ranges = reg.get(country)
    local freq

    if channel == "auto" then
        return false
    end

    channel= tonumber(channel)

    if channel <= 14 then
        freq =  2407 + channel * 5
    elseif channel >= 36 and channel <= 165 then
        freq = 5000 + channel * 5
    else
        return false
    end

    for _, range in ipairs(ranges) do
        if freq >= range.start and freq <= range["end"] then
            return range.dfs
        end
    end

    return false
end

local function read_json_file(path)
    if fs.access(path) then
        return cjson.decode(utils.readfile(path))
    end

    return nil
end

function M.get_wifi_mlo_support()
    local c = uci.cursor()
    local mlo_support = 0

    c:foreach("wireless", "wifi-device", function(s)
        local patch = "/usr/share/wifi-features-" .. s['.name']
        local features = read_json_file(patch)
        if features and features.mlo then
            mlo_support = mlo_support + 1
        end
    end)

    return mlo_support > 1
end

function M.get_wifi_6g_support()
    local c = uci.cursor()

    for s in c:each("wireless", "wifi-device") do
        if s.band == "6g" then
            return true
        end
    end

    return false
end

function M.get_wifi_5g_support()
    local c = uci.cursor()

    for s in c:each("wireless", "wifi-device") do
        if s.band == "5g" then
            return true
        end
    end

    return false
end

return M
