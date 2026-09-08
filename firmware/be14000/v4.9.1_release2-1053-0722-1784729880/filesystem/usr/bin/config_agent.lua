--[[
 * ***************************************************************************
 * *  Mediatek Inc.
 * * 4F, No. 2 Technology 5th Rd.
 * * Science-based Industrial Park
 * * Hsin-chu, Taiwan, R.O.C.
 * *
 * * (c) Copyright 2002-2019, Mediatek, Inc.
 * *
 * * All rights reserved. Mediatek's source code is an unpublished work and the
 * * use of a copyright notice does not imply otherwise. This source code
 * * contains confidential trade secret material of Ralink Tech. Any attemp
 * * or participation in deciphering, decoding, reverse engineering or in any
 * * way altering the source code is stricitly prohibited, unless the prior
 * * written consent of Mediatek, Inc. is obtained.
 * ***************************************************************************
 *
 *  Module Name:
 *  MAP Config Agent
 *
 *  Abstract:
 *  MAP Config Agent
 *
 *  Revision History:
 *  Who         When          What
 *  --------    ----------    -----------------------------------------
 *  Kapil.Gupta 2019/07/18    In-device implementation of MAP Config agent
 * ***************************************************************************
]]
-- env variables
WTS_CONF_FILE = "/etc/map/wts_bss_info_config"
WTS_BSTA_CONF_FILE = "/etc/map/wts_bsta_mlo_config"
WTS_MLO_LINK_CONF_FILE = "/etc/map/mlo_link_config"
SEND_1905_FRAME_CONF = "/etc/dev_send_1905_config"
P1905_DEBUG_LEVEL = "0"
WAPP_DEBUG_LEVEL = "0"
MAPD_DEBUG_LEVEL = "0"
CONFIG_AGENT_LOGS_FILE = "/tmp/config_agent.log"
MyDevRole = "agent" --default role, will be overwritten
-- from 0,3
MAX_NUM_MBSS = 3
-- from 0,2
MAX_NUM_RADIO = 2
L1_PROFILE_FILE = "/etc/wireless/l1profile.dat"
dev_start_buffer_mtype = ""
IS_BELLWETHER = 0
IS_EAGLE = 0
IS_LOGAN = 0
IS_DSA = 1

if (arg[1] == nil or arg[1] == "") then
	ra_interface = "ra0"
elseif (arg[1] == "rai0") then
	ra_interface = arg[1]
elseif (arg[1] == "Bellwether") then
	ra_interface = "ra0"
	IS_BELLWETHER = 1
	IS_LOGAN = 1
elseif (arg[1] == "Eagle") then
        ra_interface = "ra0"
	IS_EAGLE = 1
        IS_LOGAN = 1
end

function logger(string)

	if (string == nil) then
		return
	end
	string = "config_agent: ".. string
	print(string)
	-- appends logs to logger file
	io.write(string)
	io.write('\n')
end

function os.capture(cmd, raw)
	local f = assert(io.popen(cmd, 'r'))
	local s = assert(f:read('*a'))
	f:close()
	if raw then return s end
	s = string.gsub(s, '^%s+', '')
	s = string.gsub(s, '%s+$', '')
	s = string.gsub(s, '[\n\r]+', ' ')
	return s
end

function sleep(n)
	execute("sleep " .. tonumber(n))
end

function execute(cmd)

	local log_string = ""
	if (cmd == nil) then
		logger("cannot execute nill command")
		return
	end
	log_string = "executing: " .. cmd
	logger(log_string)
	os.execute(cmd)
end

function hostapd_interface_Up()

        local BssCnt, index
        local Phyid, Conffile
        local ExtIfname, IfName

	command = "cat /etc/map/mapd_default.cfg | grep Cert_SKU | cut -c 10-11"
	CERT_SKU = os.capture(command)

	if (string.match(CERT_SKU, "28") ) then
		for BssCnt = 0, 3 do
			ExtIfname = "ra"
			index = (BssCnt*2)
			IfName = ExtIfname ..""..BssCnt
			Phyid = 0
			Conffile = "/nvram/hostapd"..index..".conf"
			execute("hostapd_cli -i global raw ADD bss_config=phy"..Phyid..":"..Conffile)
			execute("hostapd_cli -i "..IfName.." enable")
		end
		for BssCnt = 0, 3 do
			ExtIfname = "rai"
			index = (BssCnt*2 + 1)
			IfName = ExtIfname ..""..BssCnt
			Phyid = 1
			Conffile = "/nvram/hostapd"..index..".conf"
			execute("hostapd_cli -i global raw ADD bss_config=phy"..Phyid..":"..Conffile)
			execute("hostapd_cli -i "..IfName.." enable")
		end
	elseif (string.match(CERT_SKU, "26") ) then
		for BssCnt = 0, 3 do
			ExtIfname = "ra"
			index = (BssCnt*2 + BssCnt)
			IfName = ExtIfname ..""..BssCnt
			Phyid = 0
			Conffile = "/nvram/hostapd"..index..".conf"
			execute("hostapd_cli -i global raw ADD bss_config=phy"..Phyid..":"..Conffile)
			execute("hostapd_cli -i "..IfName.." enable")
		end
		for BssCnt = 0, 3 do
			ExtIfname = "rai"
			index = (BssCnt*2 + BssCnt + 1)
			IfName = ExtIfname ..""..BssCnt
			Phyid = 1
			Conffile = "/nvram/hostapd"..index..".conf"
			execute("hostapd_cli -i global raw ADD bss_config=phy"..Phyid..":"..Conffile)
			execute("hostapd_cli -i "..IfName.." enable")
		end
	end

end
function IfaceUp(Iface)
	--execute("ifconfig "..Iface.." up")
	execute("brctl addif br-lan "..Iface)
end

function IfaceDown(Iface)
	--execute("ifconfig "..Iface.." down")
	execute("brctl delif br-lan "..Iface)
end

function IfaceDownUp(Iface, IfUp)
	if (IfUp == true) then
		IfaceUp(Iface)
	elseif (IfUp == false) then
		IfaceDown(Iface)
	else
		logger("invalid argument, bringing Interface up")
		IfaceUp(Iface)
	end
end

function RadioApIfaceDownUp(ExtIfname, IfUp)
	local IfName
	if (ExtIfname ~= nil and ExtIfname ~= "") then
		for BssCnt=0, MAX_NUM_MBSS do
			IfName = ExtIfname ..""..BssCnt
			IfaceDownUp(IfName, IfUp)
		end
	end
end

function ApInterfaceDownUp(IfUp)

	local IfaceState = ""
	local BssCnt, RadioCnt
	local ExtIfname, IfName
	local start_pos, second_iface
	local start_pos_B
	local model

	for RadioCnt = 0, MAX_NUM_RADIO do
		ExtIfname = os.capture("datconf -f " ..L1_PROFILE_FILE.. " get INDEX"..RadioCnt.."_ext_ifname")
		model = os.capture("datconf -f " ..L1_PROFILE_FILE.. " get INDEX"..RadioCnt)
		if (string.find(ExtIfname, ";")) then
			start_pos = string.find(ExtIfname, ";")
		        first_iface = string.sub(ExtIfname, 0, start_pos-1)
			RadioApIfaceDownUp(first_iface, IfUp)
			if (IS_LOGAN == 1 and IS_EAGLE ==1 and (string.match(model, "MT7992") == nil or string.match(model, "MT7993") == nil)) then
				if (string.find(ExtIfname, ";", start_pos+1)) then
					start_pos_B = string.find(ExtIfname, ";", start_pos+1)
					second_iface = string.sub(ExtIfname, start_pos+1, start_pos_B-1)
				else
					second_iface = string.sub(ExtIfname, start_pos+1, string.len(ExtIfname))
				end
				RadioApIfaceDownUp(second_iface, IfUp)
                        else
				second_iface = string.sub(ExtIfname, start_pos+1, string.len(ExtIfname))
				RadioApIfaceDownUp(second_iface, IfUp)
			end
		else
			RadioApIfaceDownUp(ExtIfname, IfUp)
		end
	end
end

function RadioStaDownUp(StaIfName, IfUp)
	local ifname
	if (StaIfName ~= nil and StaIfName ~= "") then
		ifname = StaIfName .."0"
		IfaceDownUp(ifname, IfUp)
	end
end

function StaInterfaceDownUp(IfUp)

	local IfaceState = ""
	local StaIfName, RadioCnt, ifname
	local start_pos, second_iface, first_iface
	local start_pos_B
	local model
	for RadioCnt=0, MAX_NUM_RADIO do
		StaIfName = os.capture("datconf -f " ..L1_PROFILE_FILE.. " get INDEX"..RadioCnt.."_apcli_ifname")
		model = os.capture("datconf -f " ..L1_PROFILE_FILE.. " get INDEX"..RadioCnt)
		if (string.find(StaIfName, ";")) then
			start_pos = string.find(StaIfName, ";")
		        first_iface = string.sub(StaIfName, 0, start_pos-1)
			RadioStaDownUp(first_iface, IfUp)
			if (IS_LOGAN == 1 and IS_EAGLE ==1 and (string.match(model, "MT7992") == nil or string.match(model, "MT7993") == nil)) then
				if (string.find(StaIfName, ";", start_pos+1)) then
					start_pos_B = string.find(StaIfName, ";", start_pos+1)
					second_iface = string.sub(StaIfName, start_pos+1, start_pos_B-1)
				else
					second_iface = string.sub(StaIfName, start_pos+1, string.len(StaIfName))
				end
				RadioStaDownUp(second_iface, IfUp)
			else
				second_iface = string.sub(StaIfName, start_pos+1, string.len(StaIfName))
				RadioStaDownUp(second_iface, IfUp)
			end
		else
			RadioStaDownUp(StaIfName, IfUp)
		end

	end
end

function RadioStaReset(StaIfName)
	if (StaIfName ~= nil and StaIfName ~= "") then
		StaIfName = StaIfName.."0"
		if (IS_LOGAN == 1) then
			execute("mwctl "..StaIfName.." set ApCliEnable=0")
			execute("mwctl "..StaIfName.." set ApCliSsid=")
		else
			execute("iwpriv "..StaIfName.." set ApCliEnable=0")
			execute("iwpriv "..StaIfName.." set ApCliSsid=")
		end
	end
