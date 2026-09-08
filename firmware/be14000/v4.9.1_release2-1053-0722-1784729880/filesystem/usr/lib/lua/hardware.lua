local M = {}

local lfactory = require "lfactory"
local rpc = require "oui.rpc"
local uci = require "uci"
local utils = require "oui.utils"
local ubus = require "oui.ubus"
local fs = require "oui.fs"

function M.platform_get_wan_status()
    local model = lfactory.get_model()
    local c = uci.cursor()
    local cmd
    local cable_status

    if model == "mt750" or model == "vixmini" or model == "mt300n-v2" or model == "n300" or model == "sf1200" or model == "sft1200" then
        cmd = "swconfig dev switch0 port 0 show | grep link:up"
    elseif model == "ar750s" then
        cmd = "swconfig dev switch0 port 1 show | grep link:up"
    elseif model == "x1200" then
        cmd = "swconfig dev switch0 port 5 show | grep link:up"
    elseif model == "b3000" then
        cmd = "swconfig dev switch1 port 1 show | grep link:up"
    elseif model == "mv1000" or model == "mt1300" or model == "mg1300" or model == "a1300" then
        cmd = "ethtool wan|grep Link.*yes"
    elseif model == "xe300" or model == "xe300v2" or model == "a1300"
      or model == "b1300" or model == "s1300" or model == "ap1300"
      or model == "mt6000" or model == "be5100" or model == "mt5000" then
        cmd = "ethtool eth1|grep Link.*yes"
    elseif model == "sft3000" then
        cmd = "ethtool eth2|grep Link.*yes"
    elseif model == "be14000" then
        cable_status = lfactory.check_wan_cable()
    else
        cmd = "ethtool eth0|grep Link.*yes"
    end

    local ret = ""
    if cmd then
        local rs_file = assert(io.popen(cmd))
        ret = rs_file:read() or ""
        rs_file:close()
    end

    local cable_enabled
    local tmp
    if string.len(ret) >5 or cable_status then
        tmp = c:get("network", "wan", "metric") or ""
        if type(tmp) ~= "string" or tmp:gsub("%s+", "") == "" then
            c:set("network", "wan", "metric", "10")
            c:commit("network")
        end
        cable_enabled = true
    else
        cable_enabled = false
    end



    local wan2lan = c:get("glconfig", "general", "wan2lan") or ""
    if wan2lan == "1" or model == "usb150" then
        cable_enabled = false
    end

    -- macclone usb150
    local macclone = c:get("glconfig", "general", "macclone") or ""
    local macclone_enabled = false
    local session = rpc.session()
    -- local remote_addr, cmd_str, rs_file, mac_lower, remote_mac = ""
    if model == "usb150" then
        local remote_addr = session.remote_addr
        local cmd_str = "ip ne | grep br-lan | grep "..remote_addr.." | awk '{print $5}'"
        local rs_file = assert(io.popen(cmd_str))
        local mac_lower = rs_file:read() or ""
        local remote_mac = string.upper(mac_lower)
        rs_file:close()

        local sta_macaddr = c:get("wireless", "sta", "macaddr") or ""
        if macclone == "1" or sta_macaddr == remote_mac then
            macclone_enabled = true
        end
    else
        local wan_device = lfactory.get_wan_port()
        c:foreach('network', 'device', function(s)
            if wan_device and s.name == wan_device then
                local mode = s.mac_mode
                if mode and mode:find("[cr]") then
                    macclone_enabled = true
                end
            end
        end)
    end
    return  { cable_enabled = cable_enabled , macclone_enabled = macclone_enabled }
end

