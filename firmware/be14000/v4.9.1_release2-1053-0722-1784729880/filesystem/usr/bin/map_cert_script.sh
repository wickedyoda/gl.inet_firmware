# argument details
# First Argument is SKU second Argument is device role 
# Device Role 1 - MCUT Device Role 2 - MAUT
# 1  --> MT7621 + MT7615D LSDK
# 2  --> MT7621 + MT7615 + MT7615  LSDK
# 3  --> MT7621 + MT7615D OPENWRT
# 4  --> MT7621 + MT7615 + MT7615  OPENWRT dual-band
# 5  --> MT7621 + MT7615D + MT7615  OPENWRT tri-band
# 6  --> MT7622 + MT7615 dual-band
# 7  --> MT7622 + MT7615D tri-band 
# 8  --> red board MT7622 + MT7615 + MT7615 tri-band  + switch RTL8367S
# 9	 --> MT7629 OPENWRT/LEDE 
# 11  --> MT7621 + MT7615D + MT7613  OPENWRT tri-band
# 12  --> green board MT7622 + MT7615 + MT7615 tri-band + switch MT7531
# 13  --> MT7621 + 7603 + MT7613 OPENWRT
# 14  --> MT7621 + MT7603 + MT7615 OPENWRT
# 15  --> MT7621 + MT7615D LEDE
# 16  --> MT7622 + MT7915D + switch MT7531
# 17  --> MT7622 + MT7915D + MT7915A tri-band with switch MT7531
# 18  --> MT6890 + MT7915 + MT7915 dual-band with switch MT7531
# 19  --> MT6890 + MT7915D with switch MT7531
# 20  --> MT7986 ( AX4200 )
# 21  --> MT7916 ( MERLIN )
# 22  --> MT7986 (AX8400)
# 23  --> MT7986 (AX7800 2G:5G:6G)
# 24  --> MT7986 (AX7800 2G:5GL:5GH)
# 25  --> Bellwether (Logan)
# 26  --> Eagle (Logan)
# 27  --> Eagle ( MAP R6 )
# 28  --> Kite (MAP_R4)
# 29  --> Kite (MAP_R6)
# 30  --> Griffin (MAP_R4)
# 31  --> Griffin (MAP_R6)

set -x
RED='\033[0;31m'
NC='\033[0m'
echo -e "----- ${RED}EasyMesh CERT SCRIPT dev=$1 Role=$2 ${NC} -----"
dev="$1"
Role="$2"
MAP_R2="$3"
echo "1  --> MT7621 + MT7615D LSDK"
echo "2  --> MT7621 + MT7615 + MT7615  LSDK"
echo "3  --> MT7621 + MT7615D OPENWRT"
echo "4  --> MT7621 + MT7615 + MT7615  OPENWRT dual-band"
echo "5  --> MT7621 + MT7615 + MT7615  OPENWRT tri-band"
echo "6  --> MT7622 + MT7615 dual-band"
echo "7  --> MT7622 + MT7615D tri-band" 
echo "8  --> MT7622 + MT7615 + MT7615 tri-band with switch RTL8367S"
echo "9  --> MT7629 OPENWRT/LEDE"
echo "12 --> MT7622 + MT7615 + MT7615 tri-band with switch MT7531"
echo "13  --> MT7621 + MT7603 + MT7613 OPENWRT"
echo "14  --> MT7621 + MT7603 + MT7615 OPENWRT"
echo "15  --> MT7621 + MT7915D LEDE and MT7986B (AX6000)"
echo "16  --> MT7622 + MT7915D + switch MT7531"
echo "17  --> MT7622 + MT7915D + MT7915A tri-band with switch MT7531"
echo "18  --> MT6890 + MT7915 + MT7915 dual-band + switch MT7531"
echo "19  --> MT6890 + MT7915D + switch MT7531"
echo "20  --> MT7986 ( AX4200 )"
echo "21  --> MT7622A + MT7531B_IPA"
echo "22  --> MT7986 (AX8400)"
echo "23  --> MT7986 (AX7800 2G:5G:6G)"
echo "24  --> MT7986 (AX7800 2G:5GL:5GH)"
echo "25  --> Bellwether (Logan)"
echo "26  --> Eagle (Logan)"
echo "27  --> Eagle (MAP_R6)"
echo "28  --> Kite (MAP_R4)"
echo "29  --> Kite (MAP_R6)"
echo "30  --> Griffin (MAP_R4)"
echo "31  --> Griffin (MAP_R6)"

if [ "$4" == "RDKB" ];then
	datconf -f /etc/map/mapd_default.cfg set Cert_SKU $dev
	datconf -f /etc/map/mapd_default.cfg set Cert_RDKB 1
	rm /nvram/vap-status
	touch /nvram/vap-status
	rm /sbin/udhcpc
#set hostapdx/.conf for 2G
	datconf -f /nvram/hostapd0.conf set mbo 1
	datconf -f /nvram/hostapd0.conf set ieee80211w 1
	datconf -f /nvram/hostapd0.conf set country_code US
	datconf -f /nvram/hostapd0.conf set channel 6
	datconf -f /nvram/hostapd0.conf set ssid map_cert_2g
	datconf -f /nvram/hostapd0.conf set bss_transition 1
	datconf -f /nvram/hostapd0.conf set rrm_neighbor_report 1
	datconf -f /nvram/hostapd0.conf set rrm_beacon_report 1
	datconf -f /nvram/hostapd0.conf set oce 4
	datconf -f /nvram/hostapd0.conf set interworking 1

	for i in 1 2 3
	do
		if [ "$dev" = "28"  -o "$dev" = "29"-o "$dev" = "30" ];then
			index=$((i*2))
		elif [ "$dev" = "26" ];then
			index=$((i*2 + i))
		fi
		cp /nvram/hostapd0.conf /nvram/hostapd$index.conf
		datconf -f /nvram/hostapd$index.conf set interface ra$i
		datconf -f /nvram/hostapd$index.conf set ssid map_cert_2g_$i
		#create wpa_psk_file
		touch /nvram/hostapd$index.psk
		datconf -f /nvram/hostapd$index.conf set wpa_psk_file /nvram/hostapd$index.psk
		datconf -f /nvram/vap-status set ra$i 1
		sync
	done
#set hostapdx.conf for 5G
	datconf -f /nvram/hostapd1.conf set mbo 1
	datconf -f /nvram/hostapd1.conf set ieee80211w 1
	datconf -f /nvram/hostapd1.conf set country_code US
	datconf -f /nvram/hostapd1.conf set channel 36
	datconf -f /nvram/hostapd1.conf set ssid map_cert_5g
	datconf -f /nvram/hostapd1.conf set bss_transition 1
	datconf -f /nvram/hostapd1.conf set rrm_neighbor_report 1
	datconf -f /nvram/hostapd1.conf set rrm_beacon_report 1
	datconf -f /nvram/hostapd1.conf set oce 4
	datconf -f /nvram/hostapd1.conf set interworking 1
	for i in 1 2 3
	do
		if [ "$dev" = "28"  -o "$dev" = "29" -o "$dev" = "30" -o "$dev" = "31"];then
			index=$((i*2 + 1))
		elif [ "$dev" = "26" ];then
			index=$((i*2 + i + 1))
		fi
		cp /nvram/hostapd1.conf /nvram/hostapd$index.conf
		datconf -f /nvram/hostapd$index.conf set interface rai$i
		datconf -f /nvram/hostapd$index.conf set ssid map_cert_5g_$i
		#create wpa_psk_file
		touch /nvram/hostapd$index.psk
		datconf -f /nvram/hostapd$index.conf set wpa_psk_file /nvram/hostapd$index.psk
		datconf -f /nvram/vap-status set rai$i 1
		sync
	done
#Configure IP Address
	sysevent set dhcp_server-stop
	sysevent set firewall-stop
	syscfg set wan_proto static
	syscfg set lan_proto static
	syscfg commit
if [ "$Role" == "1" ];then
        #Controller
        echo -e "----- config CONTROLLER ip address -----"
        syscfg set lan_ipaddr 192.165.100.101
        syscfg set lan_netmask 255.255.255.0
        syscfg set wan_ipaddr 192.168.250.201
        syscfg set wan_netmask 255.255.255.0
	syscfg commit