end

function StaInterfaceReset()
	local StaIfName, RadioCnt, extName

	for RadioCnt=0, MAX_NUM_RADIO do
		extName = os.capture("datconf -f " ..L1_PROFILE_FILE.. " get INDEX"..RadioCnt.."_apcli_ifname")
		if (string.find(extName, ";")) then
			start_pos = string.find(extName, ";")
		    first_iface = string.sub(extName, 0, start_pos-1)
			RadioStaReset(first_iface)
			second_iface = string.sub(extName, start_pos+1, string.len(extName))
			RadioStaReset(second_iface)
		else
			RadioStaReset(extName)
		end
	end
end

function GetSwitchArch()
	chip_an8855 = os.capture("cat /proc/air_sw/device | grep an8855")

	if (chip_an8855 ~= nil and chip_an8855 ~= "") then
		reg_hex = os.capture("switch an8855 reg r 10208a10 | awk -F = '{print $3}'")
		if (reg_hex ~= nil and reg_hex ~= "" and reg_hex == "0x920") then
			IS_DSA = 1
			print("AN8855 DSA")
		else
			IS_DSA = 0
			print("AN8855 GSW")
		end
	else
		reg_hex = os.capture("switch reg r 2610 | awk -F = '{print $3}'")
		print("switch reg r 2610: ["..reg_hex.."]")
		reg_len = string.len(reg_hex)
		print("switch reg r 2610 len:"..reg_len)
		reg_hex = string.sub(reg_hex, reg_len-1, reg_len-1)
		print("get bit 4 - bit 7: ["..reg_hex.."]")
		--bit5=1 dsa bit5=0 gsw
		if (reg_hex == "2") then IS_DSA = 1
		elseif (reg_hex == "3") then IS_DSA = 1
		elseif (reg_hex == "6") then IS_DSA = 1
		elseif (reg_hex == "7") then IS_DSA = 1
		elseif (reg_hex == "a") then IS_DSA = 1
		elseif (reg_hex == "b") then IS_DSA = 1
		elseif (reg_hex == "e") then IS_DSA = 1
		elseif (reg_hex == "f") then IS_DSA = 1
		else IS_DSA = 0
		end
	end

	if (IS_DSA == 1) then print("SWITCH DSA ARCH")
	else print("SWITCH GSW ARCH")
	end
end

function AddLanIn1905d(Backhaul)
	execute ("sed -i '/^#lan=/d' /etc/map/1905d.cfg")
	execute ("sed -i '/^lan=/d' /etc/map/1905d.cfg")
	if (IS_DSA == 0) then
		if (string.match(Backhaul, "eth")) then
			execute ("sed -i '$alan=eth0' /etc/map/1905d.cfg")
			print("cmd: add lan=eth0 to 1905d.cfg")
		end
	else
		local port_1905 = 0
		if (string.match(Backhaul, "eth")) then
			for port_1905 = 0,4 do
				print("lan"..port_1905.."")
				if(string.find(LAN_IN_DSA, "lan"..port_1905.."")) then
					lan_ifconfig = os.capture("ifconfig lan"..port_1905.."")
					if(string.find(lan_ifconfig, "HWaddr")) then
						execute ("sed -i '$alan=lan"..port_1905.."' /etc/map/1905d.cfg")
						sleep(1)
					end
				end
			end
		end
	end
end

function BRConfigOnCtrl()
	local lan_port = 0
	if (IS_DSA == 0) then
		execute ("ifconfig eth0 up")
		sleep(1)
		execute ("brctl addif br-lan eth0")
		print("cmd: brctl addif br-lan eth0")
	else
		for lan_port = 0,4 do
			print("lan"..lan_port.."")
			if (string.find(LAN_IN_DSA, "lan"..lan_port.."")) then
				lan_intf = "lan"..lan_port..""
				execute ("ifconfig "..lan_intf.." up")
				sleep(1)
				execute ("brctl addif br-lan "..lan_intf.."")
				sleep(1)
			end
		end
	end
	print("end call BRConfigCtrl")
end

function BRConfigByBackhaul(Backhaul)
	local lan_port = 0
	if (string.match(Backhaul, "eth")) then
		if (IS_DSA == 0) then
			execute ("brctl addif br-lan eth0")
			print("cmd: brctl addif br-lan eth0")
		else
			for lan_port = 0,4 do
				print("lan"..lan_port.."")
				if (string.find(LAN_IN_DSA, "lan"..lan_port.."")) then
					lan_intf = "lan"..lan_port..""
					execute ("brctl addif br-lan "..lan_intf.."")
					sleep(1)
				end
			end
		end
	else
		if (IS_DSA == 0) then
			execute ("brctl delif br-lan eth0")
		else
			for lan_port = 0,4 do
				print("lan"..lan_port.."")
				if(string.find(LAN_IN_DSA, "lan"..lan_port.."")) then
					lan_intf = "lan"..lan_port..""
					execute ("brctl delif br-lan "..lan_intf.."")
					sleep(1)
				end
			end
		end
	end
	print("end call BRConfigByBackhaul")
end