function M.platform_get_secondwan_status()
    local c = uci.cursor()
    local model = lfactory.get_model()

    local ifname = lfactory.get_secondwan_port()
    local cable_enabled = ifname and utils.readfile('sys/class/net/' .. ifname .. '/carrier', '*n') == 1

    if model == "b3000" then
        local cmd
        cmd = "swconfig dev switch1 port 2 show | grep link:up"
        local rs_file = assert(io.popen(cmd))
        local ret = rs_file:read() or ""
        rs_file:close()
        cable_enabled = #ret > 5
    end

    if model == "be9300" or model == "be6500" then
        local cmd
        cmd = "swconfig dev switch1 port 7 show | grep link:up"
        local rs_file = assert(io.popen(cmd))
        local ret = rs_file:read() or ""
        rs_file:close()
        cable_enabled = #ret > 5
    end

    if model == "be14000" then
        cable_enabled = lfactory.check_secondwan_cable()
    end

    if model == "mt5000" then
        local cmd
        cmd = "swconfig dev switch0 port 0 show | grep link:up"
        local rs_file = assert(io.popen(cmd))
        local ret = rs_file:read() or ""
        rs_file:close()
        cable_enabled = #ret > 5
    end

    local lan2wan = c:get("glconfig", "general", "lan2wan") == "1"
    if lan2wan == false then
        cable_enabled = false
    end

    local macclone_enabled = false

    c:foreach('network', 'device', function(s)
        if ifname and s.name == ifname then
            local mode = s.mac_mode
            if mode and mode:find("[cr]") then
                macclone_enabled = true
            end
        end
    end)

    return  { cable_enabled = cable_enabled , macclone_enabled = macclone_enabled }
end

function M.platform_get_usbwan_status()
    local c = uci.cursor()
    local cable_enabled = false
    local macclone_enabled = false

    local usb_port = lfactory.get_device_usbwan_port()
    if usb_port then
        local cmd = "ethtool " .. usb_port .. "|grep Link.*yes"
        local rs_file = assert(io.popen(cmd))
        local ret = rs_file:read() or ""
        rs_file:close()

        if string.len(ret) >5 then
            cable_enabled = true
        else
            cable_enabled = false
        end
    end

    local usb_lan2wan = c:get("glconfig", "general", "usb_lan2wan") == "1"
    if usb_lan2wan == false then
        cable_enabled = false
    end

    return  { cable_enabled = cable_enabled , macclone_enabled = macclone_enabled }
end