elif [ "$Role" = "2" ];then
        #Agent1
        echo -e "----- config AGENT1 ip address -----"
        syscfg set lan_ipaddr 192.165.100.102
        syscfg set lan_netmask 255.255.255.0
        syscfg set wan_ipaddr 192.168.250.202
        syscfg set wan_netmask 255.255.255.0
	syscfg commit
elif [ "$Role" = "3" ];then
        #Agent2
        echo -e "----- config AGENT2 ip address -----"
        syscfg set lan_ipaddr 192.165.100.103
        syscfg set lan_netmask 255.255.255.0
        syscfg set wan_ipaddr 192.168.250.203
        syscfg set wan_netmask 255.255.255.0
	syscfg commit
elif [ "$Role" = "4" ];then
        echo -e "----- config DUT ip address -----"
        syscfg set lan_ipaddr 192.165.100.104
        syscfg set lan_netmask 255.255.255.0
        syscfg set wan_ipaddr 192.168.250.204
        syscfg set wan_netmask 255.255.255.0
	syscfg commit
else
        echo -e "----- not change ip address -----"
fi
	sysevent set wan-stop
	sysevent set wan-start 1
	sysevent set lan-stop
	sysevent set lan-start
fi

#1) check SDK Type
echo -e "----- ${RED}EasyMesh CERT SCRIPT dev=$dev ${NC} -----"
if [ "$dev" = "3" -o "$dev" = "4" -o "$dev" = 5 -o\
 "$dev" = "6" -o "$dev" = "7" -o "$dev" = "8" -o\
 "$dev" = "9" -o "$dev" = "11" -o "$dev" = "12" -o\
 "$dev" = "13" -o "$dev" = "14"  -o "$dev" = "15" -o\
 "$dev" = "16" -o "$dev" = "17"  -o "$dev" = "18"  -o\
  "$dev" = "19" -o "$dev" = "20" -o "$dev" = "21" -o\
 "$dev" = "22" -o "$dev" = "23" -o "$dev" = "24" -o\
 "$dev" = "25" -o "$dev" = "26" -o "$dev" = "27" -o\
 "$dev" = "28" -o "$dev" = "29" -o "$dev" = "30" -o "$dev" = "31" ];then
SDK_TYPE=OPENWRT
br0_mac=$(cat /sys/class/net/br-lan/address)
br0_mac_last_byte="0x${br0_mac##*:}"
br0_mac_first_five_str=${br0_mac%:*}
al_mac_last_byte=$(printf "%02X" $((br0_mac_last_byte ^ 0xAA)))
al_mac="$br0_mac_first_five_str:$al_mac_last_byte"
uci set network.lan.macaddr="$br0_mac_first_five_str:$al_mac_last_byte"
uci commit
else
SDK_TYPE=LSDK
al_mac=$(cat /sys/class/net/br0/address)
fi

#2) check Platform
if [ "$dev" = "6" -o "$dev" = "7" -o "$dev" = "8" -o "$dev" = "12" -o "$dev" = "16" -o "$dev" = "17" -o "$dev" = "21" ];then
PLATFORM=MT7622
LAN_INTF=eth0
WAN_INTF=eth1
if [ "$dev" = "12" -o "$dev" = "16" -o "$dev" = "17" -o "$dev" = "18" -o "$dev" = "19" -o "$dev" = "21" ]; then
#forward 1905 multicast to cpu port not flooding
switch reg w 34 8160816
switch reg w 4 60
switch reg w 10 ffffffff

switch vlan clear

#lan port 0-3 and cpu port, vlan id 1
switch vlan set 0 1 11110010
#wan port 4-5, vlan id 2
switch vlan set 1 2 00001100

#lan port and cpu port set pvid to 1
switch vlan pvid 0 1
switch vlan pvid 1 1
switch vlan pvid 2 1
switch vlan pvid 3 1
switch vlan pvid 6 1

#wan port set pvid to 2
switch vlan pvid 4 2
switch vlan pvid 5 2

#add vlan 10,20,30 to lan port and cpu port
# P0/P1/P2/P3/P6(242 bitmap) belog to group of vid=10,P6(64 index) in VLAN 10  egress is tagged.
switch vlan vid 0 1 10 242 64 1 0 0
# P0/P1/P2/P3/P6(242 bitmap) belog to group of vid=20,P6(64 index) in VLAN 20  egress is tagged.
switch vlan vid 0 1 20 242 64 1 0 0
# P0/P1/P2/P3/P6(242 bitmap) belog to group of vid=30,P6(64 index) in VLAN 30  egress is tagged.
switch vlan vid 0 1 30 242 64 1 0 0


# reg: 2n04, n = port num
#set all port to check vlan after receiving pkt(security mode=3)
switch vlan port-mode 0 3
switch vlan port-mode 1 3
switch vlan port-mode 2 3
switch vlan port-mode 3 3
switch vlan port-mode 4 3
switch vlan port-mode 5 3
switch vlan port-mode 6 3

switch clear
fi
elif [ "$dev" = "1" -o "$dev" = "2" -o "$dev" = "3" -o "$dev" = "4" -o "$dev" = "5" -o "$dev" = "11" ]; then
PLATFORM=MT7621
LAN_INTF=eth0
WAN_INTF=eth1
elif [ "$dev" = "13" -o "$dev" = "14" ]; then
#master branch autobuild sqc image
#config for map1.0 certification
#interfaces need config to eth0/1
uci set network.lan.ifname=eth0
uci set network.wan.ifname=eth1
uci set network.wan6.ifname=eth1
uci commit
PLATFORM=MT7621
LAN_INTF=eth0
WAN_INTF=eth1
elif [ "$dev" = "9" ]; then
PLATFORM=MT7629
LAN_INTF=eth0
WAN_INTF=eth1
elif [ "$dev" = "15" -o "$dev" = "18" -o "$dev" = "19" ]; then
PLATFORM=MT7915
LAN_INTF=eth0
WAN_INTF=eth1
elif [ "$dev" = "20" -o "$dev" = "22" -o "$dev" = "23" -o "$dev" = "24" -o "$dev" = "25" ]; then
PLATFORM=MT7986
LAN_INTF=eth0
WAN_INTF=eth1
elif [ "$dev" = "26" -o "$dev" = "27" ]; then
PLATFORM=MT7988
LAN_INTF=`uci get network.@device[0].ports`
WAN_INTF=eth1
elif [ "$dev" = "28" ]; then
PLATFORM=MT7992
LAN_INTF=`uci get network.@device[0].ports`
WAN_INTF=eth1
elif [ "$dev" = "29" ]; then
PLATFORM=MT7992
LAN_INTF=eth0
WAN_INTF=eth1
elif [ "$dev" = "30" ]; then
PLATFORM=MT7993
LAN_INTF=`uci get network.@device[0].ports`
WAN_INTF=eth1
elif [ "$dev" = "31" ]; then
PLATFORM=MT7993
LAN_INTF=`uci get network.@device[0].ports`
WAN_INTF=eth1
fi

#3) Check IF DBDC Mode
if [ "$dev" = "1" -o "$dev" = "3" -o "$dev" = "7" -o "$dev" = "9" -o "$dev" = "11" -o\
	"$dev" = "15" -o "$dev" = "19"  -o "$dev" = "20" -o "$dev" = "21" -o "$dev" = "22" -o "$dev" = "23" -o "$dev" = "24" ];then
DBDC_MODE=1
fi
if [ "$SDK_TYPE" = "OPENWRT" ];then
echo "CONFIGURING PLATFORM $PLATFORM FOR OPENWRT SDK"
else
echo "CONFIGURING PLATFORM $PLATFORM FOR LSDK"
fi

echo -e "----- ${RED}EasyMesh CERT SCRIPT SDK=$SDK_TYPE  Genric Config${NC} -----" 

isEagleDualband="0"