function DevResetDefaultMediatek (Program, DevRole, Agt_type)
	--[[ Concurrent Mode: CntlSupport:1 AgentSupport:1 MapRoot:1 MyDevRole:agent/controller
	Stand Alone Mode: CntlSupport0/1 AgentSupport:1/0 MapRoot:1 MyDevRole:agent/controller
	MAUT: CntlSupport:0 AgentSupport:1 MapRoot:0 MyDevRole:agent

	--]]
	local i, WappEnable
	MyDevRole = DevRole

	GetSwitchArch()

	if (Program == nil or MyDevRole == nil) then
		logger("got incorrect params in set dev role")
	end

	if ((string.match(Program, "mapr3")) and Agt_type == nil) then
		logger("got incorrect params in set type")
	end

	command = "rm /etc/map/wts_bsta_mlo_config"
	execute(command)
	command = "rm /etc/map/mlo_link_config"
	execute(command)
	command = "rm /tmp/mlo_max_links"
	execute(command)


	command = "cat /etc/map/mapd_default.cfg | grep Cert_RDKB | cut -c 11"
	CERT_RDKB = os.capture(command)
	if (string.match(CERT_RDKB, "1") ) then
		hostapd_interface_Up()
		sleep (45)
	elseif (IS_LOGAN == 1 and IS_EAGLE ==1) then
		command = "dmesg -n8"
		execute(command)
		sleep(2)
		command = "cat /etc/map/mapd_default.cfg | grep Cert_6G | cut -c 9"
		CERT_6G = os.capture(command)
		if (string.match(CERT_6G, "1") ) then
			command = "cp /etc/wireless_cert_be /etc/config/wireless"
		else
			command = "cp /etc/wireless_cert /etc/config/wireless"
		end
		execute(command)
		sleep(2)

		command	= "wifi save"
		execute(command)
		sleep(2)
		command = "wifi restart"
		execute(command)
		sleep (30)
	else
		execute("wappctrl "..ra_interface.." map reset_default")
		sleep (12)
	end

	-- set default MAP version as R2
	command = "datconf -f /etc/map/1905d.cfg set map_ver R2"
	execute(command)
	if ((string.upper(Program) == "MAPR1") or (string.upper(Program) == "MAP")) then
		logger("setting map version as R1")
		command = "datconf -f /etc/map/1905d.cfg set map_ver R1"
		execute(command)
		if (IS_LOGAN == 1) then
 			execute("mwctl "..ra_interface.." set mapR2Enable=0")
 			execute("mwctl rai0 set mapR2Enable=0")
			execute("mwctl rax0 set mapR2Enable=0")
			execute("mwctl wlan0 set mapR2Enable=0")
			execute("mwctl "..ra_interface.." set mapTSEnable=0")
			execute("mwctl rai0 set mapTSEnable=0")
			execute("mwctl rax0 set mapTSEnable=0")
			execute("mwctl wlan0 set mapTSEnable=0")
		else
			execute("iwpriv "..ra_interface.." set mapR2Enable=0")
			execute("iwpriv rai0 set mapR2Enable=0")
			execute("iwpriv rax0 set mapR2Enable=0")
			execute("iwpriv wlan0 set mapR2Enable=0")
			execute("iwpriv "..ra_interface.." set mapTSEnable=0")
			execute("iwpriv rai0 set mapTSEnable=0")
			execute("iwpriv rax0 set mapTSEnable=0")
			execute("iwpriv wlan0 set mapTSEnable=0")
		end
	elseif (string.upper(Program) == "MAPR2") then
		logger("setting map version as R2")
		command = "datconf -f /etc/map/1905d.cfg set map_ver R2"
		execute(command)
		if (IS_LOGAN == 1) then
			execute("mwctl "..ra_interface.." set mapR2Enable=1")
			execute("mwctl rai0 set mapR2Enable=1")
			execute("mwctl rax0 set mapR2Enable=1")
			execute("mwctl wlan0 set mapR2Enable=1")
			execute("mwctl "..ra_interface.." set mapTSEnable=1")

			execute("mwctl rai0 set mapTSEnable=1")
  			execute("mwctl rax0 set mapTSEnable=1")
			execute("mwctl wlan0 set mapTSEnable=1")
		else
			execute("iwpriv "..ra_interface.." set mapR2Enable=1")
			execute("iwpriv rai0 set mapR2Enable=1")
			execute("iwpriv rax0 set mapR2Enable=1")
			execute("iwpriv wlan0 set mapR2Enable=1")
			execute("iwpriv "..ra_interface.." set mapTSEnable=1")

			execute("iwpriv rai0 set mapTSEnable=1")
			execute("iwpriv rax0 set mapTSEnable=1")
			execute("iwpriv wlan0 set mapTSEnable=1")
		end
	else
		logger("setting map version as R3")
		command = "datconf -f /etc/map/1905d.cfg set map_ver R3"
		execute(command)
		if (IS_LOGAN == 1) then
			execute("mwctl "..ra_interface.." set mapR2Enable=1")
 			execute("mwctl rai0 set mapR2Enable=1")
			execute("mwctl rax0 set mapR2Enable=1")
			execute("mwctl wlan0 set mapR2Enable=1")
			execute("mwctl "..ra_interface.." set mapR3Enable=1")
			execute("mwctl rai0 set mapR3Enable=1")
			execute("mwctl rax0 set mapR3Enable=1")
			execute("mwctl wlan0 set mapR3Enable=1")
			execute("mwctl "..ra_interface.." set mapTSEnable=1")
			execute("mwctl rai0 set mapTSEnable=1")
			execute("mwctl rax0 set mapTSEnable=1")
			execute("mwctl wlan0 set mapTSEnable=1")
		else
			execute("iwpriv "..ra_interface.." set mapR2Enable=1")
			execute("iwpriv rai0 set mapR2Enable=1")
			execute("iwpriv rax0 set mapR2Enable=1")
			execute("iwpriv wlan0 set mapR2Enable=1")
			execute("iwpriv "..ra_interface.." set mapR3Enable=1")
			execute("iwpriv rai0 set mapR3Enable=1")
			execute("iwpriv rax0 set mapR3Enable=1")
			execute("iwpriv wlan0 set mapR3Enable=1")
			execute("iwpriv "..ra_interface.." set mapTSEnable=1")
			execute("iwpriv rai0 set mapTSEnable=1")
			execute("iwpriv rax0 set mapTSEnable=1")
			execute("iwpriv wlan0 set mapTSEnable=1")
		end
	end
	logger("DevResetDefaultMediatek ".. Program.. "   "..MyDevRole..""..Agt_type)
	--kill 1905 first, kill after inf down up will cause CNTL mid handling issue (new msg with little mid will be dropped)
	execute ("killall -15 p1905_managerd")
	if (string.match(Program, "map") ) then
		WappEnable = 1
	else
		logger("Program is "..Program)
	end

	-- Bring down LAN(data)
	if (string.match(DevRole, "agent")) then
		if(UNAME_OS_VER == nil) then
			execute ("brctl delif br-lan "..LAN_INTERFACE.. "")
			execute ("sed -i /^lan=/c\\#lan= /etc/map/1905d.cfg")
		else
			logger ("Calling Bridge config with MAUT")
			BRConfigByBackhaul("wifi");
			execute ("sed -i /^lan=/c\\#lan= /etc/map/1905d.cfg")
		end
	else
		--add lan to bridge and 1905d.cfg as MCUT
		if(UNAME_OS_VER == nil) then
			execute ("brctl addif br-lan "..LAN_INTERFACE.. "")
			execute ("sed -i /^lan=/c\\lan="..LAN_INTERFACE.. " /etc/map/1905d.cfg")
			execute ("sed -i /^#lan=/c\\lan="..LAN_INTERFACE.. " /etc/map/1905d.cfg")
		else
			logger ("Calling with MCUT")
			AddLanIn1905d("eth")
			BRConfigOnCtrl()
		end
	end

	if (string.upper(Program) == "MAPR5") then
		execute("datconf -f /etc/map/1905d.cfg set mscs_capa 0")
		execute("datconf -f /etc/map/1905d.cfg set scs_capa 0")
		execute("datconf -f /etc/map/1905d.cfg set qosmap_capa 0")
		execute("datconf -f /etc/map/1905d.cfg set dscppolicy_capa 0")
		execute("wappctrl ra0 map dev_set_config qosmap_capa 0")
		execute("wappctrl ra0 map dev_set_config dscppolicy_capa 0")
	end

	kill_map_deamons = "killall -15 mapd; killall -15 p1905_managerd; killall -15 wapp; rm -rf /tmp/wapp_ctrl"

	-- kill MAP deamons
	execute (kill_map_deamons)

	if (string.match(DevRole, "controller") ) then
		-- bringdown all interaces
		ApInterfaceDownUp(false)
		StaInterfaceDownUp(false)

		if (string.match(Program, "mapr3")) then

			logger("Filling dpp cfg for controller")
			execute("wificonf -f /etc/dpp_cfg.txt set dpp_private_key 307702010104206de64a0e34d32b617c1c94f1f3dcea123759f5889c59b7e52f809895745b7413a00a06082a8648ce3d030107a14403420004114b5f4b7ad21d0efd4bddfd45741fdd1a7e959671777a79107b1484c102bd3beb57ec0b36fd98e2b4b902c5285df9c18d8418452c59ce68703ab9d77ea853ef")
			execute("wificonf -f /etc/dpp_cfg.txt set curve_name prime256v1")
			execute("wificonf -f /etc/dpp_cfg.txt set configurator_support 1")
			execute("wificonf -f /etc/dpp_cfg.txt set allowed_role 2")
			execute("wificonf -f /etc/dpp_cfg.txt set map_support 1")
			execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_2g "..ra_interface.."")
			execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_5gl rax0")
			execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_5gh rai0")
		end
		if (IS_LOGAN == 1 and IS_BELLWETHER ==1) then
                        command = "hostapd -B -t -d -f /root/hostapd.log /etc/hostapd_ra0_MTK_MAP.conf  /etc/hostapd_rai0_MTK_MAP.conf"
                        sleep (2)
			execute(command)
		end
		if (IS_LOGAN == 1 and IS_EAGLE == 1 ) then
			command = "EasyMesh_openwrt.sh"
			execute(command)
			sleep (10)
		end

		execute("wapp_openwrt.sh > /dev/null")
		sleep (5)

		if (IS_LOGAN == 1 and IS_EAGLE ==1) then
			command = "dmesg -n1"
			execute(command)
			sleep(2)
		end

		execute("wappctrl "..ra_interface.." map reset_default")
                if (IS_LOGAN == 1 and IS_EAGLE == 1 ) then
			execute("sleep 20")
		else
			sleep (12)
		end

		command = "p1905_managerd -r0 -f \"/etc/map/1905d.cfg\" -F \"/etc/map/wts_bss_info_config\" -M -d "..P1905_DEBUG_LEVEL.." > /dev/null &"
		execute(command)
		sleep(5)
		command = "mapd -M > /dev/null &"
		execute(command)
		if (IS_LOGAN == 1 and IS_EAGLE ==1) then
			sleep(25)
		end
		logger ("Stand Alone Controller")
	else
		-- bringup all interaces
		ApInterfaceDownUp(true)
		StaInterfaceReset()
		StaInterfaceDownUp(true)

		if (string.match(Program, "mapr3")) then
			if (string.match(Agt_type, "testbed")) then
				logger("Filling dpp cfg for Agent")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_private_key 307702010104200d78963fc9a6edf3d80f55889a77213ec368341e6904f0f60279064829a96967a00a06082a8648ce3d030107a144034200047b379c3f2543220c714711a9354ef1f5c1c50708d515e7ebca2025062e88c7e108817679eb082a00bda841db7757af8f8b8f3535c0a45475ead38b0623fdc097")
				execute("wificonf -f /etc/dpp_cfg.txt set curve_name prime256v1")
				execute("wificonf -f /etc/dpp_cfg.txt set configurator_support 0")
				execute("wificonf -f /etc/dpp_cfg.txt set allowed_role 1")
				execute("wificonf -f /etc/dpp_cfg.txt set map_support 1")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_2g "..ra_interface.."")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_5gl rax0")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_5gh rai0")
			end
			if (string.match(Agt_type, "DUT")) then
				logger("Filling dpp cfg for DUT")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_private_key 30770201010420450b7151e660bd695ee84597be3af83e2808563cb979a13e0adbb9c592a5b2dda00a06082a8648ce3d030107a1440342000452d5cfd47ec745ff20e2faf79f2dfd2ceb2dde688a8d4647fde65972dedf0aaee8da5d353a0b2d8bc98c757f318398bf7be1a4e706c6eb8d67ea053ffe3613b8")
				execute("wificonf -f /etc/dpp_cfg.txt set curve_name prime256v1")
				execute("wificonf -f /etc/dpp_cfg.txt set configurator_support 0")
				execute("wificonf -f /etc/dpp_cfg.txt set allowed_role 1")
				execute("wificonf -f /etc/dpp_cfg.txt set map_support 1")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_2g "..ra_interface.."")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_5gl rax0")
				execute("wificonf -f /etc/dpp_cfg.txt set dpp_interface_5gh rai0")
			end
			execute("wificonf -f /etc/map/mapd_user.cfg set DeviceRole 2")
			execute("wificonf -f /etc/map/mapd_cfg set DeviceRole 2")
		end

		if (IS_LOGAN == 1) then
			execute("mwctl "..ra_interface.." set DppEnable=1")
			execute("mwctl rax0 set DppEnable=1")
			execute("mwctl rai0 set DppEnable=1")
		else
			execute("iwpriv "..ra_interface.." set DppEnable=1")
			execute("iwpriv rax0 set DppEnable=1")
			execute("iwpriv rai0 set DppEnable=1")
		end
		if (IS_LOGAN == 1 and IS_BELLWETHER == 1 ) then
                        command = "hostapd -B -t -d -f /root/hostapd.log /etc/hostapd_ra0_MTK_MAP.conf  /etc/hostapd_rai0_MTK_MAP.conf"
                        sleep (2)
                        execute(command)
                        command = "wpa_supplicant -bbr-lan -Dnl80211 -iapcli0 -c/etc/wpa_supplicant_apcli0_MTK_MAP.conf -N -bbr-lan -Dnl80211 -iapclii0 -c/etc/wpa_supplicant_apclii0_MTK_MAP.conf -t -f /root/wpa_log.log -iB"
                        sleep (2)
			execute(command)
		end
		if (IS_LOGAN == 1 and IS_EAGLE == 1 ) then
			command = "EasyMesh_openwrt.sh"
			execute(command)
			sleep (10)
		end
		execute("wapp_openwrt.sh > /dev/null")
		sleep (5)

                if (IS_LOGAN == 1 and IS_EAGLE == 1 ) then
			command = "dmesg -n1"
			execute(command)
			sleep(2)
		end

		execute("wappctrl "..ra_interface.." map reset_default")
                if (IS_LOGAN == 1 and IS_EAGLE == 1 ) then
			execute("sleep 20")
		else
			execute("sleep 12")
		end

		logger ("Stand Alone Agent")
	end

	return "Success"