function M.platform_detect_usbwan_kmwan_config(interface)
    local c = uci.cursor()
    local interface6 = interface .. 6

    local kmwan_interface = c:get('kmwan', interface)
    if kmwan_interface then
        return
    end

    c:set('kmwan', interface, 'member')
    c:set('kmwan', interface, 'interface', interface)
    c:set('kmwan', interface, 'metric', '50')
    c:set('kmwan', interface, 'weight', '1')
    c:set('kmwan', interface, 'addr_type', '4')
    c:set('kmwan', interface, 'track_mode', 'force')
    c:set('kmwan', interface, 'check', '1')
    c:set('kmwan', interface, 'disabled', '0')

    local kmwan_ip_list = {}
    for _, s in pairs(c:get_all('glconfig')) do
        if s['.name'] == 'general' then
            local tracks = s.track_ip or {}
            for _, v in pairs(tracks) do
                kmwan_ip_list[#kmwan_ip_list + 1] = 'ping,' .. v
            end
        end
    end
    c:set('kmwan', interface, 'tracks', kmwan_ip_list)

    local kmwan_interface6 = c:get('kmwan', interface6)
    if kmwan_interface6 then
        return
    end

    c:set('kmwan', interface6, 'member')
    c:set('kmwan', interface6, 'interface', interface6)
    c:set('kmwan', interface6, 'metric', '50')
    c:set('kmwan', interface6, 'weight', '1')
    c:set('kmwan', interface6, 'addr_type', '6')
    c:set('kmwan', interface6, 'track_mode', 'force')
    c:set('kmwan', interface6, 'disabled', '1')

    local kmwan_ip_list6 = {}
    for _, s in pairs(c:get_all('glconfig')) do
        if s['.name'] == 'general' then
            local tracks = s.track_ipv6 or {}
            for _, v in pairs(tracks) do
                kmwan_ip_list6[#kmwan_ip_list6 + 1] = 'ping,' .. v
            end
        end
    end
    c:set('kmwan', interface6, 'tracks', kmwan_ip_list6)

    c:commit('kmwan')
end

function M.platform_support_secondwan()
    local model = lfactory.get_model()
    if model == "xe3000" or model == "mt6000" or model == "x3000" or model == "b3000" or model == "x2000" or model == "be9300" or model == "be3600"
            or model == "xe300v2" or model == "sft3000" or model == "be6500" or model == "be5100" or model == "mt3600be" or model == "mt5000" or model == "be10000"
            or model == "be14000" or model == "mg1300" then
        return true
    end
    return false
end

function M.platform_vendor_port_mode_setting(interface, mode)
    local model = lfactory.get_model()
    local c = uci.cursor()
    if model == "e5800" then
        if mode == "wan" then
            local proto = c:get('network', 'wan', 'proto')
            local vlanid = c:get('glconfig', 'general', 'wan') or 0
            if proto == "dhcp" then
                -- <profile-id>, <iface_type>, <vlanid>, <proto>, <ip_type>, <isDefault>, <username>, <password>
                ngx.pipe.spawn({"/etc/data/backhaulCommonConfig.sh", "create_wan_profile", "101", "2", vlanid, proto, "10","1"}, { stdout_read_timeout = 100000 }):wait()
            elseif proto == "pppoe" then
                local username = c:get('network', 'wan', 'username')
                local password = c:get('network', 'wan', 'password')
                -- <profile-id>, <iface_type>, <vlanid>, <proto>, <ip_type>, <isDefault>, <username>, <password>
                ngx.pipe.spawn({"/etc/data/backhaulCommonConfig.sh", "create_wan_profile", "101", "2", vlanid, proto, "10", "1", username, password}, { stdout_read_timeout = 100000 }):wait()
            elseif proto == "static" then
                -- <profile-id>, <iface_type>, <vlanid>, <proto>, <ip_type>, <isDefault>, <ipaddr>, <netmask>, <gateway>, <dns1>, <dns2>
                local ipaddr = c:get('network', 'wan', 'ipaddr')
                local netmask = c:get('network', 'wan', 'netmask')
                local gateway = c:get('network', 'wan', 'gateway')
                local dns = c:get('network', 'wan', 'dns')
                ngx.pipe.spawn({"/etc/data/backhaulCommonConfig.sh", "create_wan_profile", "101", "2", vlanid, proto, "4", "1", ipaddr, netmask, gateway, dns[1], dns[2] or ""}, { stdout_read_timeout = 100000 }):wait()
            end

            -- <mode> <no_of_nics> <nic_number> $1:mode [0-LAN 1-WAN 2-WAN_LAN] $2:no_of_nics [2] $3:nic_number [1,2]
            -- $1:eth_iface_name $2:type[0-LAN, 1-WAN] $3:NIC number[1,2] " .. interface .. "
            ngx.pipe.spawn("/etc/data/tethering.sh set_eth_config 2 1 1;sleep 1;/etc/data/tethering.sh set_eth_type eth0 1 1")
            ngx.pipe.spawn("/etc/data/backhaulCommonConfig.sh set_ipa_load_balance")
        else
            ngx.pipe.spawn("/etc/data/tethering.sh set_eth_config 2 1 1;sleep 1;/etc/data/tethering.sh set_eth_type eth0 0 1")
            ngx.pipe.spawn("/etc/data/backhaulCommonConfig.sh set_ipa_load_balance")
        end

        return true
    else
        return false
    end
end

function M.platform_vendor_port_config_setting(proto, vlanid, username, password, ipaddr, netmask, gateway, dns)
    local model = lfactory.get_model()
    if model == "e5800" then
        if proto == "dhcp" then
            -- <profile-id>, <iface_type>, <vlanid>, <proto>, <ip_type>, <isDefault>, <username>, <password>
            ngx.pipe.spawn("/etc/data/backhaulCommonConfig.sh update_wan_profile 101 2 " .. vlanid .. " " .. proto .. " 10 1")
        elseif proto == "pppoe" then
            -- <profile-id>, <iface_type>, <vlanid>, <proto>, <ip_type>, <isDefault>, <username>, <password>
            ngx.pipe.spawn({"/etc/data/backhaulCommonConfig.sh", "update_wan_profile", "101", "2", vlanid, proto, "10", "1", username, password})
        elseif proto == "static" then
            -- <profile-id>, <iface_type>, <vlanid>, <proto>, <ip_type>, <isDefault>, <ipaddr>, <netmask>, <gateway>, <dns1>, <dns2>
            ngx.pipe.spawn({"/etc/data/backhaulCommonConfig.sh", "update_wan_profile", "101", "2", vlanid, proto, "4", "1", ipaddr, netmask, gateway, dns[1], dns[2] or ""})
        end
        return true
    else
        return false
    end
end

local function reconnect_switch_port(start_idx, end_idx, switch_dev, down_action, up_action)
    -- defaults to previous behaviour
    start_idx = tonumber(start_idx) or 0
    end_idx = tonumber(end_idx) or 4
    down_action = down_action or "enable_port 0"
    up_action = up_action or "enable_port 1"
    switch_dev = switch_dev or "switch0"

    local wan_ports = {}
    local rs = io.popen("uci -q show eth_ports_config_map 2>/dev/null")
    if rs then
        local sw, p, m, wt
        for line in rs:lines() do
            local s = line:match("%.switch='?(.-)'?$")
            if s then sw = s end
            local port_v = line:match("%.port='?(.-)'?$")
            if port_v then p = port_v end
            local mode_v = line:match("%.mode='?(.-)'?$")
            if mode_v then m = mode_v end
            local wantype_v = line:match("%.wantype='?(.-)'?$") or line:match("%.wan_type='?(.-)'?$")
            if wantype_v then wt = wantype_v end

            if sw and p and m and wt then
                -- skip ports configured as WAN
                if sw == switch_dev and m == "wan" and wt == "wan" then
                    wan_ports[tostring(p)] = true
                end
                sw, p, m, wt = nil, nil, nil, nil
            end
        end
        rs:close()
    end

    for i = start_idx, end_idx do
        if not wan_ports[tostring(i)] then
            os.execute("swconfig dev " .. switch_dev .. " port " .. i .. " set " .. down_action .. " 2>/dev/null")
            ngx.sleep(1)
            os.execute("swconfig dev " .. switch_dev .. " port " .. i .. " set " .. up_action .. " 2>/dev/null")
            ngx.sleep(1)
        end
    end
end

function M.platform_switch_restart()
    local model = lfactory.get_model()

    if model == "ar150" or model == "mifi" or model == "ar750"
      or model == "ar300m" or model == "x750" or model == "e750"
      or model == "x300b" or model == "xe300" or model == "s200"
      or model == "ar750s" then
        ngx.pipe.spawn("swconfig dev switch0 set reset")
    elseif model == "a1300" or model == "b1300" or model == "s1300" or model == "ap1300" then
        ngx.pipe.spawn("swconfig dev switch0 set linkdown 1;sleep 1;swconfig dev switch0 set linkdown 0")
    elseif model == "mt300n-v2" then
        ngx.pipe.spawn("swconfig dev switch0 port 1 set disable 1;swconfig dev switch0 set apply 1;sleep 1;swconfig dev switch0 port 1 set disable 0;swconfig dev switch0 set apply 1")
    elseif model == "b3000" then
        ngx.pipe.spawn("swconfig dev switch1 load network")
    elseif model == "sft1200" or model == "sf1200" then
        ngx.pipe.spawn("ip link set dev eth0 down;sleep 1;ip link set dev eth0 up")
    elseif model == "x2000" then
        ngx.pipe.spawn("ssdk_sh port reset set 2")
    elseif model == "be9300" or model == "be6500" then
        ngx.pipe.spawn("for i in `seq 4 7`;do swconfig dev switch1 port $i set disable 1;swconfig dev switch1 port $i set disable 0;done")
    elseif model == "mt5000" then
        ngx.pipe.spawn("for i in `seq 0 1`;do swconfig dev switch0 port $i set disable 1;sleep 1;swconfig dev switch0 port $i set disable 0;done")
    elseif model == "be14000" then
        reconnect_switch_port(0, 4, "switch0", "enable_port 0", "enable_port 1")
    end
end
function M.platform_usb_lan_restart()
    local otg_support = utils.readfile("/proc/gl-hw-info/usb-otg")
    if otg_support and otg_support:match("true") then
        local usb_proto

        for port in utils.readfile("/proc/gl-hw-info/usb-port"):gmatch("([^,]+)") do
            port = port:gsub("[\r\n]", "")
            if fs.access("/sys/bus/usb/devices/" .. port .. "/idVendor") then
                if port == '1-1' then
                    usb_proto = "usb1"
                else
                    usb_proto = "usb2"
                end

                break
            end
        end

        if usb_proto then
            ngx.pipe.spawn("echo 1 > /sys/class/power_supply/charger/device/sgm41542s/mos1_pin")
            ngx.sleep(4)
            ngx.pipe.spawn("echo 0 > /sys/class/power_supply/charger/device/sgm41542s/mos1_pin")
        else
            local usb_udc = utils.readfile("/sys/kernel/config/usb_gadget/g1/UDC"):gsub("[\r\n]", "")
            ngx.pipe.spawn("echo '' > /sys/kernel/config/usb_gadget/g1/UDC")
            ngx.sleep(2)
            ngx.pipe.spawn("echo " .. usb_udc .. " > /sys/kernel/config/usb_gadget/g1/UDC")
        end
    end
end

function M.platform_get_time_info()
    local model = lfactory.get_model()
    local api_extra = 0
    if model == "xe300v2" or model == "mg1300" then
        api_extra = 10
    elseif model == "be14000" then
        api_extra = 15
    end

    if model == "ar150" or model == "mifi" or model == "x300b"
      or model == "s200" or model == "a1300" or model == "b3000"
      or model == "x2000" or model == "be9300" or model == "be6500" then
        return  { upgrade = 240 , reboot = 120, init = 10 , api_extra = api_extra }
    elseif model == "be3600" then
        return  { upgrade = 180 , reboot = 70, init = 10 , api_extra = api_extra }
    elseif model == "e5800" then
        return  { upgrade = 240 , reboot = 80, init = 8 , api_extra = api_extra }
    elseif model == "xe300" or model == "x750" or model == "e750"
      or model == "ar750" or model == "ar300m" or model == "sft1200"
      or model == "b1300" or model == "ar750s" or model == "mt1300"
      or model == "mt300n-v2" or model == "xe300v2" or model == "rt1500" then
        return  { upgrade = 240 , reboot = 180, init = 10 , api_extra = api_extra }
    elseif model == "be10000" then
        return  { upgrade = 110 , reboot = 80, init = 3 , api_extra = api_extra }
    elseif model == "be14000" then
        return  { upgrade = 110 , reboot = 100, init = 3 , api_extra = api_extra }
    else
        return  { upgrade = 120 , reboot = 60, init = 3 , api_extra = api_extra }
    end
end

function M.platform_telething_whether_removing_usb0()
    local model = lfactory.get_model()
    local usb

    if model == "mv1000" then
        usb = "usb0"
    elseif model == "x3000" then
        usb = "rm500u_5gnet"
    end

    return usb
end

function M.platform_factory_reset_mcu()
    local model = lfactory.get_model()

    if model == "e750" then
        ubus.call("mcu", "system_reft", { system = 'reft' })
        ngx.pipe.spawn("sleep 2;/etc/init.d/mcu stop")
    end
end

function M.platform_older_models_add_delay()
    local model = lfactory.get_model()

    if model == "ar150" or model == "mifi" or model == "ar750"
      or model == "ar300m" or model == "x750" or model == "e750"
      or model == "x300b" or model == "xe300" or model == "s200"
      or model == "sft1200" or model == "b1300" or model == "a1300"
      or model == "ar750s"  or model == "mt1300" or model == "mt300n-v2"
      or model == "xe300v2" then
        ngx.sleep(8)
    elseif model == "be9300" or model == "be6500" or model == "e5800" then
        ngx.sleep(5)
    end
end

function M.platform_netmode_set_back_router(lan2wan,wan2lan,lan2wan_bk)
    local model = lfactory.get_model()
    local c = uci.cursor()
    local vlanid = c:get("network", "secondwan", "vlanid")
    local vlanid_num = tonumber(vlanid) or 0

    if model == "b3000" then
        if lan2wan_bk == '1' then
            c:set("network", "vlan_secondwan", "switch_vlan")
            c:set("network", "vlan_secondwan", "device","switch1")
            c:set("network", "vlan_secondwan", "ports","2 6t")
            c:set("network", "vlan_lan", "ports", "3 6t")
            c:set("glconfig", "general", "lan2wan", "1")
            c:delete("glconfig", "general", "lan2wan_bk")

            if vlanid_num >= 1 and vlanid_num <= 4094 then
                c:set("network", "vlan_secondwan", "vlan",vlanid)
                c:set("network", "vlan_secondwan", "vid",vlanid)
            else
                c:set("network", "vlan_secondwan", "vlan",'3')
                c:set("network", "vlan_secondwan", "vid",'3')
            end
        elseif lan2wan == '1' then
            c:delete("network", "vlan_secondwan")
            c:set("network", "secondwan", "disabled","1")
            c:set("network", "vlan_lan", "ports", "2 3 6t")
            c:delete("glconfig", "general", "lan2wan")
            c:set("glconfig", "general", "lan2wan_bk", "1")
        end

        if wan2lan == '1' then
            c:set("network", "lan", "ifname", {"eth1.1", "eth1.2"})
        end

    end
end

function M.set_wan_ports_to_vlan(is_vlan)
    local model = lfactory.get_model()
    local c = uci.cursor()
    if model == "b3000" then
        local wan_vlanid = c:get("network", "wan", "vlanid")
        local wan_vlanid_num = tonumber(wan_vlanid) or 0
        local wan_port = c:get("board_special", "switch", "wan");
        local cpu_port = c:get("board_special", "switch", "cpu");
        local vlan_wan_ports = c:get("network", "vlan_wan", "ports");
        if vlan_wan_ports and wan_port and cpu_port then
            if wan_vlanid_num >=1 and wan_vlanid_num <= 4094 and is_vlan then
                c:set("network", "vlan_wan", "ports", wan_port.."t".." "..cpu_port.."t")
            else
                c:set("network", "vlan_wan", "ports", wan_port.." "..cpu_port.."t")
            end
            c:commit('network')
        end
    elseif model == "x2000" then
        local wan_vlanid = c:get("network", "wan", "vlanid") or "0"
        local wan_vlanid_num = tonumber(wan_vlanid)
        local wan2lan = c:get("glconfig", "general", "wan2lan") or "0"
        if wan_vlanid_num >=1 and wan_vlanid_num <= 4094  and is_vlan then
            local wan_port = c:get("board_special", "hardware", "wan")
            c:set("network", "wan", "ifname", wan_port)
        else
            if wan2lan == "0" then
                local wan_old_port = c:get("network", "wan_dev", "name")
                c:set("network", "wan", "ifname", wan_old_port)
            end
        end
        c:commit("network")
    end
end

return M