if [  "$dev" = "26"  -o "$dev" = "27" ]; then

	main_iface_num=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname | cut -d '=' -f 2 | awk -F ';' '{print NF}'`
	card_initial_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
	profile_num=`cat ${card_initial_profile_path} | grep profile_path |wc -l`
	band1_profile_exist=`cat ${card_initial_profile_path} | grep BN1_profile_path`

	if [ "$main_iface_num" -eq "2" -a "$profile_num" -eq "2" -a -z "$band1_profile_exist" ]; then
		isEagleDualband="1"
	fi
	if [  "$isEagleDualband" == "1" ]; then
		echo "----- MT7990  205----------"
		MT7990_B1_DAT=mt7990.b1.dualband.dat
	else
		echo "----- MT7990  256----------"
		MT7990_B1_DAT=mt7990.b1.dat
	fi
fi

if [ "$MAP_R2" != "0" ];then
	if [ "$dev" = "26" ]; then
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set QoSEnable 1
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT  set QoSEnable 1
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set DscpPriMapEnable 1
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set DscpPriMapEnable 1
	elif [ "$dev" = "27" ];then
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set QoSEnable 0
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set QoSEnable 0
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set QoSEnable 0
	elif [ "$dev" = "29" ];then
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set QoSEnable 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set QoSEnable 0
	elif [ "$dev" = "31" ];then
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set QoSEnable 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set QoSEnable 0
	else
		datconf -f /tmp/mtk/wifi/2860 set QoSEnable 0
		datconf -f /tmp/mtk/wifi/rtdev set QoSEnable 0
		datconf -f /tmp/mtk/wifi/wifi3 set QoSEnable 0
	fi
fi

if [ "$MAP_R2" = "1" -o "$MAP_R2" = "2" ];then

	if [  "$dev" = "26"  -o "$dev" = "27" ]; then
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set BssidNum 4
		#datconf -f /tmp/mtk/wifi/wifi3 set BssidNum 4
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set MboSupport "1;1;1;1"
		#datconf -f /tmp/mtk/wifi/wifi3 set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set PMFMFPC "1;1;1;1"
		#datconf -f /tmp/mtk/wifi/wifi3 set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set MapR2Enable 1
		#datconf -f /tmp/mtk/wifi/wifi3 set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_AMSDU 0
		#datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_AutoBA 0
		#datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_BADecline 1
		#datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7990.b0.dat set G_BAND_256QAM 0
		datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set G_BAND_256QAM 0
		#datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
		if [ "$dev" = "27" ]; then
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set BssidNum 4
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set MboSupport "1;1;1;1"
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set PMFMFPC "1;1;1;1"
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set MapR2Enable 1
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set HT_AMSDU 0
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set HT_AutoBA 0
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set HT_BADecline 1
			datconf -f /etc/wireless/mediatek/mt7990.b2.dat set G_BAND_256QAM 0
		fi
	elif [ "$dev" = "28" ]; then
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set G_BAND_256QAM 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set G_BAND_256QAM 0
	elif [  "$dev" = "29" ]; then
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7992.b0.dat set G_BAND_256QAM 0
		datconf -f /etc/wireless/mediatek/mt7992.b1.dat set G_BAND_256QAM 0
	elif [ "$dev" = "30" ]; then
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set G_BAND_256QAM 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set G_BAND_256QAM 0
	elif [  "$dev" = "31" ]; then
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set BssidNum 4
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MboSupport "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set PMFMFPC "1;1;1;1"
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MapR2Enable 1
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_AMSDU 0
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_AutoBA 0
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BADecline 1
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set G_BAND_256QAM 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set G_BAND_256QAM 0
	else
		datconf -f /tmp/mtk/wifi/2860 set BssidNum 4
		datconf -f /tmp/mtk/wifi/wifi3 set BssidNum 4
		datconf -f /tmp/mtk/wifi/rtdev set BssidNum 4
		datconf -f /tmp/mtk/wifi/2860 set MboSupport "1;1;1;1"
		datconf -f /tmp/mtk/wifi/rtdev set MboSupport "1;1;1;1"
		datconf -f /tmp/mtk/wifi/wifi3 set MboSupport "1;1;1;1"
		datconf -f /tmp/mtk/wifi/2860 set PMFMFPC "1;1;1;1"
		datconf -f /tmp/mtk/wifi/rtdev set PMFMFPC "1;1;1;1"
		datconf -f /tmp/mtk/wifi/wifi3 set PMFMFPC "1;1;1;1"
		datconf -f /tmp/mtk/wifi/2860 set MapR2Enable 1
		datconf -f /tmp/mtk/wifi/rtdev set MapR2Enable 1
		datconf -f /tmp/mtk/wifi/wifi3 set MapR2Enable 1
		datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
		datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
		datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
		datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
		datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
		datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
		datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
		datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
		datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
		datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
		datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
		datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	fi
else
datconf -f /tmp/mtk/wifi/2860 set BssidNum 2
datconf -f /tmp/mtk/wifi/wifi3 set BssidNum 2
datconf -f /tmp/mtk/wifi/rtdev set BssidNum 2
fi
if [ "$dev" = "15" ];then
datconf -f /tmp/mtk/wifi/2860 set BssidNum 4
datconf -f /tmp/mtk/wifi/wifi3 set BssidNum 4
datconf -f /tmp/mtk/wifi/rtdev set BssidNum 4
fi
if [ "$dev" = "23" ];then
datconf -f /tmp/mtk/wifi/2860 set BssidNum 4
datconf -f /tmp/mtk/wifi/wifi3 set BssidNum 1
datconf -f /tmp/mtk/wifi/rtdev set BssidNum 4
fi
if [ "$dev" = "25"  -o "$dev" = "26" -o "$dev" = "27" ];then
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set BssidNum 4
#datconf -f /etc/wireless/mediatek/mt7990.b2.dat set BssidNum 1
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set BssidNum 4
	if [ "$dev" = "27" ];then
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set BssidNum 4
	fi
fi
if [ "$dev" = "29" ];then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set BssidNum 4
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set BssidNum 4
fi
if [ "$dev" = "31" ];then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set BssidNum 4
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set BssidNum 4
fi
if [  "$dev" = "26" -o "$dev" = "27" ]; then
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set MAP_Ext "32;32;32;32;32;32;32;32"
#datconf -f /tmp/mtk/wifi/wifi3 set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set map_controller 1
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set map_agent 1
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set map_root 0
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set bh_type wifi
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_BW 0
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_BW 0
#datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 0
	if [  "$dev" = "27"]; then
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set MAP_Ext "32;32;32;32;32;32;32;32"
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set HT_BW 0
	fi
elif [  "$dev" = "28" ]; then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MAP_Ext "32;32;32;32;32;32;32;32"
#datconf -f /tmp/mtk/wifi/wifi3 set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set map_controller 1
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set map_agent 1
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set map_root 0
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set bh_type wifi
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BW 0
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BW 0
elif [  "$dev" = "29" ]; then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set map_controller 1
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set map_agent 1
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set map_root 0
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set bh_type wifi
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BW 0
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BW 0
elif [  "$dev" = "30" ]; then
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MAP_Ext "32;32;32;32;32;32;32;32"
#datconf -f /tmp/mtk/wifi/wifi3 set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set map_controller 1
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set map_agent 1
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set map_root 0
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set bh_type wifi
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BW 0
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BW 0
elif [  "$dev" = "31" ]; then
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set map_controller 1
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set map_agent 1
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set map_root 0
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set bh_type wifi
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BW 0
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BW 0
else
datconf -f /tmp/mtk/wifi/2860 set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /tmp/mtk/wifi/rtdev set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /tmp/mtk/wifi/wifi3 set MAP_Ext "32;32;32;32;32;32;32;32"
datconf -f /tmp/mtk/wifi/2860 set map_controller 1
datconf -f /tmp/mtk/wifi/2860 set map_agent 1
datconf -f /tmp/mtk/wifi/2860 set map_root 0
datconf -f /tmp/mtk/wifi/2860 set bh_type wifi
datconf -f /tmp/mtk/wifi/2860 set HT_BW 0
datconf -f /tmp/mtk/wifi/rtdev set HT_BW 0
datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 0
fi
if [ "$MAP_R2" = "1" -o "$MAP_R2" = "2" ];then
if [  "$dev" = "26" -o "$dev" = "27" ]; then
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set RRMEnable "1;1;1;1"
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set RRMEnable "1;1;1;1"
#datconf -f /tmp/mtk/wifi/wifi3 set RRMEnable "1;1;1;1"
	if [  "$dev" = "27" ]; then
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set RRMEnable "1;1;1;1"
	fi
elif [  "$dev" = "28" ]; then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set RRMEnable "1;1;1;1"
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set RRMEnable "1;1;1;1"
elif [  "$dev" = "29" ]; then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set RRMEnable "1;1;1;1"
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set RRMEnable "1;1;1;1"
elif [  "$dev" = "30" ]; then
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set RRMEnable "1;1;1;1"
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set RRMEnable "1;1;1;1"
elif [  "$dev" = "31" ]; then
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set RRMEnable "1;1;1;1"
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set RRMEnable "1;1;1;1"
else
datconf -f /tmp/mtk/wifi/2860 set RRMEnable "1;1;1;1"
datconf -f /tmp/mtk/wifi/rtdev set RRMEnable "1;1;1;1"
datconf -f /tmp/mtk/wifi/wifi3 set RRMEnable "1;1;1;1"
fi
else
datconf -f /tmp/mtk/wifi/2860 set RRMEnable "1;1"
datconf -f /tmp/mtk/wifi/rtdev set RRMEnable "1;1"
datconf -f /tmp/mtk/wifi/wifi3 set RRMEnable "1;1"
fi
if [  "$dev" = "26" -o "$dev" = "27" ]; then
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set VHT_BW 0
#datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set AutoChannelSelect 0
#datconf -f /tmp/mtk/wifi/wifi3 set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set SteerEnable 1
datconf -f /etc/wireless/mediatek/mt7990.b0.dat set MapMode 4
datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set MapMode 4
#datconf -f /tmp/mtk/wifi/wifi3 set MapMode 4
	if [  "$dev" = "27" ]; then
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set VHT_BW 0
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set AutoChannelSelect 0
		datconf -f /etc/wireless/mediatek/mt7990.b2.dat set MapMode 4
	fi
elif [  "$dev" = "28" ]; then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set VHT_BW 0
#datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set AutoChannelSelect 0
#datconf -f /tmp/mtk/wifi/wifi3 set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set SteerEnable 1
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MapMode 4
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MapMode 4
elif [  "$dev" = "29" ]; then
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set SteerEnable 1
datconf -f /etc/wireless/mediatek/mt7992.b0.dat set MapMode 4
datconf -f /etc/wireless/mediatek/mt7992.b1.dat set MapMode 4
elif [  "$dev" = "30" ]; then
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set VHT_BW 0
#datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set AutoChannelSelect 0
#datconf -f /tmp/mtk/wifi/wifi3 set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set SteerEnable 1
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MapMode 4
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MapMode 4
elif [  "$dev" = "31" ]; then
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set VHT_BW 0
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set AutoChannelSelect 0
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set SteerEnable 1
datconf -f /etc/wireless/mediatek/mt7993.b0.dat set MapMode 4
datconf -f /etc/wireless/mediatek/mt7993.b1.dat set MapMode 4
else
datconf -f /tmp/mtk/wifi/2860 set VHT_BW 0
datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 0
datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 0
datconf -f /tmp/mtk/wifi/2860 set AutoChannelSelect 0
datconf -f /tmp/mtk/wifi/wifi3 set AutoChannelSelect 0
datconf -f /tmp/mtk/wifi/rtdev set AutoChannelSelect 0
datconf -f /tmp/mtk/wifi/2860 set SteerEnable 1
datconf -f /tmp/mtk/wifi/2860 set MapMode 4
datconf -f /tmp/mtk/wifi/rtdev set MapMode 4
datconf -f /tmp/mtk/wifi/wifi3 set MapMode 4
fi
if [ "$dev" == "23" -o "$dev" == "24" ];then
datconf -f /etc/wireless/mediatek/mt7986-ax7800.dbdc.b0.dat set MapMode 4
fi
if [ "$MAP_R2" == "0" ];then
datconf -f /tmp/mtk/wifi/2860 set HT_BW 1
datconf -f /tmp/mtk/wifi/rtdev set HT_BW 1
datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 1
datconf -f /tmp/mtk/wifi/2860 set VHT_BW 1
datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 1
datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 1
datconf -f /tmp/mtk/wifi/2860 set MboSupport "0;0;0;0"
datconf -f /tmp/mtk/wifi/rtdev set MboSupport "0;0;0;0"
datconf -f /tmp/mtk/wifi/wifi3 set MboSupport "0;0;0;0"
fi

#4) Configure Per SKU Params
#Default channel for 24G is 6 / 5GL is 36 /5GH is 149
#Radio band in case of 2 band 2.4G;5G;5G & in case of tri-band 2.4G;5Gh;5GL
# BSS priority should be configured in the order of interfaces and bss registered
echo -e "----- ${RED}EasyMesh CERT SCRIPT SKU=$dev Per SKU Config${NC} -----" 
if [ "$dev" = "1" ];then
	bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 36
elif [ "$dev" = "2" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;apcli0;apclii0"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
elif [ "$dev" = "3" ];then
	bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 36
	datconf -f /tmp/mtk/wifi/rtdev set Channel 6
elif [ "$dev" = "4" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;apcli0;apclii0"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
elif [ "$dev" = "5" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;rax0;rax1;apcli0;apclii0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 36
	datconf -f /tmp/mtk/wifi/rtdev set Channel 149
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5GL;5GH;"
elif [ "$dev" = "6" ];then
	bss_config_priority="rai0;rai1;ra0;ra1;apclii0;apcli0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set WirelessMode 9
	datconf -f /tmp/mtk/wifi/rtdev set WirelessMode 14
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
        datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
elif [ "$dev" = "7" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;wlan0;wlan1;apcli0;apclii0;wlan-apcli0"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 36
	datconf -f /tmp/mtk/wifi/rtdev set Channel 149
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5GL;5GH;"
elif [ "$dev" = "8" -o "$dev" = "12" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;wlan0;wlan1;apcli0;apclii0;wlan-apcli0"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 149
	datconf -f /tmp/mtk/wifi/rtdev set ChannelGrp "1:1:0:0"
	datconf -f /tmp/mtk/wifi/wifi3 set ChannelGrp "0:0:1:1"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5GL;5GH;"
	if [ "$dev" = "12" ];then
		datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
		datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
		datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
		datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
		datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
		datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
		datconf -f /tmp/mtk/wifi/rtdev set Channel 149
		datconf -f /tmp/mtk/wifi/wifi3 set Channel 36
		datconf -f /tmp/mtk/wifi/2860 set Channel 6
		datconf -f /tmp/mtk/wifi/wifi3 set ChannelGrp "1:1:0:0"
		datconf -f /tmp/mtk/wifi/rtdev set ChannelGrp "0:0:1:1"
	fi
elif [ "$dev" = "9" ];then
	bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 36
elif [ "$dev" = "11" ];then
	bss_config_priority="rax0;rax1;rax2;rax3;rai0;rai1;rai2;rai3;ra0;ra1;ra2;ra3;apclix0;apclii0;apcli0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5GL;5GH;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 149
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 36
	datconf -f /tmp/mtk/wifi/rtdev set Channel 6
elif [ "$dev" = "13" -o "$dev" = "14" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;apcli0;apclii0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
elif [ "$dev" = "15" ];then
        bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	if [ "$MAP_R2" = "2" ]; then
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/2860 set VHT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 2
	datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
	datconf -f /tmp/mtk/wifi/2860 set HT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BW 2
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
	datconf -f /tmp/mtk/wifi/2860 set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/2860 set VHT_LDPC 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_LDPC 0
	datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
	else
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
   	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
    	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
    	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	fi
	datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	if [ "$MAP_R2" = "2" ]; then
		datconf -f /tmp/mtk/wifi/2860 WifiCert 1
		datconf -f /tmp/mtk/wifi/rtdev WifiCert 1
		datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
	fi
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "16" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;apcli0;apclii0"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 149
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "17" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;rax0;rax1;apcli0;apclii0;apclix0"
	datconf -f /tmp/mtk/wifi/2860  set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/wifi3 set Channel 149
	datconf -f /tmp/mtk/wifi/rtdev set ChannelGrp "1:1:0:0"
	datconf -f /tmp/mtk/wifi/wifi3  set ChannelGrp "0:0:1:1"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5GL;5GH;"
	datconf -f /tmp/mtk/wifi/2860 set E2pAccessMode 1
	datconf -f /tmp/mtk/wifi/rtdev set E2pAccessMode 1
	datconf -f /tmp/mtk/wifi/wifi3 set E2pAccessMode 1
	datconf -f /tmp/mtk/wifi/2860 set WifiCert 1
	datconf -f /tmp/mtk/wifi/rtdev set WifiCert 1
	datconf -f /tmp/mtk/wifi/wifi3 set WifiCert 1
	datconf -f /tmp/mtk/wifi/2860 set CP_SUPPORT 1
	datconf -f /tmp/mtk/wifi/rtdev set CP_SUPPORT 1
	datconf -f /tmp/mtk/wifi/wifi3 set CP_SUPPORT 1
	datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "18" ];then
	bss_config_priority="ra0;ra1;rai0;rai1;apcli0;apclii0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "5G;24G;5G;"
	datconf -f /tmp/mtk/wifi/rtdev set radio_band "5G;24G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 36
	datconf -f /tmp/mtk/wifi/rtdev set Channel 6
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/2860 set VHT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 0
	datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BW 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BW 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 1
	datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "19" ];then
        bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
    	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
    	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "20" ];then
        bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
        datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
        datconf -f /tmp/mtk/wifi/2860 set Channel 6
        datconf -f /tmp/mtk/wifi/rtdev set Channel 36
        datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
        datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
        datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
        datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
        datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
        datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
        datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
        datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
        datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	if [ "$MAP_R2" = "2" ]; then
        datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 2
        datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 3
        datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 3
        datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 2
        datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 3
        datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 3
        datconf -f /tmp/mtk/wifi/2860 set VHT_BW 0
        datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 2
        datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
        datconf -f /tmp/mtk/wifi/2860 set HT_BW 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_BW 2
        datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
        datconf -f /tmp/mtk/wifi/2860 set HT_LDPC 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_LDPC 0
        datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
        datconf -f /tmp/mtk/wifi/2860 set VHT_LDPC 0
        datconf -f /tmp/mtk/wifi/rtdev set VHT_LDPC 0
        datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
        else
        datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
        datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
        fi
        datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "21" ];then
	bss_config_priority="ra0;ra1;rax0;rax1;apcli0;apclix0"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;5G;"
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	if [ "$MAP_R2" = "2" ]; then
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/2860 set VHT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 2
	datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
	datconf -f /tmp/mtk/wifi/2860 set HT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BW 2
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
	datconf -f /tmp/mtk/wifi/2860 set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/2860 set VHT_LDPC 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_LDPC 0
	datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
	else
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
    	datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
   	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
    	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
    	datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	fi
	datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	if [ "$MAP_R2" = "2" ]; then
		datconf -f /tmp/mtk/wifi/2860 WifiCert 1
		datconf -f /tmp/mtk/wifi/rtdev WifiCert 1
		datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
	fi
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "22" -o  "$dev" = "23" -o "$dev" = "24" ];then
        bss_config_priority="ra0;ra1;ra2;ra3;rai0;rai1;rai2;rai3;rax0;rax1;rax2;rax3;apcli0;apclii0;apclix0"
	if [ "$dev" = "23" -o "$dev" = "24" ];then
        bss_config_priority="rai0;rai1;rai2;rai3;rax0;rax1;rax2;rax3;raix0;raix1;raix2;raix3;apclii0;apclix0;apcliix0"
	fi
	datconf -f /etc/map/1905d.cfg set radio_band "24G;5G;6G"
	datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5G;6G;"
	if [ "$dev" = "24" ]; then
		datconf -f /etc/map/1905d.cfg set radio_band "24G;5GL;5GH"
		datconf -f /tmp/mtk/wifi/2860 set radio_band "24G;5GL;5GH;"
		datconf -f /tmp/mtk/wifi/wifi3 set ChannelGrp "0:0:1:1"
		datconf -f /tmp/mtk/wifi/rtdev set ChannelGrp "1:1:0:0"
		datconf -f /tmp/mtk/wifi/wifi3 set Channel  149
		datconf -f /tmp/mtk/wifi/wifi3 set CountryRegionABand 13
	fi
	datconf -f /tmp/mtk/wifi/2860 set Channel 6
	datconf -f /tmp/mtk/wifi/rtdev set Channel 36
	datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
	datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
	#datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	if [ "$MAP_R2" = "2" ]; then
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 4
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
	if [ "$dev" = "23" -o "$dev" = "24" ]; then
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 2
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 2
	fi
	datconf -f /tmp/mtk/wifi/2860 set VHT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 2
	#datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
	datconf -f /tmp/mtk/wifi/2860 set HT_BW 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BW 2
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
	datconf -f /tmp/mtk/wifi/2860 set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_LDPC 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
	datconf -f /tmp/mtk/wifi/2860 set VHT_LDPC 0
	datconf -f /tmp/mtk/wifi/rtdev set VHT_LDPC 0
	#datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
	else
	datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
	datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
	datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
	fi
	datconf -f /tmp/mtk/wifi/rtdev set CountryRegionABand 13
	if [ "$MAP_R2" = "2" ]; then
		datconf -f /tmp/mtk/wifi/2860 WifiCert 1
		datconf -f /tmp/mtk/wifi/rtdev WifiCert 1
		#datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
	fi
	datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
	datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "25" ];then
        bss_config_priority="rai0;rai1;rai2;rai3;rax0;rax1;rax2;rax3;raix0;raix1;raix2;raix3;apclii0;apclix0;apcliix0"
        datconf -f /etc/map/1905d.cfg set radio_band "24G;5G;5G"
        datconf -f /tmp/mtk/wifi/rtdev set radio_band "24G;5G;"
        datconf -f /tmp/mtk/wifi/2860 set Channel 36
        datconf -f /tmp/mtk/wifi/rtdev set Channel 6
        if [ "$MAP_R2" != "2" ]; then
                datconf -f /tmp/mtk/wifi/2860 set WirelessMode 14
                datconf -f /tmp/mtk/wifi/rtdev set WirelessMode 9
        else
                datconf -f /tmp/mtk/wifi/2860 set WirelessMode 23
                datconf -f /tmp/mtk/wifi/rtdev set WirelessMode 22
        fi
        datconf -f /tmp/mtk/wifi/2860 set HT_AMSDU 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_AMSDU 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /tmp/mtk/wifi/2860 set HT_AutoBA 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_AutoBA 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
        datconf -f /tmp/mtk/wifi/2860 set HT_BADecline 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_BADecline 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
        datconf -f /tmp/mtk/wifi/2860 set G_BAND_256QAM 0
        datconf -f /tmp/mtk/wifi/rtdev set G_BAND_256QAM 0
        #datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
        if [ "$MAP_R2" = "2" ]; then
        datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 4
        datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 4
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
        datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 4
        datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 4
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
        #if [ "$dev" = "25" ]; then
        #datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 2
        #datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 2
        #fi
        datconf -f /tmp/mtk/wifi/2860 set VHT_BW 1
        datconf -f /tmp/mtk/wifi/rtdev set VHT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
        datconf -f /tmp/mtk/wifi/2860 set HT_BW 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
        datconf -f /tmp/mtk/wifi/2860 set HT_LDPC 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
        datconf -f /tmp/mtk/wifi/2860 set VHT_LDPC 0
        datconf -f /tmp/mtk/wifi/rtdev set VHT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
        else
        datconf -f /tmp/mtk/wifi/2860 set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_TxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
        datconf -f /tmp/mtk/wifi/2860 set HT_RxStream 1
        datconf -f /tmp/mtk/wifi/rtdev set HT_RxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
        fi
	datconf -f /tmp/mtk/wifi/2860 set CountryRegionABand 13
        if [ "$MAP_R2" = "2" ]; then
                datconf -f /tmp/mtk/wifi/2860 WifiCert 1
                datconf -f /tmp/mtk/wifi/rtdev WifiCert 1
                #datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
        fi
        datconf -f /tmp/mtk/wifi/2860 set HT_BSSCoexistence 0
        datconf -f /tmp/mtk/wifi/rtdev set HT_BSSCoexistence 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
elif [ "$dev" = "26"  ];then
		echo "entered per sku config for eagle"
        bss_config_priority="ra0;ra1;ra2;ra3;apcli0;rai0;rai1;rai2;rai3;apclii0;rax0;rax1;rax2;rax3;apclix0"
        datconf -f /etc/map/1905d.cfg set radio_band "24G;5G;5G"
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set radio_band "24G;5G;"

	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set Channel 36
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set Channel 6

	    if [ "$MAP_R2" != "2" ]; then
                datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set WirelessMode 14
                datconf -f /etc/wireless/mediatek/mt7990.b0.dat set WirelessMode 9
        else
                datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set WirelessMode 17
                datconf -f /etc/wireless/mediatek/mt7990.b0.dat set WirelessMode 16
        fi
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_AMSDU 0
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_AMSDU 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_AutoBA 0
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_AutoBA 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_BADecline 1
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_BADecline 1
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set G_BAND_256QAM 0
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set G_BAND_256QAM 0
	#datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f  /etc/wireless/mediatek/$MT7990_B1_DAT set WscConfMode "4;4;4;4"
	datconf -f  /etc/wireless/mediatek/mt7990.b0.dat set WscConfMode "4;4;4;4"
	datconf -f  /etc/wireless/mediatek/$MT7990_B1_DAT set WscConfStatus "2;2;2;2"
	datconf -f  /etc/wireless/mediatek/mt7990.b0.dat set WscConfStatus "2;2;2;2"

	if [ "$MAP_R2" = "2" ]; then
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_TxStream 4
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_TxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_RxStream 4
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_RxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set VHT_BW 2
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set VHT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_BW 1
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set VHT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set VHT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
        else
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_TxStream 1
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_TxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_RxStream 1
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_RxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
        fi
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set DfsEnable 1
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set DfsDedicatedZeroWait 0
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set DfsZeroWaitDefault 0
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set CountryRegionABand 13
        if [ "$MAP_R2" = "2" ]; then
                datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT WifiCert 1
                datconf -f /etc/wireless/mediatek/mt7990.b0.dat WifiCert 1
                #datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
        fi
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set HT_BSSCoexistence 0
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set HT_BSSCoexistence 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
		echo "exiting per sku config for eagle"

elif [ "$dev" = "28"  ];then
		echo "entered per sku config for kite"
        bss_config_priority="ra0;ra1;ra2;ra3;apcli0;rai0;rai1;rai2;rai3;apclii0"
        datconf -f /etc/map/1905d.cfg set radio_band "24G;5G;5G"
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set radio_band "24G;5G;"

	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set Channel 36
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set Channel 6

	    if [ "$MAP_R2" != "2" ]; then
                datconf -f /etc/wireless/mediatek/mt7992.b1.dat set WirelessMode 14
                datconf -f /etc/wireless/mediatek/mt7992.b0.dat set WirelessMode 9
        else
                datconf -f /etc/wireless/mediatek/mt7992.b1.dat set WirelessMode 17
                datconf -f /etc/wireless/mediatek/mt7992.b0.dat set WirelessMode 16
        fi
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_AMSDU 0
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_AMSDU 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_AutoBA 0
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_AutoBA 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BADecline 1
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BADecline 1
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set G_BAND_256QAM 0
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set G_BAND_256QAM 0
	#datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f  /etc/wireless/mediatek/mt7992.b1.dat set WscConfMode "4;4;4;4"
	datconf -f  /etc/wireless/mediatek/mt7992.b0.dat set WscConfMode "4;4;4;4"
	datconf -f  /etc/wireless/mediatek/mt7992.b1.dat set WscConfStatus "2;2;2;2"
	datconf -f  /etc/wireless/mediatek/mt7992.b0.dat set WscConfStatus "2;2;2;2"

	if [ "$MAP_R2" = "2" ]; then
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_TxStream 4
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_TxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_RxStream 4
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_RxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set VHT_BW 2
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set VHT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BW 1
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set VHT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set VHT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
        else
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_TxStream 1
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_TxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_RxStream 1
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_RxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
        fi
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set DfsEnable 1
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set DfsDedicatedZeroWait 0
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set DfsZeroWaitDefault 0
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set CountryRegionABand 13
        if [ "$MAP_R2" = "2" ]; then
                datconf -f /etc/wireless/mediatek/mt7992.b1.dat WifiCert 1
                datconf -f /etc/wireless/mediatek/mt7992.b0.dat WifiCert 1
                #datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
        fi
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set HT_BSSCoexistence 0
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set HT_BSSCoexistence 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
		echo "exiting per sku config for kite"
elif [ "$dev" = "30" ];then
		echo "entered per sku config for griffin"
        bss_config_priority="ra0;ra1;ra2;ra3;apcli0;rai0;rai1;rai2;rai3;apclii0"
        datconf -f /etc/map/1905d.cfg set radio_band "24G;5G;5G"
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set radio_band "24G;5G;"

	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set Channel 36
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set Channel 6

	    if [ "$MAP_R2" != "2" ]; then
                datconf -f /etc/wireless/mediatek/mt7993.b1.dat set WirelessMode 14
                datconf -f /etc/wireless/mediatek/mt7993.b0.dat set WirelessMode 9
        else
                datconf -f /etc/wireless/mediatek/mt7993.b1.dat set WirelessMode 17
                datconf -f /etc/wireless/mediatek/mt7993.b0.dat set WirelessMode 16
        fi
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_AMSDU 0
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_AMSDU 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AMSDU 0
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_AutoBA 0
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_AutoBA 0
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_AutoBA 0
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BADecline 1
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BADecline 1
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_BADecline 1
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set G_BAND_256QAM 0
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set G_BAND_256QAM 0
	#datconf -f /tmp/mtk/wifi/wifi3 set G_BAND_256QAM 0
	datconf -f  /etc/wireless/mediatek/mt7993.b1.dat set WscConfMode "4;4;4;4"
	datconf -f  /etc/wireless/mediatek/mt7993.b0.dat set WscConfMode "4;4;4;4"
	datconf -f  /etc/wireless/mediatek/mt7993.b1.dat set WscConfStatus "2;2;2;2"
	datconf -f  /etc/wireless/mediatek/mt7993.b0.dat set WscConfStatus "2;2;2;2"

	if [ "$MAP_R2" = "2" ]; then
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_TxStream 4
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_TxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 4
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_RxStream 4
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_RxStream 4
	#datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 4
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set VHT_BW 2
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set VHT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_BW 2
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BW 1
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BW 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BW 2
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set VHT_LDPC 0
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set VHT_LDPC 0
        #datconf -f /tmp/mtk/wifi/wifi3 set VHT_LDPC 0
        else
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_TxStream 1
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_TxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_TxStream 1
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_RxStream 1
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_RxStream 1
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_RxStream 1
        fi
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set DfsEnable 1
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set DfsDedicatedZeroWait 0
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set DfsZeroWaitDefault 0
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set CountryRegionABand 13
        if [ "$MAP_R2" = "2" ]; then
                datconf -f /etc/wireless/mediatek/mt7993.b1.dat WifiCert 1
                datconf -f /etc/wireless/mediatek/mt7993.b0.dat WifiCert 1
                #datconf -f /tmp/mtk/wifi/wifi3 WifiCert 1
        fi
        datconf -f /etc/wireless/mediatek/mt7993.b1.dat set HT_BSSCoexistence 0
        datconf -f /etc/wireless/mediatek/mt7993.b0.dat set HT_BSSCoexistence 0
        #datconf -f /tmp/mtk/wifi/wifi3 set HT_BSSCoexistence 0
		echo "exiting per sku config for griffin"
fi



echo -e "----- ${RED}EasyMesh CERT SCRIPT BSS Config=$bss_config_priority ${NC} -----"
echo -e "----- ${RED}EasyMesh CERT SCRIPT DBDC=$DBDC_MODE ${NC} -----"
#Enable DBDC For SKU's
if [ "$DBDC_MODE" = "1" ];then
	datconf -f /tmp/mtk/wifi/2860 set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/rtdev set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 1
elif [ "$dev" = "17" ];then
	datconf -f /tmp/mtk/wifi/2860 set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/rtdev set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 0
elif [ "$dev" = "26" ];then
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set DBDC_MODE 0
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set DBDC_MODE 0
	#datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 0
elif [ "$dev" = "27" ];then
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set DBDC_MODE 0
        datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set DBDC_MODE 0
	datconf -f /etc/wireless/mediatek/mt7990.b2.dat set DBDC_MODE 0
elif [ "$dev" = "28" ];then
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set DBDC_MODE 0
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set DBDC_MODE 0
	#datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 0
elif [ "$dev" = "29" ];then
        datconf -f /etc/wireless/mediatek/mt7992.b0.dat set DBDC_MODE 0
        datconf -f /etc/wireless/mediatek/mt7992.b1.dat set DBDC_MODE 0
elif [ "$dev" = "30" ];then
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set DBDC_MODE 0
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set DBDC_MODE 0
	#datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 0
elif [ "$dev" = "31" ];then
		datconf -f /etc/wireless/mediatek/mt7993.b1.dat set DBDC_MODE 0
		datconf -f /etc/wireless/mediatek/mt7993.b0.dat set DBDC_MODE 0
	#datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 0
else
	datconf -f /tmp/mtk/wifi/2860 set DBDC_MODE 0
	datconf -f /tmp/mtk/wifi/rtdev set DBDC_MODE 0
	datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 0
fi

if [ "$dev" = "22" ];then
	datconf -f /tmp/mtk/wifi/2860 set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/rtdev set DBDC_MODE 0
	#datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 1
fi

if [ "$dev" = "23" -o "$dev" = "24" ];then
	datconf -f /tmp/mtk/wifi/2860 set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/rtdev set DBDC_MODE 1
	datconf -f /tmp/mtk/wifi/wifi3 set DBDC_MODE 1
fi

if [ "$Role" = "1" ];then
	if [ "$SDK_TYPE" = "OPENWRT" ];then
		datconf -f /etc/map/mapd_user.cfg set DeviceRole 1
	else
		datconf -f /tmp/mtk/wifi/2860 set DeviceRole 1
	fi
else
	if [ "$SDK_TYPE" = "OPENWRT" ];then
		datconf -f /etc/map/mapd_user.cfg set DeviceRole 2
	else
		datconf -f /tmp/mtk/wifi/2860 set DeviceRole 2
	fi
fi

#5) Configure the Lan and WAN Interfaces Per  Platform
echo -e "----- ${RED}EasyMesh CERT SCRIPT set LAN WAN Interface ${NC} -----" 
if [ "$PLATFORM" = MT7622 ];then
	datconf -f /tmp/mtk/wifi lan_inf_name set $LAN_INTF
	datconf -f /tmp/mtk/wifi br_inf_name set br-lan
	datconf -f /etc/map/mapd_user.cfg set lan_interface $LAN_INTF
	datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
	datconf -f /etc/map/1905d.cfg set lan $LAN_INTF

	elif [ "$PLATFORM" = MT7629 ];then
	datconf -f /tmp/mtk/wifi set lan_inf_name $LAN_INTF
	datconf -f /tmp/mtk/wifi set br_inf_name br-lan
	datconf -f /etc/map/mapd_user.cfg set lan_interface $LAN_INTF
	datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
	datconf -f /etc/map/1905d.cfg set lan $LAN_INTF

elif [ "$PLATFORM" = MT7915 ];then
	datconf -f /tmp/mtk/wifi/2860 set lan_inf_name $LAN_INTF
	datconf -f /tmp/mtk/wifi/2860 set br_inf_name br-lan
	datconf -f /etc/map/mapd_user.cfg set lan_interface $LAN_INTF
	datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
	datconf -f /etc/map/1905d.cfg set lan $LAN_INTF

elif [ "$PLATFORM" = MT7986 ];then
	datconf -f /tmp/mtk/wifi/2860 set lan_inf_name $LAN_INTF
	datconf -f /tmp/mtk/wifi/2860 set br_inf_name br-lan
	datconf -f /etc/map/mapd_user.cfg set lan_interface $LAN_INTF
	datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
	datconf -f /etc/map/1905d.cfg set lan $LAN_INTF

elif [ "$PLATFORM" = MT7988 ];then
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set lan_inf_name "$LAN_INTF"
        datconf -f /etc/wireless/mediatek/mt7990.b0.dat set br_inf_name br-lan
        datconf -f /etc/map/mapd_user.cfg set lan_interface "$LAN_INTF"
        datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
        datconf -f /etc/map/1905d.cfg set lan "$LAN_INTF"
elif [" $PLATFORM" = MT7992 ]; then
		if [ "$dev" = "29" ]; then
			datconf -f /etc/wireless/mediatek/mt7992.b0.dat set lan_inf_name "$LAN_INTF"
			datconf -f /etc/wireless/mediatek/mt7992.b0.dat set br_inf_name br-lan
			datconf -f /etc/map/mapd_user.cfg set lan_interface "$LAN_INTF"
			datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
			datconf -f /etc/map/1905d.cfg set lan "$LAN_INTF"
		fi
elif [" $PLATFORM" = MT7993 ]; then
		if [ "$dev" = "31" ]; then
			datconf -f /etc/wireless/mediatek/mt7993.b0.dat set lan_inf_name "$LAN_INTF"
			datconf -f /etc/wireless/mediatek/mt7993.b0.dat set br_inf_name br-lan
			datconf -f /etc/map/mapd_user.cfg set lan_interface "$LAN_INTF"
			datconf -f /etc/map/mapd_user.cfg set wan_interface $WAN_INTF
			datconf -f /etc/map/1905d.cfg set lan "$LAN_INTF"
		fi
elif [ "$PLAFORM" = MT7621 ];then
	if ["$SDK_TYPE" = LSDK ]; then
		nvram_set lan_inf_name $LAN_INTF
		nvram_set br_inf_name br0
	else
		nvram_set lan_inf_name $LAN_INTF
		nvram_set br_inf_name br-lan
	fi
fi

#6) Configure IP Address
echo -e "----- ${RED}EasyMesh CERT SCRIPT Configure IP Address  ${NC} -----" 
if [ "$SDK_TYPE" = "OPENWRT" ];then
uci set dhcp.lan.ignore='1'
uci set firewall.@zone[1].input='ACCEPT'
uci set firewall.@zone[1].forward='ACCEPT'
uci set network.wan6.proto='static'
uci set network.wan.proto='static'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.165.100.200'
uci set network.lan.netmask='255.255.255.0'
uci set network.wan.ipaddr='192.168.250.200'
uci set network.wan.netmask='255.255.255.0'
if [ "$Role" = "1" ];then
	#Controller
	echo -e "----- config CONTROLLER ip address -----" 
	uci set network.lan.ipaddr='192.165.100.101'
	uci set network.lan.netmask='255.255.255.0'
	uci set network.wan.ipaddr='192.168.250.201'
	uci set network.wan.netmask='255.255.255.0'
elif [ "$Role" = "2" ];then
	#Agent1
	echo -e "----- config AGENT1 ip address -----" 
	uci set network.lan.ipaddr='192.165.100.102'
	uci set network.lan.netmask='255.255.255.0'
	uci set network.wan.ipaddr='192.168.250.202'
	uci set network.wan.netmask='255.255.255.0'
elif [ "$Role" = "3" ];then
	#Agent2
	echo -e "----- config AGENT2 ip address -----" 
	uci set network.lan.ipaddr='192.165.100.103'
	uci set network.lan.netmask='255.255.255.0'
	uci set network.wan.ipaddr='192.168.250.203'
	uci set network.wan.netmask='255.255.255.0'
elif [ "$Role" = "4" ];then
	echo -e "----- config DUT ip address -----" 
	uci set network.lan.ipaddr='192.165.100.104'
	uci set network.lan.netmask='255.255.255.0'
	uci set network.wan.ipaddr='192.168.250.204'
	uci set network.wan.netmask='255.255.255.0'
else
	echo -e "----- not change ip address -----"
fi
uci commit
fi

if [ "$SDK_TYPE" = "LSDK" ];then
	nvram_set map_agent_alid $al_mac
	nvram_set map_controller_alid $al_mac
	nvram_set wan_ipaddr 192.168.250.200
	nvram_set lan_ipaddr 192.165.100.200
	datconf -f /tmp/mtk/wifi/2860 set BSS_CONFIG_PRIORITY $bss_config_priority
fi
#7) Configuration for map_cfg.txt and mapd_cfg.txt
echo -e "----- ${RED}EasyMesh CERT SCRIPT Configure map_cfg.txt and mapd_cfg.txt  ${NC} -----" 
if [ "$SDK_TYPE" = "OPENWRT" ];then
datconf -f /etc/map/1905d.cfg set lan "$LAN_INTF"
datconf -f /etc/map/1905d.cfg set bss_config_priority $bss_config_priority
datconf -f /etc/map/mapd_default.cfg set bss_config_priority $bss_config_priority
datconf -f /etc/map/mapd_default.cfg set MapEnable 1
datconf -f /etc/map/mapd_default.cfg set lan_interface "$LAN_INTF"
datconf -f /etc/map/mapd_default.cfg set wan_interface $WAN_INTF
datconf -f /etc/map/mapd_default.cfg set BandSwitchTime 0
datconf -f /etc/map/mapd_default.cfg set AutoBHSwitching 0
datconf -f /etc/map/mapd_default.cfg set ChPlanningEnable 0
datconf -f /etc/map/mapd_default.cfg set ChPlanningEnableR2 0
datconf -f /etc/map/mapd_default.cfg set NetworkOptimizationEnabled 0
datconf -f /etc/map/mapd_default.cfg set DhcpCtl 0
datconf -f /etc/map/1905d.cfg set config_agent_port 9008
datconf -f /etc/wapp_ap_wlan0.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_ra0.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_rai0.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_rax0.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_wlan0_default.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_ra0_default.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_rai0_default.conf set gas_cb_delay 0
datconf -f /etc/wapp_ap_rax0_default.conf set gas_cb_delay 0
datconf -f /etc/map/mapd_default.cfg set CentralizedSteering 0
datconf -f /etc/mapd_strng.conf set Btm_Retry_Time 0
fi

if [ "$MAP_R2" = "2" ]; then
datconf -f /etc/map/1905d.cfg set map_ver R3
elif [ "$MAP_R2" = "1" ]; then
datconf -f /etc/map/1905d.cfg set map_ver R2
else
datconf -f /etc/map/1905d.cfg set map_ver R1
fi

if [ "$SDK_TYPE" = "LSDK" ];then
datconf -f /tmp/mtk/wifi/2860 set MapEnable 1
datconf -f /tmp/mtk/wifi/2860 set AutoBHSwitch 0
datconf -f /tmp/mtk/wifi/2860 set BandSwitchTime 0
datconf -f /tmp/mtk/wifi/2860 set ChPlanningEnable 0
fi
#8) Configuration for dpp_cfg.txt file
if [ "$Role" = "4" ];then
	#Agent1
	echo -e "----- DUT dpp cfg -----" 
	datconf -f /etc/dpp_cfg.txt set dpp_private_key 30770201010420450b7151e660bd695ee84597be3af83e2808563cb979a13e0adbb9c592a5b2dda00a06082a8648ce3d030107a1440342000452d5cfd47ec745ff20e2faf79f2dfd2ceb2dde688a8d4647fde65972dedf0aaee8da5d353a0b2d8bc98c757f318398bf7be1a4e706c6eb8d67ea053ffe3613b8
	datconf -f /etc/dpp_cfg.txt set curve_name prime256v1
	datconf -f /etc/dpp_cfg.txt set allowed_role 1
	datconf -f /etc/dpp_cfg.txt set map_support 1
	datconf -f /etc/dpp_cfg.txt set dpp_interface_2g ra0
	datconf -f /etc/dpp_cfg.txt set dpp_interface_5gl rax0
	datconf -f /etc/dpp_cfg.txt set dpp_interface_5gh rai0
fi

if [ "$Role" = "1" ];then
        #Controller
        echo -e "----- Controller dpp cfg -----"
        datconf -f /etc/dpp_cfg.txt set dpp_private_key 307702010104206de64a0e34d32b617c1c94f1f3dcea123759f5889c59b7e52f809895745b7413a00a06082a8648ce3d030107a14403420004114b5f4b7ad21d0efd4bddfd45741fdd1a7e959671777a79107b1484c102bd3beb57ec0b36fd98e2b4b902c5285df9c18d8418452c59ce68703ab9d77ea853ef
        datconf -f /etc/dpp_cfg.txt set curve_name prime256v1
        datconf -f /etc/dpp_cfg.txt set configurator_support 1
        datconf -f /etc/dpp_cfg.txt set allowed_role 2
        datconf -f /etc/dpp_cfg.txt set map_support 1
        datconf -f /etc/dpp_cfg.txt set dpp_interface_2g ra0
        datconf -f /etc/dpp_cfg.txt set dpp_interface_5gl rax0
        datconf -f /etc/dpp_cfg.txt set dpp_interface_5gh rai0
fi

#for 6G interface down in MAP cert
if [  "$dev" = "23" ]; then
	datconf -f /etc/map/mapd_default.cfg set Cert_6G 0
fi

if [  "$dev" = "26" ]; then
	datconf -f /etc/map/mapd_default.cfg set Cert_6G 0
	cp /etc/wireless_cert /etc/config/wireless
	wifi save
fi
if [  "$dev" = "27" ]; then
	datconf -f /etc/map/mapd_default.cfg set Cert_6G 1
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7990.b2.dat set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7990.b2.dat set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/mt7990.b2.dat set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/mt7990.b0.dat set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/wireless/mediatek/$MT7990_B1_DAT set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7990.b2.dat set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/map/mapd_default.cfg set BH_AKM "000FAC02;000FAC08;000FAC24;506F9A02"
	datconf -f /etc/map/mapd_default.cfg set FH_AKM "000FAC00;000FAC02;000FAC08;000FAC24"
	cp /etc/wireless_cert_be /etc/config/wireless
	wifi save
fi
if [  "$dev" = "29" ]; then
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/mt7992.b0.dat set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7992.b1.dat set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/map/mapd_default.cfg set BH_AKM "000FAC02;000FAC08;000FAC24;506F9A02"
	datconf -f /etc/map/mapd_default.cfg set FH_AKM "000FAC00;000FAC02;000FAC08;000FAC24"
	cp /etc/wireless_cert_be_dual_band /etc/config/wireless
	uci delete wireless.rax0
	uci delete wireless.apclix0
	uci delete wireless.MT7990_1_3
	uci commit
	sed -i 's/7990/7992/g' /etc/config/wireless
	uci commit
	cp /etc/config/wireless /etc/wireless_cert
	wifi save
fi
if [  "$dev" = "28" ]; then
	#kite support 2G:5G so delete 6G related conf from file
	cp /etc/wireless_cert /etc/config/wireless
	uci delete wireless.rax0
	uci delete wireless.apclix0
	uci delete wireless.MT7990_1_3
	uci commit
	sed -i 's/7990/7992/g' /etc/config/wireless
	uci commit
	cp /etc/config/wireless /etc/wireless_cert
    wifi save
fi
if [  "$dev" = "31" ]; then
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set EHT_ApEmlsr_mr "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set EHT_ApScsTraffic "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set EHT_MaxMcs "9;9;9;9"
	datconf -f /etc/wireless/mediatek/mt7993.b0.dat set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/wireless/mediatek/mt7993.b1.dat set EHT_ApT2lmNegoSupport "1;1;1;1"
	datconf -f /etc/map/mapd_default.cfg set BH_AKM "000FAC02;000FAC08;000FAC24;506F9A02"
	datconf -f /etc/map/mapd_default.cfg set FH_AKM "000FAC00;000FAC02;000FAC08;000FAC24"
	cp /etc/wireless_cert_be_dual_band_gg /etc/config/wireless
	uci delete wireless.rax0
	uci delete wireless.apclix0
	uci delete wireless.MT7993_1_3
	uci commit
	sed -i 's/7990/7993/g' /etc/config/wireless
	uci commit
	cp /etc/config/wireless /etc/wireless_cert
	wifi save
fi

if [  "$dev" = "30" ]; then
	#griffin support 2G:5G so delete 6G related conf from file
	cp /etc/wireless_cert /etc/config/wireless
	uci delete wireless.rax0
	uci delete wireless.apclix0
	uci delete wireless.MT7990_1_3
	uci commit
	sed -i 's/7990/7993/g' /etc/config/wireless
	uci commit
	cp /etc/config/wireless /etc/wireless_cert
    wifi save
fi


reboot