end

function StartWpsRegistrationMediatek(Mode, Band)
	command = "wappctrl "..ra_interface.." map trigger_wps "..Mode.. " "..Band.." "
	execute(command)

	return "successful"
end

function GetInfoMediatek(Value, Device, Comment)
	local version, model, vendor, iRet, model2
	--command = "iwpriv "..ra_interface.." stat |grep driver_version | cut -c 17-999"

	-- let's take image built time as version instead from now on
	--
	command = "uname -a | awk '{print $9$10}' | awk -F: '{print $1$2$3}'"
	version = os.capture(command)
	logger ("Cmd Result ".. version)
	command = "datconf -f /etc/wireless/l1profile.dat get INDEX0"
	model = os.capture(command)
	if (string.match (model,"MT7622")) then
		command = "datconf -f /etc/wireless/l1profile.dat get INDEX1"
		model2 = os.capture(command)
	end
	if (string.match (model,"MT7902")) then
                command = "datconf -f /etc/wireless/l1profile.dat get INDEX1"
                model2 = os.capture(command)
        end
        vendor = "MediaTek"
        if (string.match (model,"MT7622")) then
                if (string.match (model2,"MT7915")) then
                        iRet = "vendor,"..vendor..",model,"..model2..",version,"..version
                else
                        iRet = "vendor,"..vendor..",model,"..model..",version,"..version
                end
        elseif (string.match (model,"MT7902")) then
                if (string.match (model2,"MT7902")) then
                        iRet = "vendor,"..vendor..",model,"..model2..",version,"..version
                else
                        iRet = "vendor,"..vendor..",model,"..model..",version,"..version
                end
        else
                model = "FiLogic880"
                iRet = "vendor,"..vendor..",model,"..model..",version,"..version
        end
        return iRet
end

function GetMacAddrBySSIDMediatek (SSID, RUID)
	logger ("GetMacAddrBySSIDMediatek: "..SSID.."  " ..RUID)

	extracted_RUID = string.gsub(RUID, "0x", "")

	logger("SSID-"..SSID.." extracted_RUID -"..extracted_RUID)

	command = "wappctrl "..ra_interface.." map get_macaddr "..SSID.." " ..extracted_RUID..";"
	execute(command)

	command = "cat /tmp/map_macaddr.txt |grep HWAddr | awk '{print $2}'"
	iRet = os.capture(command)
	logger ("return: -"..iRet)
	return iRet
end

function GetMldAddrBySSIDMediatek (SSID, RUID)
	if (RUID == nil) then
		logger ("GetMldAddrBySSIDMediatek: "..SSID)
		logger("SSID-"..SSID)
		command = "wappctrl "..ra_interface.." map get_mldaddr "..SSID..";"
		execute(command)
		command = "cat /tmp/map_mld_addr.txt |grep MLD_Addr | awk '{print $2}'"
	else
        	logger ("GetBstaAffiliatedMacAddrBySSIDRuidMediatek: "..SSID.."  " ..RUID)
		extracted_RUID = string.gsub(RUID, "0x", "")
		logger("SSID-"..SSID.." extracted_RUID -"..extracted_RUID)
		command = "wappctrl "..ra_interface.." map get_bsta_affiliated_mac_addr "..SSID.." " ..extracted_RUID..";"
		execute(command)
		command = "cat /tmp/map_bsta_affilaited_macaddr.txt |grep BSTA_AFFILIATED_MAC_ADDR | awk '{print $2}'"
	end
	iRet = os.capture(command)
        logger ("return: -"..iRet)
        return iRet
end

function DevStartBuffMediatek(MsgType)
	logger("My dev role "..MyDevRole)
	logger(" DevStartBuffMediatek msg type : "..MsgType)

	command = "1905ctrl "..MyDevRole.." dev_start_buffer "..MsgType..";"
	execute(command)
	return "successful"
end


function DevStopBuffMediatek()
	logger("My dev role "..MyDevRole)
	logger(" DevStopBuffMediatek ")

	command = "1905ctrl "..MyDevRole.." dev_stop_buffer;"
	execute(command)
	return "successful"
end

function DevGetFrameInfoMediatek(mtype,tlv,mid,filter,return_content)
	local return_str = "MessageTypePresent"
	logger("My dev role "..MyDevRole)
	logger(" DevGetFrameInfoMediatek ")

	command = "1905ctrl "..MyDevRole.." dev_get_frame_info "..mtype.." "..tlv.." "..mid.." "..filter.." "..return_content..";"
	execute(command)

	sleep (5)

	-- MessageType set by 1905, if no pkt hit, do not add the string
	-- grep if MessageType is preset or not
	command = "cat /tmp/map_frameinfo.txt |grep MessageType | awk '{print $2}'"
	iRet = os.capture(command)

	-- MessageTypePresent,Yes or MessageTypePresent,No
	if (iRet ~= nil) then
		return_str = return_str..",Yes"
		logger(" MessageType "..iRet.." found")
	else
		return_str = return_str..",No"
		logger(" MessageType "..mtype.." not found")
	end



	-- TLVList
	if (string.match (return_content, "tlv")) then
		logger(" check if TLVList existed ")
		command = "cat /tmp/map_frameinfo.txt |grep TLVList | awk '{print $2}'"
		iRet = os.capture(command)
		return_str = return_str..",TLVList,"..iRet

	-- MessageDump
	elseif (string.match (return_content, "messagehexdump")) then
		logger(" check if MessageDump existed ")
		command = "cat /tmp/map_frameinfo.txt |grep MessageDump | awk '{print $2}'"
		iRet = os.capture(command)
		return_str = return_str..",MessageDump,"..iRet

	-- TLVFieldValue,00(other filter check should be before TLVFieldValue check)
	else
		logger(" check if TLVFieldValue existed ")
		command = "cat /tmp/map_frameinfo.txt |grep TLVFieldValue | awk '{print $2}'"
		iRet = os.capture(command)
		return_str = return_str..",TLVFieldValue,"..iRet

	end

	return return_str
end

function DevGetMapParameterMediatek(StaMac, Param)

	local str, result
	local apcli0_ssid, apclii0_ssid, apclix0_ssid, sta_itf, upper_mac
	local apcli0_mac, apclii0_mac, apclix0_mac
	local bssid, pmk

	Param = string.gsub(Param, ",", "")

	logger ("DevGetMapParameterMediatek: "..StaMac..""..Param)
	upper_mac = string.upper(StaMac)
	logger ("upper stamac: "..upper_mac)

	-- check apcli0 by sta mac
	command = "ifconfig apcli0 | grep "..upper_mac
	apcli0_mac = os.capture(command)
	-- check apclii0 by sta mac
	command = "ifconfig apclii0 | grep "..upper_mac
	apclii0_mac = os.capture(command)
	-- check apclix0 by sta mac
	command = "ifconfig apclix0 | grep "..upper_mac
	apclix0_mac = os.capture(command)

	-- check if stamac match any apcli interface
	if ((apcli0_mac ~= nil and apcli0_mac ~= "") or
		(apclii0_mac ~= nil and apclii0_mac ~= "") or
		(apclix0_mac ~= nil and apclix0_mac ~= "")) then
		logger ("GET PMK FOR BSTA SIDE")

		command = "iwconfig apcli0 | grep ESSID | awk -F 'ESSID:' '{print $2}'"
		logger ("cmd: "..command)
		apcli0_ssid = os.capture(command)
		logger ("apcli0 ssid: "..apcli0_ssid)

		command = "iwconfig apclii0 | grep ESSID | awk -F 'ESSID:' '{print $2}'"
		logger ("cmd: "..command)
		apclii0_ssid = os.capture(command)
		logger ("apclii0 ssid: "..apclii0_ssid)

		command = "iwconfig apclix0 | grep ESSID | awk -F 'ESSID:' '{print $2}'"
		logger ("cmd: "..command)
		apclix0_ssid = os.capture(command)
		logger ("apclix0 ssid: "..apclix0_ssid)

		if (apcli0_ssid ~= nil and apcli0_ssid ~= "" and apcli0_ssid ~= "\"\"") then
			sta_itf = "apcli0"
			logger ("sta interface: "..sta_itf)
		elseif (apclii0_ssid ~= nil and apclii0_ssid ~= "" and apclii0_ssid ~= "\"\"") then
			sta_itf = "apclii0"
			logger ("sta interface: "..sta_itf)
		elseif (apclix0_ssid ~= nil and apclix0_ssid ~= "" and apclix0_ssid ~= "\"\"") then
			sta_itf = "apclix0"
			logger ("sta interface: "..sta_itf)
		end

		if (sta_itf ~= nil and sta_itf ~= "") then
			-- get pmk for the bssid
			command = "wpa_cli -i "..sta_itf.." raw PMKSA_GET 0 | awk -F ' ' '{print $3}'"
			-- command = "wpa_cli -i "..sta_itf.." raw PMKSA_GET 0 | grep "..bssid.." | awk '{print $3}'"
			logger ("cmd: "..command)
			pmk = os.capture(command)
			if (pmk == nil or pmk == "FAIL") then
				logger ("not found pmk")
				return ""
			end
			logger ("PMK :" ..pmk)

			-- find the pmk belong to the bssid
			logger ("DevGetParameter - " ..Param .." value - "..pmk)
			result = "PMK,"..pmk
			return result
		end
		result = "PMK,"
		return result
	else
		logger ("GET PMK FOR AP SIDE")
		-- get pmk on ap side start
		str = StaMac..""..Param
		str = string.gsub(str, " ", "_")
		logger ("str: "..str)

		command = "cat /etc/dpp_cfg_test.txt | grep "..str.." | awk '{print $2}' | tr '\n' '_' | sed '$s/_$//'"
		logger ("cmd: "..command)
		iRet = os.capture(command)
		iRet = Param..","..iRet
		logger ("return: -"..iRet)
		return iRet
		-- get pmk on ap side end
	end

end

function DevSetParameterMediatek(trigger,StaMac,Action)

	local set_param
	logger ("DevSetParameterMediatek: "..trigger)
	
	if string.match (trigger, "deauthentication") then
		set_param = StaMac
	elseif string.match (trigger, "dpppresenceannouncementblock") then
		set_param = Action
	end

	logger ("parameter: "..set_param)
	command = "wappctrl "..ra_interface.." map dev_set_trigger "..trigger.." "..set_param
	logger ("cmd: "..command)
	iRet = os.capture(command)
	logger ("return: -"..iRet)
	return iRet
end

function DevGetParameterMediatek(Value, Ruid, MatchSSID)

	local Param = Value
	local wapp_param

	logger ("DevGetParameter - "..Param)
	if string.match (Param, "FronthaulRadio_Supt") then
		wapp_param = "fh_radio_supt"
	elseif string.match (Param, "BackhaulSTA_Supt") then
		wapp_param = "bh_sta_radio"
	elseif string.match (Param, "FronthaulRadio_24G_BSSID") then
		wapp_param = "fh_24g_bssid"
	elseif string.match (Param, "FronthaulRadio_5G1_BSSID") then
		wapp_param = "fh_5g1_bssid"
	elseif string.match (Param, "FronthaulRadio_5G2_BSSID") then
		wapp_param = "fh_5g2_bssid"
	elseif string.match (Param, "HTCap_24G_Supt") then
		wapp_param = "ht_24g_supt"
	elseif string.match (Param, "HECap_24G_Supt") then
		wapp_param = "he_24g_supt"
	elseif string.match (Param, "HTCap_5G1_Supt") then
		wapp_param = "ht_5g1_supt"
	elseif string.match (Param, "HTCap_5G2_Supt") then
		wapp_param = "ht_5g2_supt"
	elseif string.match (Param, "VHTCap_5G1_Supt") then
		wapp_param = "vht_5g1_supt"
	elseif string.match (Param, "VHTCap_5G2_Supt") then
		wapp_param = "vht_5g2_supt"
	elseif string.match (Param, "HECap_5G1_Supt") then
		wapp_param = "he_5g1_supt"
	elseif string.match (Param, "HECap_5G2_Supt") then
		wapp_param = "he_5g2_supt"
	elseif string.match (Param, "backhaultype") then
		wapp_param = "bh_type"
	elseif (string.match ("CtrlAlid", Param)) then
		wapp_param = "ctrl_alid"
	elseif (string.match ("AgntAlid", Param)) then
		wapp_param = "agnt_alid"
	elseif (string.match (Param, "ALid")) then
		if string.match (MyDevRole, "controller") then
			wapp_param = "ctrl_alid"
		elseif string.match (MyDevRole, "agent") then
			wapp_param = "agnt_alid"
		else
			wapp_param = "agnt_alid"
		end
	elseif ((string.match (Param, "macaddr")) or (string.match (Param, "bssid"))) then
		MacAddr = GetMacAddrBySSIDMediatek(MatchSSID, Ruid)
		logger ("!!!!!!!!!!!!!!!!!!!!!!mac -"..MacAddr)
		return "macaddr,"..MacAddr
	elseif ((string.match (Param, "MLDAddr"))) then
                mldaddr = GetMldAddrBySSIDMediatek(MatchSSID, Ruid)
                logger ("!!!!!!!!!!!!!!!!!!!!!!MLD addr -"..mldaddr)
                return "MLDAddr,"..mldaddr
	end

	command = "wappctrl "..ra_interface.." map show_param; cat /tmp/map_cfg.txt | grep "..wapp_param.." | awk '{print $2}'"
	iRet = os.capture(command)

	if (string.match (Param, "ALid")) then
		logger ("DevGetParameter - " ..Param .." value - "..iRet)
		return "ID,"..iRet
	end

	return iRet
end

function DevSetBackhaulMediatek (Program, Backhaul)
	logger ("DevSetBackhaulMediatek -"..Program.." backhaul:"..Backhaul)

	command = "mbo_nr.sh 3"
	execute(command)
	sleep (2)
	if (string.match(Backhaul, "eth")) then
		if(UNAME_OS_VER == nil) then
			execute ("brctl addif br-lan "..LAN_INTERFACE.. "")
			execute ("sed -i /^lan=/c\\lan="..LAN_INTERFACE.. " /etc/map/1905d.cfg")
			execute ("sed -i /^#lan=/c\\lan="..LAN_INTERFACE.. " /etc/map/1905d.cfg")
			sleep(1)
		else
			BRConfigByBackhaul(Backhaul)
			AddLanIn1905d(Backhaul)
			sleep(1)
		end

		command = "p1905_managerd -r1 -f \"/etc/map/1905d.cfg\" -F \"/etc/map/wts_bss_info_config\" -M -d "..P1905_DEBUG_LEVEL.." > /dev/null &"
		execute(command)
		sleep (10)
		if (string.find(dev_start_buffer_mtype, "0x") ~= nil) then
			DevStartBuffMediatek(dev_start_buffer_mtype)
			dev_start_buffer_mtype = ""
		end
		sleep(1)
		command = "mapd -M > /dev/null &"
		execute(command)
		sleep (10)
		command = "wappctrl "..ra_interface.." map set_bh_type "..Backhaul
		execute(command)
		sleep (50)
	else
		execute ("sed -i /^lan=/c\\#lan= /etc/map/1905d.cfg")
		sleep(1)
		extracted_RUID = string.gsub(Backhaul, "0x", "")
		logger ("extracted_RUID "..extracted_RUID)
		command = "p1905_managerd -r1 -f \"/etc/map/1905d.cfg\" -F \"/etc/map/wts_bss_info_config\" -M -d "..P1905_DEBUG_LEVEL.." > /dev/null &"
		execute(command)

		sleep (10)
		if (string.find(dev_start_buffer_mtype, "0x") ~= nil) then
			DevStartBuffMediatek(dev_start_buffer_mtype)
			dev_start_buffer_mtype = ""
		end
		sleep(1)
		command = "mapd -M > /dev/null &"
		execute(command)
		sleep (10)
		command = "wappctrl "..ra_interface.." dpp dpp_onboard_type type=1"
		execute(command)
		sleep (5)
		command = "wappctrl "..ra_interface.." map set_bh_type wifi "..extracted_RUID
		execute(command)
	end

	return "success"
end

function DevSend1905Mediatek(cmd)
	local role = 0
	local len = 100

	if (string.match(MyDevRole, "agent")) then
		role = 1
	end

	local tlv_found
	local i = 1, tlv_value, data
	local alid, msg_type, start_pos, tlv_type, tlv_length, next_pos, tlv

	cmd = string.gsub(cmd, "dev_send_1905,", "")

	start_pos = string.find (cmd, "DestALid,")
	if (start_pos ~= nil) then
		alid = string.sub(cmd, start_pos + 9, start_pos + 9 + 16)
	end

	start_pos = string.find (cmd, "MessageTypeValue,")
	if (start_pos ~= nil) then
		msg_type = string.sub(cmd, start_pos + 17, start_pos + 17 + 5)
	end

	data = alid .. " " .. msg_type

	command = "rm -rf "..SEND_1905_FRAME_CONF.."; echo "..data.." > "..SEND_1905_FRAME_CONF..";"
	execute(command)

	-- validate which kind of msg it is(tlv1/tlv)
	start_pos = string.find(cmd, "tlv_type1")
	tlv_found = string.find(cmd, "tlv_type")
	if (start_pos == nil and tlv_found ~= nil) then
		tlv_type = string.sub(cmd, (string.find(cmd, "tlv_type") + 9),
					(string.find(cmd, "tlv_type") + 12))
		tlv_length = string.sub(cmd, (string.find(cmd, "tlv_length") + 11),
					(string.find(cmd, "tlv_length") + 16))

		tlv_value = string.sub(cmd, (string.find(cmd, "tlv_value") + 10))

		--[[ Case: Macaddress string as raw data.
		     Ideally this should have come as raw data
		     but if coming as string, convert it to raw data.
		  ]]
		if (string.match(tlv_value, "(%w+:%w+:%w+:%w+:%w+:%w+)")) then
			-- append 0x for first octact.
			tlv_value = "0x"..tlv_value
		end
		tlv_value = string.gsub(tlv_value, ":", " 0x")

		tlv_value = string.gsub(tlv_value, "{", "")
		tlv_value = string.gsub(tlv_value, "}", "")
		tlv_value = string.gsub(tlv_value, " ", "_")

		tlv = tlv_type.. " "..tlv_length.." "..tlv_value

		command = "echo "..tlv.." >> "..SEND_1905_FRAME_CONF..";"

		execute(command)
	else
		for i = 1,6 do
			start_pos = string.find(cmd, "tlv_type"..i)
			if (start_pos == nil) then break end

			tlv_type = string.sub(cmd, (string.find(cmd, "tlv_type"..i) + 10),
							(string.find(cmd, "tlv_type"..i) + 13))
			tlv_length = string.sub(cmd, (string.find(cmd, "tlv_length"..i) + 12),
							(string.find(cmd, "tlv_length"..i) + 17))

			next_pos = string.find(cmd, "tlv_type"..i+1)

			if (next_pos) then next_pos = next_pos - 2 end

			tlv_value = string.sub(cmd, (string.find(cmd, "tlv_value"..i) + 11), next_pos)
			if (string.match(tlv_value, "(%w+:%w+:%w+:%w+:%w+:%w+)")) then
				-- append 0x for first octact.
				tlv_value = "0x"..tlv_value
			end
			tlv_value = string.gsub(tlv_value, "{", "")
			tlv_value = string.gsub(tlv_value, "}", "")
			tlv_value = string.gsub(tlv_value, " ", "_")
			tlv_value = string.gsub(tlv_value, ":", "")
			
			tlv = tlv_type.. " "..tlv_length.." "..tlv_value

			command = "echo "..tlv.." >> "..SEND_1905_FRAME_CONF..";"
			execute(command)
		end
	end

	if role > 0 then
		command = "1905ctrl agent dev_send_1905 "..SEND_1905_FRAME_CONF
	else
		command = "1905ctrl controller dev_send_1905 "..SEND_1905_FRAME_CONF
	end
	execute(command)

	sleep (1)

	command = "cat /tmp/msg_id.txt | awk '{print $2}'"
	iRet = os.capture(command)

	return iRet

end

function GetInterfaceFromBssid(bssid)
	local interface

	command = "iwconfig | grep -i "..bssid.." -B 2 > /tmp/map_cfg.txt"
	execute(command)
	command = "cat /tmp/map_cfg.txt | grep -vi -e "..bssid.." -e wds -e -- -e '         ' > /tmp/1.txt"
	execute(command)
	command = "cat /tmp/1.txt  |  awk '{print $1}'"
	interface = os.capture(command, nil)

	if (interface ~= nil) then
		logger("interface is " ..interface)
	else
		logger("interface not found")
	end
	return interface
end

function setAssoc_Disallow (bssid, Value)
	local interface
	logger("setAssoc_Disallow: Value="..Value)

	if string.match(Value, "Enable") then
		Disallow_Reason = "1"
	elseif string.match(Value, "Disable") then
		Disallow_Reason = "0"
	else
		logger("invalid reason")
		Disallow_Reason = "0"
	end

	interface = GetInterfaceFromBssid(bssid)

	if (interface == nil) then
		return "-1"
	end

	if (MBOWappCommands and MBOWappCommands["Assoc_Disallow"]) then
		command = "wappctrl "..interface.." "..MBOWappCommands["Assoc_Disallow"].." "..Disallow_Reason
		execute (command)
	end

	return "Success"
end

-- Just a basic function for all map handling, should be verified each function and add handling
-- if needed.
function execute_wapp_command(parameter, bssid, Value)

	local interface

	if string.match(Value, "Enable") then
		Value = "1"
	elseif string.match(Value, "Disable") then
		Value = "0"
	end

	interface = GetInterfaceFromBssid(bssid)
	if (MBOWappCommands[parameter]) then
		command = "wappctrl "..interface.." "..MBOWappCommands[parameter].." "..Value
		execute (command)
		return "Success"
	else
		logger("command not found")
		return "failed"
	end

end

function DevSetbStaCfgMediatek (cmd)
	local i = 1
	local trim_len = 11
	bsta_info = null
	logger("DevSetbStaCfgMediatek")
	command = "rm -rf " ..WTS_BSTA_CONF_FILE.. "; echo \"#ucc_bsta_info\" > "..WTS_BSTA_CONF_FILE.." "
	execute(command)

	for i = 1,9 do
		start_pos = string.find (cmd, "bsta_info"..i..",")
		end_pos = string.find(cmd, "bsta_info".. (i+1)..",")

		if (start_pos == nil) then break end

		if (end_pos) then
			bsta_info = string.sub(cmd, start_pos + trim_len, end_pos - 2)
		else
			bsta_info = string.sub(cmd, start_pos + trim_len)
		end

		bsta_info = string.gsub(bsta_info, ",", " ")

		command = "echo "..i ..",".. bsta_info .. "  >> "..WTS_BSTA_CONF_FILE..";"
		execute(command)
		sleep (1)
	end
end

function DevReconfigMediatek (cmd)
	logger("DevReconfigMediatek")

	command = "rm -rf " ..WTS_MLO_LINK_CONF_FILE
	execute(command)

	cmd = string.gsub(cmd, "dev_reconfig_1905,", "")
	cmd = string.gsub(cmd, ",", " ")

	command = "echo ".. cmd .. " > "..WTS_MLO_LINK_CONF_FILE
	execute(command)
	sleep (1)

	if (string.find (cmd, "bSTALinkAddition") or string.find (cmd, "bSTALinkRemoval")) then
		command = "1905ctrl controller bsta_mlo_link_chg"
		execute(command)

	elseif (string.find (cmd, "APAddition") or string.find (cmd, "APRemoval")) then
		command = "1905ctrl controller ap_mlo_link_chg"
		execute(command)
	end

	return "success"
end

function DevSetConfigMediatek (cmd)

	--inform 1905 by wapp_ctrl
	command = "rm -rf " ..WTS_CONF_FILE.. "; echo \"#ucc_bss_info\" > "..WTS_CONF_FILE.." "
	execute(command)


	--parsing bss_info into /etc_ro/wts_bss_info_config

	local i = 1
	local trim_len = 0
	cmd = string.gsub(cmd, "dev_set_config,", "")
	bss_info = null

	if (string.find (cmd, "bsta_info")) then
		DevSetbStaCfgMediatek(cmd)
	end

	for i = 1,16 do
		start_pos = string.find (cmd, "bss_info"..i..",")
		end_pos = string.find(cmd, "bss_info".. (i+1)..",")
		if (start_pos == nil) then break end
		if (i > 9) then
			trim_len = 11
		else
			trim_len = 10
		end
		if (end_pos) then
			bss_info = string.sub(cmd, start_pos + trim_len, end_pos - 2)
		else
			bss_info = string.sub(cmd, start_pos + trim_len)
		end
		bss_info = string.gsub(bss_info, "{", "")
		bss_info = string.gsub(bss_info, "}", "")
		bss_info = string.gsub(bss_info, ",", " ")
		bss_info = string.gsub(bss_info, "tlv_type1", "")
		bss_info = string.gsub(bss_info, "tlv_type2", "")
		bss_info = string.gsub(bss_info, "tlv_length1", "")
		bss_info = string.gsub(bss_info, "tlv_length2", "")
		bss_info = string.gsub(bss_info, "tlv_value1", "")
		bss_info = string.gsub(bss_info, "tlv_value2", "")
		logger(i..","..bss_info)
		command = "echo "..i ..",".. bss_info .. "  >> "..WTS_CONF_FILE..";"
		os.execute(command)
	end

	sleep (5)
	--inform wapp
	command = "wappctrl "..ra_interface.." dpp dpp_dev_set_cfg"
	execute(command)
	sleep (1)
	--inform 1905
	command = "mapd_cli /tmp/mapd_ctrl renew"
	execute(command)

	sleep (1)

	return "config_applied"
end

function bin2hex(s)
	s=string.gsub(s,"(.)",function (x) return string.format("%02X",string.byte(x)) end)
    return s.lower(s)
end

function hex2string(hex)
	local str, n = hex:gsub("(%x%x)[ ]?", function (word)
	return string.char(tonumber(word, 16))
	end)
	return str
end

-- This function should be extended for all the config agent functionality
-- Since UCC commands comes in string txt, scipts are better way to handle
-- these commands rather than C
function process_ucc_command(line)

	local Program, Type, Agt_type, iRet = ""
	local backhaulset = 0
	local capability_set = 0

	if (line == nil) then
		return
	end
	RESULT = "Status,Error"
	logger(line)

	if (string.match(line, "dev_reset_default,")) then
		line = string.gsub(line, "dev_reset_default,", "")
		for k, v in string.gmatch(line, "(%w+),(%w+)") do
			if (k == "name") then
				Name = v
			end
			if (k == "program") then
				Program = v
			end
			if (k == "devrole") then
				DevRole = v
			end
			if (k == "type") then
				Agt_type = v
			end
		end
		iRet = DevResetDefaultMediatek(Program, DevRole, Agt_type)
		RESULT = "status,COMPLETE,"..iRet
		return RESULT

	elseif (string.match(line, "ap_reset_default,")) then
		return "status,COMPLETE,0"
	elseif (string.match(line, "start_wps_registration,")) then
		line = string.gsub(line, "start_wps_registration,", "")
		for k, v in string.gmatch(line, "(%w+),(%w+)") do
			if (k == "ALid") then
				ALid = v
			end
			if (k == "WpsConfigMethod") then
				Mode = v
			end
			if (k == "band") then
				Band = v
			end
		end
		iRet = StartWpsRegistrationMediatek(Mode, Band)
		RESULT = "status,COMPLETE,wps started"
		return RESULT
	elseif (string.match(line, "device_get_info")) then
		iRet = GetInfoMediatek(NULL, "Mediatek", NULL)
		RESULT = "status,COMPLETE,"..iRet
		return RESULT
	elseif (string.match(line, "dev_get_parameter,")) then
		line = string.gsub(line, "dev_get_parameter,", "")
		local ruid, ssid, parameter, Name, StaMac
                if string.match(line, "ruid") then
                        start_pos = string.find(line, "ruid,")
                        end_pos = string.find(line, "," , start_pos + 5)
                        ruid = string.sub(line, start_pos + 5, end_pos - 1)
                end
                if string.match(line, "ssid") then
                        start_pos = string.find(line, "ssid,")
                        end_pos = string.find(line, "," , start_pos + 5)
                        ssid = string.sub(line, start_pos + 5, end_pos - 1)
                end

                if string.match(line, "parameter") then
                        start_pos = string.find(line, "parameter,")
                        end_pos = string.find(line, "," , start_pos + 10)
                        parameter = string.sub(line, start_pos + 10, end_pos)
                end
				
				if string.match(line, "Name") then
                        start_pos = string.find(line, "Name,")
                        end_pos = string.find(line, "," , start_pos + 5)
                        Name = string.sub(line, start_pos + 5, end_pos)
                end
				
				if string.match(line, "STA_MACAddress") then
                        start_pos = string.find(line, "STA_MACAddress,")
                        end_pos = string.find(line, "," , start_pos + 15)
                        StaMac = string.sub(line, start_pos + 15, end_pos)
                end

		if (ssid == nil) then
			ssid = "BHSTA"
		end
		
		if(StaMac == nil) then
			iRet = DevGetParameterMediatek(parameter, ruid, ssid)
		else
			iRet = DevGetMapParameterMediatek(StaMac, parameter)
		end
		
		RESULT = "status,COMPLETE,"..iRet
		return RESULT
	elseif (string.match(line, "dev_set_config,")) then
		line = string.gsub(line, "dev_set_config,", "")
		logger( "dev_set_config " ..line)
		--for k, v in string.gmatch(line, "(%w+),(%w+)") do
		for k, v in string.gmatch(line, "(%w+_%w+),(%w+)") do
			if (k == "program") then
				Program = v
			end
			if (k == "bss_info1") then
				iRet = DevSetConfigMediatek(line)
				RESULT = "status,COMPLETE,"..iRet
				return RESULT
			end
		end
		for k, v in string.gmatch(line, "(%w+_%w+_%w+),(%w+)") do
			if (k == "AP_Max_Links") then
				local ap_max_links
				ap_max_links = v
				logger("ap_max_links:"..ap_max_links)
				command = "echo "..ap_max_links.." > /tmp/mlo_max_links"
				execute(command)
				logger(command)
				RESULT = "status,COMPLETE,success"
				return RESULT
			end
		end
		for k, v in string.gmatch(line, "(%w+),(%w+)") do
			if (k == "program") then
				Program = v
			end
			if (k == "MSCS") then
				capability_set = 1
				if (v == "Enable") then
					execute("datconf -f /etc/map/1905d.cfg set mscs_capa 1")
				else
					execute("datconf -f /etc/map/1905d.cfg set mscs_capa 0")
				end
			elseif (k == "SCS") then
				capability_set = 1
				if (v == "Enable") then
					execute("datconf -f /etc/map/1905d.cfg set scs_capa 1")
				else
					execute("datconf -f /etc/map/1905d.cfg set scs_capa 0")
				end
			elseif (k == "QoSMAPCapability") then
				capability_set = 1
				if (v == "Enable") then
					execute("datconf -f /etc/map/1905d.cfg set qosmap_capa 1")
					execute("wappctrl ra0 map dev_set_config qosmap_capa 1")
				else
					execute("datconf -f /etc/map/1905d.cfg set qosmap_capa 0")
					execute("wappctrl ra0 map dev_set_config qosmap_capa 0")
				end
			elseif (k == "DSCPPolicyCapability") then
				capability_set = 1
				if (v == "Enable") then
					execute("datconf -f /etc/map/1905d.cfg set dscppolicy_capa 1")
					execute("wappctrl ra0 map dev_set_config dscppolicy_capa 1")
				else
					execute("datconf -f /etc/map/1905d.cfg set dscppolicy_capa 0")
					execute("wappctrl ra0 map dev_set_config dscppolicy_capa 0")
				end
			end
			if (capability_set > 0) then
				RESULT = "status,COMPLETE"
				return RESULT
			end
		end
		for k, v in string.gmatch(line, "(%w+),(%w+)") do
			if (k == "program") then
				Program = v
			end
			if (k == "backhaul") then
				backhaul = v
				iRet = DevSetBackhaulMediatek(Program, backhaul)
				backhaulset = 1
				--RESULT = "status,COMPLETE,"..iRet
				--return RESULT
			end
			if (k == "type") then
				type = v
				backhaulset = 2
				logger( "backhaulset =1")
				if (v == "dpp") then
					command = "wappctrl "..ra_interface.." dpp dpp_onboard_type type=0"
					execute(command)
					sleep (5)
				end
				if(string.match(backhaul, "eth") == nil) then
					if (v == "dpp") then
						execute("sleep 2s")
						--execute("wappctrl "..ra_interface.." dpp dpp_auth_init peer=2 own=1")
						execute ("wappctrl "..ra_interface.." dpp dpp_start")
					end
				end
			end
		end
		if (backhaulset > 0) then
			logger( "backhaulset = 1 return result")
			RESULT = "status,COMPLETE,"..iRet
			return RESULT
		end
	elseif (string.match(line, "dev_reconfig_1905")) then
		iRet = DevReconfigMediatek(line)
		RESULT = "status,COMPLETE,"..iRet
		return RESULT
	elseif (string.find(line, "dev_send_1905") == 1) then
		iRet = DevSend1905Mediatek(line)
		RESULT = "status,COMPLETE,MID,"..iRet
		return RESULT
	elseif (string.find(line, "ap_ca_version") == 1) then
		RESULT = "status,COMPLETE,Wi-Fi Test Suite-9.0.0"
		return RESULT
	elseif (string.find(line, "ca_get_version") == 1) then
		RESULT = "status,COMPLETE,Wi-Fi Test Suite-9.3.1"
		return RESULT
	elseif (string.find(line, "dev_set_rfeature") == 1) then
                local local_program, bssid, parameter, value
                if string.match(line, "type") then
                        start_pos = string.find(line, "type,")
                        end_pos = string.find(line, "," , start_pos + 5)
                        local_program = string.sub(line, start_pos + 5, end_pos - 1)
                end
                if string.match(line, "bssid") then
                        start_pos = string.find(line, "bssid,")
                        end_pos = string.find(line, "," , start_pos + 6)
                        bssid = string.sub(line, start_pos + 6, end_pos - 1)
                end

                start_pos = end_pos + 1
                end_pos = string.find(line, "," , start_pos)
                parameter = string.sub(line, start_pos, end_pos - 1)

                start_pos = end_pos + 1
                end_pos = string.find(line, "," , start_pos)
                if (end_pos == nil) then
                        end_pos = string.len(line)
                end
                value = string.sub(line, start_pos, end_pos)

                local fn = _G["set"..parameter]
		if (fn) then
	                iRet = fn(bssid, value)
		else
			logger("direct function handler not found, execute generic handler")
			iRet = execute_wapp_command(parameter, bssid, value)
		end
		RESULT = "status,COMPLETE,"..iRet
		return RESULT
	elseif (string.find(line, "dev_exec_action") == 1) then
		line = string.format("%s,", line)
		local program, actiontype, cryptid, dppbs, authrole, dppwaitforconn, provrole
		if string.match(line, "program,") then
			start_pos = string.find(line, "program,")
			end_pos = string.find(line, ",", start_pos + 8 )
			program = string.sub(line, start_pos + 8, end_pos - 1)
		end
		if string.match(line, "DPPActionType,") then
			start_pos = string.find(line, "DPPActionType,")
			end_pos = string.find(line, ",", start_pos + 14 )
			actiontype = string.sub(line, start_pos + 14, end_pos - 1)
		end
		if string.match(line, "DPPCryptoIdentifier,") then
			start_pos = string.find(line, "DPPCryptoIdentifier,")
			end_pos = string.find(line, ",", start_pos + 20 )
			cryptid = string.sub(line, start_pos + 20, end_pos - 1)
		end
		if string.match(line, "DPPBS,") then
			start_pos = string.find(line, "DPPBS,")
			end_pos = string.find(line, ",", start_pos + 6);
			dppbs = string.sub(line, start_pos + 6, end_pos - 1)
		end
		if string.match(line, "DPPAuthRole,") then
			start_pos = string.find(line, "DPPAuthRole,")
			end_pos = string.find(line, ",", start_pos + 12);
			authrole = string.sub(line, start_pos + 12, end_pos - 1)
		end
		if string.match(line, "DPPWaitForConnect,") then
			start_pos = string.find(line, "DPPWaitForConnect,")
			end_pos = string.find(line, ",", start_pos + 18);
			dppwaitforconn = string.sub(line, start_pos + 18, end_pos - 1)
		end
		if string.match(line, "DPPProvisioningRole,") then
			start_pos = string.find(line, "DPPProvisioningRole,")
			end_pos = string.find(line, ",", start_pos + 20)
			provrole = string.sub(line, start_pos + 20, end_pos - 1)
		end

		logger("program:"..program.." dppbs:"..dppbs.." actiontype:"..actiontype)
		if (program == "MAP") then
			if (actiontype == "GetLocalBootstrap") then
				if (dppbs == "URI_String ") then
					local command
					execute ("wappctrl "..ra_interface.." dpp dpp_bootstrap_get_uri 1")
					execute("sleep 1s")
					command = "cat /etc/dpp_cfg_test.txt | grep -i \"qrcode\""
					local temp
					temp = os.capture(command, nil)
					start_pos = string.find(temp, "qrcode=")
					end_pos = string.len(temp)
					local qrcode
					qrcode = string.sub(temp, start_pos + 7, end_pos)
					if (qrcode) then
						RESULT = "status,COMPLETE,BootstrappingData,"..bin2hex(qrcode)
						return RESULT
					end
				end
			elseif(actiontype == "AutomaticDPP") then
				--step1: init config file
				if (provrole == "Configurator") then
					--this is a configurator
					configrole = "CONF"
					RESULT = "status,COMPLETE,BootstrapResult,OK,AuthResult,OK,ConfResult,OK"
				elseif (provrole == "Enrollee") then
					if (dppwaitforconn ~= nil) then
						--this is an enrollee
						--configrole = "STA"
						RESULT = "status,COMPLETE,BootstrapResult,OK,AuthResult,OK,ConfResult,OK,NetworkIntroResult,OK,NetworkConnectResult,OK"
					else
						--this is an enrollee
						--configrole = "AP"
						RESULT = "status,COMPLETE,BootstrapResult,OK,AuthResult,OK,ConfResult,OK"
					end
				end

				if (g_key_index == 1) then
					write_config_file(configrole)
					execute("killall -9 wapp")
					execute("wapp")

					--reset the bootstrapping key as writing config file will re-launch wapp process
					if (temp_bskey ~= "") then
						execute("sleep 1s")
						execute("wappctrl "..ra_interface.." dpp dpp_qr_code \""..temp_bskey.."\"")
						temp_bskey = ""
					end
				end

				--step2: trigger dpp process at the initiator side
				g_key_index = g_key_index + 1
				if (authrole == "Initiator") then
					execute("sleep 2s")
					execute("wappctrl "..ra_interface.." dpp dpp_auth_init peer="..g_key_index.." own=1")

				end

				return RESULT
			elseif(actiontype == "SetPeerBootstrap") then
				local bskey
				start_pos = string.find(line, "DPPBootstrappingData,")
				end_pos = string.find(line, ",", start_pos + 21);
				bskey = string.sub(line, start_pos + 21, end_pos - 1)
				bskey = hex2string(bskey)
				logger("bskey:"..bskey)
				execute("wappctrl "..ra_interface.." dpp dpp_qr_code \""..bskey.."\"")
				execute("sleep 2s")
				--execute("wappctrl "..ra_interface.." dpp dpp_configurator_sign mode=map")
				--execute("sleep 5s")
				--execute("wappctrl "..ra_interface.." dpp dpp_auth_init peer=2 own=1")
				
				temp_bskey = bskey

				RESULT = "status,COMPLETE,channel,6"
				return RESULT
			end

		end
	elseif (string.find(line, "dev_send_frame") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_send_tsmrpt_req") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_deauth_sta") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_send_bcnrpt_req") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_send_tsmrpt_req") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_send_bsstrans_mgmt_req") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_send_link_mea_req") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_set_security") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_set") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "ap_get_mac_address") == 1) then
		logger("command not supported, got :"..line)
	elseif (string.find(line, "close_config_agent") == 1) then
		EXIT = 1
	elseif (string.find(line, "dev_start_buffer") == 1) then
		start_pos = string.find(line, "MessageTypes,")
		end_pos = string.len(line)
		-- msgtype should like 0x8003_0x8004
		dev_start_buffer_mtype = string.sub(line, start_pos + 13, end_pos)
		logger("dev_start_buffer msg type :"..dev_start_buffer_mtype)
		iRet = DevStartBuffMediatek(dev_start_buffer_mtype)
		RESULT = "status,COMPLETE"
		return RESULT
	elseif (string.find(line, "dev_stop_buffer") == 1) then
		logger("dev_stop_buffer")
		iRet = DevStopBuffMediatek()
		RESULT = "status,COMPLETE"
		return RESULT
	elseif (string.find(line, "dev_get_frame_info") == 1) then
		local mtype,tlv,mid,filter,return_content
		tlv = "0x00"
		mid = "0x0000"
		logger("dev_get_frame_info")
		if string.match(line, "message") then
			start_pos = string.find(line, "message,")
			end_pos = string.find(line, "," , start_pos + 8)
			-- mtype should be 0x0000
			mtype = string.sub(line, start_pos + 8, end_pos - 1)
			logger("dev_get_frame_info set message "..mtype)
		end
		if string.match(line, "TLV") then
			start_pos = string.find(line, "TLV,")
			if (start_pos == nil) then
				tlv = "0x00"
			else
				end_pos = string.find(line, "," , start_pos + 4)
				-- tlv should like 0x..
				tlv = string.sub(line, start_pos + 4, end_pos - 1)
				logger("dev_get_frame_info set TLV "..tlv)
			end
		end
		if string.match(line, "MID") then
				start_pos = string.find(line, "MID,")
				end_pos = string.find(line, "," , start_pos + 4)
				-- mid here should be NA or 0x....
				mid = string.sub(line, start_pos + 4, end_pos - 1)
				logger("dev_get_frame_info set MID "..mid)
				if string.match(mid, "NA") then
					-- reset to "0x0" if mid == NA
					mid = "0x0000"
					logger("dev_get_frame_info reset mid to "..mid)
				end
		end
		if string.match(line, "filter") then
			start_pos = string.find(line, "filter,")
			end_pos = string.find(line, "," , start_pos + 7)
			filter = string.sub(line, start_pos + 7, end_pos - 1)
			filter = string.lower(filter)
			logger("dev_get_frame_info set filter to "..filter)
		end
		if string.match(line, "returncontent") then
			start_pos = string.find(line, "returncontent,")
			end_pos = string.len(line)
			return_content = string.sub(line, start_pos + 14, end_pos - 1)
			return_content = string.lower(return_content)
			logger("dev_get_frame_info set returncontent to "..return_content)
		end
		iRet = DevGetFrameInfoMediatek(mtype,tlv,mid,filter,return_content)
		RESULT = "status,COMPLETE,"..iRet
		return RESULT
	elseif (string.find(line, "dev_set_trigger") == 1) then
		line = string.gsub(line, "dev_set_trigger,", "")
		local trigger, StaMac, Action
		if string.match(line, "trigger") then
                        start_pos = string.find(line, "trigger,")
                        end_pos = string.find(line, "," , start_pos + 8)
                        trigger = string.sub(line, start_pos + 8, end_pos-1)
                end
				
		if string.match(line, "STAMACAddress") then
                        start_pos = string.find(line, "STAMACAddress,")
                        end_pos = string.find(line, "," , start_pos + 14)
                        StaMac = string.sub(line, start_pos + 14, end_pos)
                end

		if string.match(line, "action") then
                        start_pos = string.find(line, "action,")
                        end_pos = string.find(line, "," , start_pos + 7)
                        Action = string.sub(line, start_pos + 7, end_pos)
                end

		iRet = DevSetParameterMediatek(trigger,StaMac,Action)
		RESULT = "status,COMPLETE"
		return RESULT
	else
		logger("command not supported, got :"..line)
	end

	return "OK"
end

function start_agent_server(conf)
	local socket = require("socket")
	local server = assert(socket.bind("*", conf.server_port))
	local tcp = assert(socket.tcp())

	logger("Started config server at "..conf.server_port.." "..ra_interface.." ")

	return server, tcp
end

function config_agent_main(conf)
	server, tcp = start_agent_server(conf)
	local result, err, partial
	local line = nil
	local client = nil
	while 1 do

		if client == nil then
			client = server:accept()
		end
		line, err, partial = client:receive()

		-- data received
		if line ~= nil then
			-- UCC needs this, no response will be processed without this
			client:send("status,RUNNING\n")
			-- pcall is for seg fault during processing, TODO add this for each fn call
			if (pcall(process_ucc_command(line))) then
				EXIT = 1
				break
			end

			logger(RESULT)
			client:send(RESULT.."\n")
		elseif err == "closed" then
			-- connection has closed, cleanup the client
			logger("connection is closed")
			client:close()
			client = nil
		elseif err == "timeout" then
			logger(err .. " partial: " .. partial)
			client:close()
			client = nil
		end

		if (EXIT == 1) then
			logger("closing tcp port and exiting, command : "..line)
			break
		end
		line = nil
	end

	if (tcp ~= nil) then
		tcp:close()
	end
	if (client ~= nil) then
		client:close()
	end
	if (server ~= nil) then
		server:close()
	end
end

MBOWappCommands = {}

MBOWappCommands["Cellular_Cap_Pref"] = "mbo ap_cdcp"
MBOWappCommands["BTMReq_DisAssoc_Imnt"] = "mbo disassoc_imnt"
MBOWappCommands["BTMReq_Term_Bit"] = "mbo bss_term_onoff"
MBOWappCommands["BSS_Term_Duration"] = "mbo bss_term_duration"
MBOWappCommands["BSS_Term_TSF"] =  "mbo bss_term_tsf"
MBOWappCommands["Assoc_Disallow"] = "mbo assoc_disallow"
MBOWappCommands["Nebor_BSSID"] =  "mbo nebor_bssid"
MBOWappCommands["Nebor_Op_Class"] =  "mbo nebor_op_class"
MBOWappCommands["Nebor_Op_Ch"] = "mbo nebor_op_ch"
MBOWappCommands["Disassoc_Timer"] = "mbo disassoc_timer"
MBOWappCommands["Assoc_Delay"] = "mbo retry_delay"
MBOWappCommands["Nebor_Pref"] = "mbo nebor_pref"
MBOWappCommands["Nebor_Test"] = "mbo add_test_nr"
MBOWappCommands["send_BTMReq"] = "mbo send_btm_req"
MBOWappCommands["Gas_CB_Delay"] = "set gas_cb_delay"
MBOWappCommands["Mpdu_Size"] = "set mmpdu_size"

-- read configurations here from nvram/db
local conf
conf = {}
RESULT = ""
EXIT = 0
-- global variable
log_file = ""

command = ""
conf.server_port = os.capture("datconf -f /etc/map/1905d.cfg get config_agent_port")

if (conf.server_port == nil or conf.server_port == "") then
	conf.server_port = 9215
end

function version_greater(ver1, ver2)
	local function split(str)
		local t = {}
		for num in string.gmatch(str, "%d+") do
		    table.insert(t, tonumber(num))
		end
		return t
	end
	local v1 = split(ver1)
	local v2 = split(ver2)
	for i = 1, math.max(#v1, #v2) do
		local n1 = v1[i] or 0
		local n2 = v2[i] or 0
		if n1 > n2 then
			return true
		elseif n1 < n2 then
			return false
		end
	end
    return true
end


local uname = os.capture("uname -r")
ver = uname:match("(%d+%.%d+%.%d+)") or uname:match("(%d+%.%d+)")

if ver and version_greater(ver, "5.4") then
	UNAME_OS_VER = ver
else
	UNAME_OS_VER = nil
end

if(UNAME_OS_VER == nil) then
	LAN_INTERFACE = os.capture("uci get network.lan.ifname")
	if (LAN_INTERFACE == nil) then
		-- set default interface
		LAN_INTERFACE = "eth0"
	end
else
	-- find the bridge device
	LAN_IF = os.capture("uci get network.lan.device")
	print ("DSAFindLANPorts: uci get network.lan.device "..LAN_IF.."")
	command = "cat /etc/map/mapd_default.cfg | grep Cert_RDKB | cut -c 11"
	CERT_RDKB = os.capture(command)
	if (string.match(CERT_RDKB, "1") ) then
		LAN_IN_DSA = os.capture("syscfg get lan_ethernet_physical_ifnames")
	else
		for dev_tree = 0,2 do
			-- check in device tree's local bridge device
			LAN_IN_LOCAL = os.capture("uci get network.@device["..dev_tree.."].name")
			print ("DSAFindLANPorts: uci get network.@device["..dev_tree.."].name = "..LAN_IN_LOCAL.."")
				if (LAN_IF == LAN_IN_LOCAL) then
					-- found a match, fetching device tree's local device ports.
					LAN_IN_DSA = os.capture("uci get network.@device["..dev_tree.."].ports")
					print ("DSAFindLANPorts: uci get network.@device["..dev_tree.."].ports = "..LAN_IN_DSA.."")
					break
				end
		end
	end

end

-- remove older logs file
execute ("rm -rf "..CONFIG_AGENT_LOGS_FILE)

execute ("touch "..CONFIG_AGENT_LOGS_FILE)
-- Opens a file in append mode
log_file = io.open(CONFIG_AGENT_LOGS_FILE, "a")

-- sets the default output file as logger file
io.output(log_file)

-- run deamon
config_agent_main(conf)
