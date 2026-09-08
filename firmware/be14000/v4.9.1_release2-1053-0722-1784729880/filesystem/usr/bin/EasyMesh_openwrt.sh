#!/bin/sh

RED='\033[0;31m'
NC='\033[0m'
echo -e "----- ${RED}EasyMesh SCRIPT${NC} -----"
check_default="$1"
isAX7800="0"
isLogan="0"
isBellwether="0"
isEagle="0"
PHY_11AX_6G="18"
PHY_11AX_6G_EAGLE="24"
perportpervlan="$1"
mode="$2"
sw_arch="DSA"
isEagleDualband="0"

if [ -n "$mode" ]
then
	echo "input param2 is $mode"
else
	mode="0"
	echo "input param2 is null, set mode as router mode, mode=$mode"
fi

echo "param1 perportpervlan=$perportpervlan"
echo "param1  0--> disable perportpervlan"
echo "param1  1--> enable perportpervlan"
echo "param2 mode=$mode"
echo "param2  0--> router mode on dev"
echo "param2  1--> bridge mode on dev"

ramips_board_name() {
	echo "####ramips_board_name####"
	local name

	[ -f /tmp/sysinfo/board_name ] && name=$(cat /tmp/sysinfo/board_name)
	[ -z "$name" ] && name="unknown"

	echo "${name%-[0-9]*M}"
}

board=$(ramips_board_name)
platform=${board:0:6}
echo "##################################$platform"

get_switch_arch() {
	echo "####get_switch_arch####"
	local sw_reg

	if [ -f "/proc/air_sw/device" ]; then
		sw_reg=`switch an8855 reg r 10208a10 | awk -F = '{print $3}'`
		if [ -z $sw_reg -o "$sw_reg" != "0x920" ]; then
			sw_arch="GSW"
			echo "AN8855 GSW"
		else
			sw_arch="DSA"
			echo "AN8855 DSA"
		fi
	else
		sw_reg=`switch reg r 2610 | awk -F = '{print $3}'`
		echo "switch reg r 2610: [$sw_reg]"
		sw_reg_len=`echo ${#sw_reg}`
		echo "len : $sw_reg_len"
		sw_reg=${sw_reg:$sw_reg_len-2:1}
		echo "get bit 4 - bit 7: ["$sw_reg"]"
		#bit5=1 dsa bit5=0 gsw
		if [ "$sw_reg" == "2" -o "$sw_reg" == "3" -o "$sw_reg" == "6" -o "$sw_reg" == "7" ] ||
		   [ "$sw_reg" == "a" -o "$sw_reg" == "b" -o "$sw_reg" == "e" -o "$sw_reg" == "f" ]
		then
			sw_arch="DSA"
		else
			sw_arch="GSW"
		fi
	fi
	if [ $sw_arch == "DSA" ]; then
		echo "SWITCH DSA ARCH"
	else
		echo "SWITCH GSW ARCH"
	fi
}

clean()
{
	echo "####clean####"
	rm -rf /tmp/wapp_ctrl
	killall -15 mapd
	killall -2 wapp
	killall -15 p1905_managerd
	killall -15 bs20
	sleep 5
	rmmod mapfilter
	echo -e "----- ${RED}killed all apps ${NC} -----"
}
#call routine to decide operating mode
get_operating_mode()
{
	echo "####get_operating_mode####"
	if [ $isLogan == "1" -a  $isEagle == "1" ];
	then
	card0_initial_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
        card0_profile_path=`cat ${card0_initial_profile_path} | grep BN0_profile_path |awk -F "[=;]" '{ print $2 }'`
	else
	card0_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
	fi

	echo "card0 profile path=$card0_profile_path"
	#MapEnable=`cat ${card0_profile_path} | grep MapEnable | awk -F "=" '{ print $2 }'`
	#MapTurnKey=`cat ${card0_profile_path} | grep MAP_Turnkey | awk -F "=" '{ print $2 }'`
	#BSEnable=`cat ${card0_profile_path} | grep BSEnable | awk -F "=" '{ print $2 }'`
	MapMode=`cat ${card0_profile_path} | grep MapMode | awk -F "=" '{ print $2 }'`
	echo "MapMode=${MapMode}"
	LastMapMode=`cat /etc/map/mapd_default.cfg | grep LastMapMode | awk -F "=" '{ print $2 }'`
	if [ -z ${LastMapMode} ]
	then
	echo "fist start init last_map_mode ${MapMode}"
	LastMapMode="${MapMode}"
	fi
	echo "update last_map_mode ${MapMode}"
	sed -i "s/LastMapMode=.*/LastMapMode=${MapMode}/g" /etc/map/mapd_default.cfg
}
#Function reads interface name from the l1profile
prepare_ifname_card()
{
	echo "####prepare_ifname_card####"
	echo "card_idx=$card_idx"
        if [ $isLogan == "1" -a  $isEagle == "1" ];
        then
        card_initial_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
        card_profile_path=`cat ${card_initial_profile_path} | grep BN${card_idx}_profile_path |awk -F "[=;]" '{ print $2 }'`
		if [ $card_idx == "0" ];
		then
		card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $2 }'`
		card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $2 }'`
		card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $2 }'`
		fi

                if [ $card_idx == "1" ];
                then
                card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $3 }'`
                card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $3 }'`
                card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $3 }'`
                fi

                if [ $card_idx == "2" ];
                then
					if [ "$isEagleDualband" == "1" ]; then
					card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $3 }'`
					card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $3 }'`
					card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $3 }'`
					else
					card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $4 }'`
					card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $4 }'`
					card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $4 }'`
				fi
				fi
	else
	card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |awk -F "=" '{ print $2 }'`
	card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |awk -F "=" '{ print $2 }'`
        card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |awk -F "=" '{ print $2 }'`
	card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname |awk -F "=" '{ print $2 }'`
fi
	echo "card_profile_path=$card_profile_path"
	echo "card_ext_ifname=$card_ext_ifname"
	echo "card_apcli_ifname=$card_apcli_ifname"
	echo "card_main_ifname=$card_main_ifname"

	card_bssid_num=`cat ${card_profile_path} | grep BssidNum | awk -F "=" '{ print $2 }'`
	echo "card_bssid_num $card_bssid_num"
	iwconfig ${card_main_ifname} | grep "Access Point"
	card_exist=$?
	echo "card_exist=$card_exist"
	ifconfig | grep "br" > br_name
	bridge_name=`cat br_name | awk '{ print $1}'`
	if [ $card_exist == 0 ]
	then
		active_cards=`expr $active_cards + 1`
		bssid_num=0
		while [ $bssid_num -lt $card_bssid_num ]
		do
			if [ -z ${if_list} ]
			then
			if_list="${card_ext_ifname}${bssid_num}"
			else
			if_list="${if_list};${card_ext_ifname}${bssid_num}"
			fi
			brctl delif $bridge_name $card_ext_ifname$bssid_num
			brctl addif $bridge_name $card_ext_ifname$bssid_num
			bssid_num=`expr $bssid_num + 1`
		done
		if_list="${if_list};${card_apcli_ifname}0"
		echo ${card_main_ifname} >> main_ifname
		echo ${card_apcli_ifname}"0" >> apcli_ifname
		brctl delif $bridge_name $card_apcli_ifname"0"
		brctl addif $bridge_name $card_apcli_ifname"0"
	fi
	echo "if_list=$if_list"
}
prepare_ifame_band()
{
	echo "####prepare_ifame_band####"
	card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |awk -F "[=;]" '{ print $2 }'`
	echo "card_ext_ifname=$card_ext_ifname"
	card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |awk -F "[=;]" '{ print $2 }'`
	echo "card_profile_path=$card_profile_path"
	card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |awk -F "[=;]" '{ print $2 }'`
	echo "card_apcli_ifname=$card_apcli_ifname"
	card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname |awk -F "[=;]" '{ print $2 }'`
	card_bssid_num=`cat ${card_profile_path} | grep BssidNum | awk -F "=" '{ print $2 }'`
	echo "card_bssid_num=$card_bssid_num"
	iwconfig ${card_main_ifname} | grep "Access Point"
	card_exist=$?
	echo $card_exist
	ifconfig | grep "br" > br_name
	bridge_name=`cat br_name | awk '{ print $1}'`
	if [ $card_exist == 0 ]
	then
		active_cards=`expr $active_cards + 1`
		bssid_num=0
		while [ $bssid_num -lt $card_bssid_num ]
		do
			if [ -z ${if_list} ]
			then
				if_exist=`ifconfig | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					if_list="${card_ext_ifname}${bssid_num}"
					interface_available=$card_ext_ifname
				fi
			else
				if_exist=`ifconfig | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					if_list="${if_list};${card_ext_ifname}${bssid_num}"
					interface_available=$card_ext_ifname
				fi
			fi
			brctl delif $bridge_name $card_ext_ifname$bssid_num
			brctl addif $bridge_name $card_ext_ifname$bssid_num
			bssid_num=`expr $bssid_num + 1`
		done
		if [ $interface_available == $card_ext_ifname ]; then
			if_list="${if_list};${card_apcli_ifname}0"
			echo ${card_main_ifname} >> main_ifname
			echo ${card_apcli_ifname}"0" >> apcli_ifname
		fi
		brctl delif $bridge_name $card_apcli_ifname"0"
		brctl addif $bridge_name $card_apcli_ifname"0"
	fi
	echo "if_list=$if_list"
	card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |awk -F "[=;]" '{ print $3 }'`
	echo "card_ext_ifname=$card_ext_ifname"
        card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |awk -F "[=;]" '{ print $3 }'`
	echo "card_profile_path=$card_profile_path"
	card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |awk -F "[=;]" '{ print $3 }'`
	echo "card_apcli_ifname=$card_apcli_ifname"
	card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname |awk -F "[=;]" '{ print $3 }'`
	card_bssid_num=`cat ${card_profile_path} | grep BssidNum | awk -F "=" '{ print $2 }'`
	echo "card_bssid_num=$card_bssid_num"
	iwconfig ${card_main_ifname} | grep "Access Point"
	card_exist=$?
	echo $card_exist
	if [ $card_exist == 0 ]
	then
		active_cards=`expr $active_cards + 1`
		bssid_num=0
		while [ $bssid_num -lt $card_bssid_num ]
		do
			if [ -z ${if_list} ]
			then
				if_exist=`ifconfig | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					if_list="${card_ext_ifname}${bssid_num}"
					interface_available=$card_ext_ifname
				fi
			else
				if_exist=`ifconfig | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					if_list="${if_list};${card_ext_ifname}${bssid_num}"
					interface_available=$card_ext_ifname
				fi
			fi
			brctl delif $bridge_name $card_ext_ifname$bssid_num
			brctl addif $bridge_name $card_ext_ifname$bssid_num
			bssid_num=`expr $bssid_num + 1`
		done
		if [ $interface_available == $card_ext_ifname ]; then
			if_list="${if_list};${card_apcli_ifname}0"
			echo ${card_main_ifname} >> main_ifname
			echo ${card_apcli_ifname}"0" >> apcli_ifname
		fi
		brctl delif $bridge_name $card_apcli_ifname"0"
		brctl addif $bridge_name $card_apcli_ifname"0"
	fi
	echo "if_list=$if_list"
}
prepare_bh_priority_card_if_list()
{
	echo "####prepare_bh_priority_card_if_list####"
        echo "card_idx=$card_idx"
        if [ $isLogan == "1" -a  $isEagle == "1" ];
        then
        card_initial_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
        card_profile_path=`cat ${card_initial_profile_path} | grep BN${card_idx}_profile_path |awk -F "[=;]" '{ print $2 }'`

                if [ $card_idx == "0" ];
                then
                card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $2 }'`
                card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $2 }'`
                card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $2 }'`
                fi

                if [ $card_idx == "1" ];
                then
                card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $3 }'`
                card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $3 }'`
                card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $3 }'`
                fi

                if [ $card_idx == "2" ];
                then
					if [ "$isEagleDualband" == "1" ]; then
					card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $3 }'`
					card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $3 }'`
					card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $3 }'`
					else
					card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |awk -F "[=;]" '{ print $4 }'`
					card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |awk -F "[=;]" '{ print $4 }'`
					card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $4 }'`
				fi
				fi
        else
        card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |awk -F "=" '{ print $2 }'`
        card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |awk -F "=" '{ print $2 }'`
        card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |awk -F "=" '{ print $2 }'`
        card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname |awk -F "=" '{ print $2 }'`
fi
        echo "card_profile_path=$card_profile_path"
        echo "card_ext_ifname=$card_ext_ifname"
        echo "card_apcli_ifname=$card_apcli_ifname"
        echo "card_main_ifname=$card_main_ifname"

	card_bssid_num=`cat ${card_profile_path} | grep BssidNum | awk -F "=" '{ print $2 }'`
	echo "card_bssid_num=$card_bssid_num"
	iwconfig ${card_main_ifname} | grep "Access Point"
	card_exist=$?
	echo $card_exist
	if [ $card_exist == 0 ]
	then
		bssid_num=0
		while [ $bssid_num -lt $card_bssid_num ]
		do
			if [ -z ${bh_priority_list} ]
			then
				if_exist=`ifconfig -a | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					bh_priority_list="${card_ext_ifname}${bssid_num}"
				fi
			else
				if_exist=`ifconfig -a | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					bh_priority_list="${bh_priority_list};${card_ext_ifname}${bssid_num}"
				fi
			fi
			bssid_num=`expr $bssid_num + 1`
		done
		bh_priority_list="${bh_priority_list};${card_apcli_ifname}0"
	fi
	echo "bh_priority_list=$bh_priority_list"
}

prepare_bh_priority_if_list()
{
	echo "####prepare_bh_priority_if_list####"
	card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |awk -F "[=;]" '{ print $2 }'`
	echo "card_ext_ifname=$card_ext_ifname"
        card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |awk -F "[=;]" '{ print $2 }'`
	echo "card_profile_path=$card_profile_path"
	card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |awk -F "[=;]" '{ print $2 }'`
	echo "card_apcli_ifname=$card_apcli_ifname"
	card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname |awk -F "[=;]" '{ print $2 }'`
	card_bssid_num=`cat ${card_profile_path} | grep BssidNum | awk -F "=" '{ print $2 }'`
	echo "card_bssid_num=$card_bssid_num"
	iwconfig ${card_main_ifname} | grep "Access Point"
	card_exist=$?
	echo $card_exist
	if [ $card_exist == 0 ]
	then
		bssid_num=0
		while [ $bssid_num -lt $card_bssid_num ]
		do
			if [ -z ${bh_priority_list} ]
			then
				if_exist=`ifconfig -a | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					bh_priority_list="${card_ext_ifname}${bssid_num}"
				fi
			else
				if_exist=`ifconfig -a | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					bh_priority_list="${bh_priority_list};${card_ext_ifname}${bssid_num}"
				fi
			fi
			bssid_num=`expr $bssid_num + 1`
		done
		bh_priority_list="${bh_priority_list};${card_apcli_ifname}0"
	fi
	echo $bh_priority_list
	card_ext_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |awk -F "[=;]" '{ print $3 }'`
	echo $card_ext_ifname
        card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |awk -F "[=;]" '{ print $3 }'`
	echo $card_profile_path
	card_apcli_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |awk -F "[=;]" '{ print $3 }'`
	echo $card_apcli_ifname
	card_main_ifname=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname |awk -F "[=;]" '{ print $3 }'`
	card_bssid_num=`cat ${card_profile_path} | grep BssidNum | awk -F "=" '{ print $2 }'`
	echo $card_bssid_num
	iwconfig ${card_main_ifname} | grep "Access Point"
	card_exist=$?
	echo $card_exist
	if [ $card_exist == 0 ]
	then
		bssid_num=0
		while [ $bssid_num -lt $card_bssid_num ]
		do
			if [ -z ${bh_priority_list} ]
			then
				if_exist=`ifconfig -a | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					bh_priority_list="${card_ext_ifname}${bssid_num}"
				fi
			else
				if_exist=`ifconfig -a | grep ${card_ext_ifname}${bssid_num}`
				if [ "$if_exist" != "" ]; then
					bh_priority_list="${bh_priority_list};${card_ext_ifname}${bssid_num}"
				fi
			fi
			bssid_num=`expr $bssid_num + 1`
		done
		bh_priority_list="${bh_priority_list};${card_apcli_ifname}0"
	fi
	echo $bh_priority_list
}

get_platform()
{
	echo "####get_platform####"
	card1=`cat /etc/wireless/l1profile.dat | grep INDEX0= | awk -F "=" '{ print $2 }'`
	card2=`cat /etc/wireless/l1profile.dat | grep INDEX1= | awk -F "=" '{ print $2 }'`
	echo "card1=$card1"
	echo "card2=$card2"
	if [ "$card1" != "" -a "$card2" != "" ]
	then
		if [ "$card1" = "MT7986" -a "$card2" = "MT7916" ];
		then
			echo "Its AX7800"
			isAX7800=1
		fi

		if [ "$card1" = "MT7902" -a "$card2" = "MT7902" ];
                then
                        echo "Its Bellwether Logan"
			isBellwether=1
                        isLogan=1
                fi
	fi
	if [ "$card1" != "" -a "$card2" = "" ];
        then
		if [ "$card1" = "MT7990" -o "$card1" = "MT7992" -o "$card1" = "MT7993" ];
		then
			echo "Its Eagle Logan"
			isEagle=1
			isLogan=1
		fi
	fi

	if [ $isLogan == "1" -a  $isEagle == "1" ]; then
		main_iface_num=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname | cut -d '=' -f 2 | awk -F ';' '{print NF}'`

		card_initial_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
		profile_num=`cat ${card_initial_profile_path} | grep profile_path |wc -l`
		band1_profile_exist=`cat ${card_initial_profile_path} | grep BN1_profile_path`

		if [ "$main_iface_num" -eq "2" -a "$profile_num" -eq "2" -a -z "$band1_profile_exist" ]; then
			isEagleDualband="1"
		fi
	fi
}

prepare_ifname()
{
	echo "####prepare_ifname####"
	card_idx=0
	active_cards=0
	rm -rf apcli_ifname main_ifname

	if [ $isLogan == "1" -a  $isEagle == "1" ];
        then
       	 while [ $card_idx -le 3 ]
         do
		card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
		card=`cat ${card_profile_path} | grep BN${card_idx}_profile_path |awk -F "[=;]" '{ print $2 }'`
                echo "card=$card"
                if [ -z "$card" ]
                then
                        echo "No card"
                else
                        dbdc_detect=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname= | awk -F ";" '{ print $2 }'`
                                prepare_ifname_card
                                prepare_bh_priority_card_if_list
                fi
                card_idx=`expr $card_idx + 1`
        done
	else
	while [ $card_idx -le 2 ]
	do
		card=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}= | awk -F "=" '{ print $2 }'`
		echo "card=$card"
		if [ -z "$card" ]
		then
			echo "No card"
		else
			dbdc_detect=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname= | awk -F ";" '{ print $2 }'`
                        if [ -z "$dbdc_detect" ]
                        then
                                prepare_ifname_card
                                prepare_bh_priority_card_if_list
                        else
                                echo "dbdc detected"
                                prepare_ifame_band
                                prepare_bh_priority_if_list
                        fi
                fi
                card_idx=`expr $card_idx + 1`
        done
fi
	lan_ifname=`uci get network.lan.device`
	echo "lan_ifname=$lan_ifname"
	for i in 0 1 2
	do
		tmp_name=`uci get network.@device[$i].name`
		echo "tmp_name=$tmp_name"
		if [ "$lan_ifname" = "$tmp_name" ]; then
			lan_iface=`uci get network.@device[$i].ports`
			echo "lan_iface=$lan_iface"
		break
		fi
	done
}
#call routine for SDK specific config preparation(ra_band/ bh_priority etc)
prepare_platform_variables_eagle()
{
	echo "####prepare_platform_variables_eagle####"
	card_idx=0
	is6G=0
	is6GBE=0

	lan_iface=`uci get network.@device[0].ports`
	wan_iface=`uci get network.wan.device`
	echo "got lan_iface: $lan_iface"
	echo "got wan_iface: $wan_iface"

	while [ $card_idx -le 3 ]
	do
		card_initial_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX0_profile_path |awk -F "[=;]" '{ print $2 }'`
		card_profile_path=`cat ${card_initial_profile_path} | grep BN${card_idx}_profile_path |awk -F "[=;]" '{ print $2 }'`

		echo "$card"
		if [ -z "$card_profile_path" ]
		then
			echo "No card"
		else
			echo "Card Exists"
			card_wireless_num=`cat ${card_profile_path} | grep -w WirelessMode | awk -F "=" '{ print $2 }'`
			card_wireless_num=` echo $card_wireless_num | awk -F ";" '{print $1}'`
			if [ $card_wireless_num = $PHY_11AX_6G_EAGLE -o $card_wireless_num = $PHY_11AX_6G ]
			then
				is6G=1
			fi

			if [ $card_wireless_num -gt $PHY_11AX_6G ]
                        then
                                is6GBE=1
			fi

			if [ $is6G == "1" -a $isEagle == "1" ]
			then
				apcli_6G=`cat /etc/wireless/l1profile.dat | grep INDEX0_apcli_ifname |
					awk -F "[=;]" '{ print $4 }'`
				ra_6G=`cat /etc/wireless/l1profile.dat | grep INDEX0_ext_ifname |
					 awk -F "[=;]" '{ print $4 }'`
			fi
		fi
		card_idx=`expr $card_idx + 1`
	done

	echo "is6G $is6G card_wireless_num $card_wireless_num isAX7800 $isAX7800 isEagle $isEagle active_cards $active_cards"

	if [ $active_cards == "2" -a $is6G == "0" ]
	then
		radio_band="24G;5G;5G"
	elif [ $active_cards == "2" -a $is6G == "1" ]
	then
		radio_band="24G;6G"
	elif [ $active_cards == "3" -a $is6G == "0" ]
	then
		radio_band="24G;5GH;5GL"
	elif [ $active_cards == "3" -a $is6G == "1" ]
	then
		radio_band="24G;5G;6G"
	elif [ $active_cards == "4" -a $is6G == "1" -a $isAX7800 == "1" ]
	then
		radio_band="24G;5G;6G"
	elif [ $active_cards == "4" -a $is6G == "0" -a $isAX7800 == "1" ]
	then
		radio_band="24G;5GH;5GL"
	elif [ $active_cards == "4" -a $is6G == "1" -a $isEagle == "1" ]
	then
		radio_band="24G;5G;6G"
	elif [ $active_cards == "4" -a $is6G == "0" -a $isEagle == "1" ]
	then
		radio_band="24G;5GH;5GL"
	fi
	wan_iface=`uci get network.wan.device`
}

#call routine for SDK specfic config preparation(ra_band/ bh_priority etc)
prepare_platform_variables()
{
	echo "####prepare_platform_variables####"
	card_idx=0
	is6G=0
	while [ $card_idx -le 2 ]
	do
		card=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}= | awk -F "=" '{ print $2 }'`
		echo "$card"
		if [ -z "$card" ]
		then
			echo "No card"
		else
			echo "Card Exists"
			dbdc_detect=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_main_ifname= | awk -F ";" '{ print $2 }'`

			if [ -z "$dbdc_detect" ]
			then
				card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |
					awk -F "[=;]" '{ print $2 }'`
				card_wireless_num=`cat ${card_profile_path} | grep -w WirelessMode | awk -F "=" '{ print $2 }'`
				card_wireless_num=` echo $card_wireless_num | awk -F ";" '{print $1}'`
				if [ $card_wireless_num = $PHY_11AX_6G ]
				then
					is6G=1
				fi
			else
				echo "dbdc detected"
				card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |
					awk -F "[=;]" '{ print $2 }'`
				card_wireless_num=`cat ${card_profile_path} | grep -w WirelessMode | awk -F "=" '{ print $2 }'`
				card_wireless_num=` echo $card_wireless_num | awk -F ";" '{print $1}'`
				if [ $card_wireless_num = $PHY_11AX_6G ]
				then
					is6G=1
				fi
				card_profile_path=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_profile_path |
					awk -F "[=;]" '{ print $3 }'`
				card_wireless_num=`cat ${card_profile_path} | grep -w WirelessMode | awk -F "=" '{ print $2 }'`
				card_wireless_num=` echo $card_wireless_num | awk -F ";" '{print $1}'`
				if [ $card_wireless_num = $PHY_11AX_6G ]
				then
					is6G=1
				fi

				if [ $is6G == "1" -a $isAX7800 == "1" ]
				then
					apcli_6G=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_apcli_ifname |
						awk -F "[=;]" '{ print $3 }'`
					ra_6G=`cat /etc/wireless/l1profile.dat | grep INDEX${card_idx}_ext_ifname |
						awk -F "[=;]" '{ print $3 }'`
				fi

			fi
		fi
		card_idx=`expr $card_idx + 1`
	done
	echo "is6G $is6G card_wireless_num $card_wireless_num isAX7800 $isAX7800 active_cards $active_cards"
	if [ $active_cards == "2" -a $is6G == "0" ]
	then
		radio_band="24G;5G;5G"
	elif [ $active_cards == "2" -a $is6G == "1" ]
	then
		radio_band="24G;6G"
	elif [ $active_cards == "3" -a $is6G == "0" ]
	then
		radio_band="24G;5GH;5GL"
	elif [ $active_cards == "3" -a $is6G == "1" ]
	then
		radio_band="24G;5G;6G"
	elif [ $active_cards == "4" -a $is6G == "1" -a $isAX7800 == "1" ]
	then
		radio_band="24G;5G;6G"
	elif [ $active_cards == "4" -a $is6G == "0" -a $isAX7800 == "1" ]
	then
		radio_band="24G;5GH;5GL"
	fi
	wan_iface=`uci get network.wan.device`
}

R2_config_check() {
	echo "####R2_config_check####"
#MAP version check
		MapVer=`cat /etc/map/1905d.cfg | grep map_ver| awk -F "=" '{ print $2 }'`
		if [ "$MapVer" = "R1" ]; then
			echo "MAP version 1.0"
			loop_count=1
			while [ $loop_count -le $active_cards ]
			do
				if_name=`sed -n "${loop_count}"p ./main_ifname`
				if [ $isLogan == "1" ];
                                then
					mwctl ${if_name} set mapR2Enable=0
                                        echo "mwctl $if_name set mapR2Enable=0"
                                        mwctl ${if_name} set mapTSEnable=0
                                        echo "mwctl $if_name set mapTSEnable=0"
                		else
					iwpriv ${if_name} set mapR2Enable=0
					echo "iwpriv $if_name set mapR2Enable=0"
					iwpriv ${if_name} set mapTSEnable=0
					echo "iwpriv $if_name set mapTSEnable=0"
				fi
				loop_count=`expr $loop_count + 1`
			done
		elif [ "$MapVer" = "R2" ]; then
			echo "MAP version 2.0"
			loop_count=1
			while [ $loop_count -le $active_cards ]
			do
				if_name=`sed -n "${loop_count}"p ./main_ifname`
				if [ $isLogan == "1" ]
                                then
					mwctl ${if_name} set mapR2Enable=1
	                                echo "mwctl $if_name set mapR2Enable=1"
        	                        mwctl ${if_name} set mapTSEnable=1
                	                echo "mwctl $if_name set mapTSEnable=1"
                                else
					iwpriv ${if_name} set mapR2Enable=1
					echo "iwpriv $if_name set mapR2Enable=1"
                                	iwpriv ${if_name} set mapTSEnable=1
                                	echo "iwpriv $if_name set mapTSEnable=1"
				fi
                                loop_count=`expr $loop_count + 1`
                        done
		else
			echo "MAP version 3.0"
			loop_count=1
			while [ $loop_count -le $active_cards ]
			do
				if_name=`sed -n "${loop_count}"p ./main_ifname`
				mwctl ${if_name} set mapR3Enable=1
				echo "mwctl $if_name set mapR3Enable=1"
				mwctl ${if_name} set DppEnable=1
				echo "mwctl $if_name set DppEnable=1"
				mwctl ${if_name} set mapTSEnable=1
				echo "mwctl $if_name set mapTSEnable=1"
				if [ ${MapMode} = "4" ]; then
					mwctl ${if_name} set cp_support=1
					echo "mwctl $if_name set cp_support=1"
				fi
				loop_count=`expr $loop_count + 1`
			done
		fi
}

disable_R2_config() {
	echo "####disable_R2_config####"
	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./main_ifname`
		if [ $isLogan == "1" ];
		then
			mwctl ${if_name} set mapR2Enable=0
                	echo "mwctl $if_name set mapR2Enable=0"
                	mwctl ${if_name} set mapTSEnable=0
                	echo "mwctl $if_name set mapTSEnable=0"
		else
			iwpriv ${if_name} set mapR2Enable=0
			echo "iwpriv $if_name set mapR2Enable=0"
			iwpriv ${if_name} set mapTSEnable=0
			echo "iwpriv $if_name set mapTSEnable=0"
		fi
		loop_count=`expr $loop_count + 1`
	done
}

disable_R3_config() {
       echo "####disable_R3_config####"
        loop_count=1
        while [ $loop_count -le $active_cards ]
        do
                if_name=`sed -n "${loop_count}"p ./main_ifname`
		if [ $isLogan == "1" ];
                then
			mwctl ${if_name} set mapR3Enable=0
	                echo "mwctl $if_name set mapR3Enable=0"
        	        mwctl ${if_name} set DppEnable=0
                	echo "mwctl $if_name set DppEnable=0"
                	mwctl ${if_name} set mapTSEnable=0
                	echo "mwctl $if_name set mapTSEnable=0"
		else
        	        iwpriv ${if_name} set mapR3Enable=0
			echo "iwpriv $if_name set mapR3Enable=0"
			iwpriv ${if_name} set DppEnable=0
			echo "iwpriv $if_name set DppEnable=0"
                	iwpriv ${if_name} set mapTSEnable=0
                	echo "iwpriv $if_name set mapTSEnable=0"
		fi
                loop_count=`expr $loop_count + 1`
        done
}




#call routine to prepare wapp configuration files
#call routine to prepare 1905 config file
prepare_1905_config()
{
	echo "####prepare 1905 config####"

	main_intf=`cat /etc/wireless/l1profile.dat | grep INDEX0_main_ifname |awk -F "[=;]" '{ print $2 }'`
	main_intf_mac=`cat /sys/class/net/$main_intf/address`
	echo "main wifi intf[$main_intf] mac[$main_intf_mac]"
	ctrlr_al_mac=$main_intf_mac
	agent_al_mac=$main_intf_mac

	DeviceRole=`cat /etc/map/mapd_cfg | grep DeviceRole | awk -F "=" '{ print $2 }'`
	wan_iface=`uci get network.wan.device`
	`ifconfig | grep "br" > br_name`
	bridge_name=`cat br_name | awk '{ print $1}'`
	####delete all lan= wan=
	sed -i '/lan=/d' /etc/map/1905d.cfg
	sed -i '/wan=/d' /etc/map/1905d.cfg
	#$a indicate append at the end of the file
	addlinestr='$a '
	lanstr='lan='
	wanstr='wan='
	br0_mac=$(cat /sys/class/net/br-lan/address)
	first_three_octets=${br0_mac:0:9}
	last_two_octets=${br0_mac:11}
	modified_octet=${br0_mac:9:2}
	let mac=0x$modified_octet
	sed -i "/lan=.*/d" /etc/ethernet_cfg.txt
	lan_iface=""
	space=" "
	eth_itfs_file='/tmp/eth_itfs.txt'

	#save all eth intf in bridge to /tmp/eth_itfs.txt
	cat /etc/config/network | grep 'list ports' | awk '{print $3}' | awk -F  "'" '{print $2}' > $eth_itfs_file

	# lan_iface with all lan interface in bridge
	# lan_iface=lan0 lan1 lan2 ... for /etc/ethernet_cfg.txt
	while read -r line; do
		lan_iface=$lan_iface$space$line
	done < "$eth_itfs_file"

	echo "lan_iface=$lan_iface"

	if [ "${perportpervlan}" = "1" ] && [ $sw_arch = "GSW" ]; then
		echo "------------------------------------------"
		echo "prepare_1905_config perportpervlan enabled on GSW switch"
		echo "------------------------------------------"
		eth0=$lan_iface
		lan_iface1=vlan1
		lan_iface2=vlan2
		lan_iface3=vlan3
		lan_iface4=vlan4
		lan1_insert_str=$addlinestr$lanstr$lan_iface1
		lan2_insert_str=$addlinestr$lanstr$lan_iface2
		lan3_insert_str=$addlinestr$lanstr$lan_iface3
		lan4_insert_str=$addlinestr$lanstr$lan_iface4
		echo "!!!!!!!!!!!!!!!!!!!!!$lan1_insert_str"
		`sed -i "$lan1_insert_str" /etc/map/1905d.cfg`
		`sed -i "$lan2_insert_str" /etc/map/1905d.cfg`
		`sed -i "$lan3_insert_str" /etc/map/1905d.cfg`
		`sed -i "$lan4_insert_str" /etc/map/1905d.cfg`
		sed -i "s/lan_vid=.*/lan_vid=1;2;3;4;/g" /etc/ethernet_cfg.txt
		sed -i "s/wan_vid=.*/wan_vid=5;/g" /etc/ethernet_cfg.txt
	else
		if [ $mode = "1" ];then
			if [[ "$lan_iface" == *"$wan_iface"* ]]; then
				sed -i "1i\lan=$lan_iface" /etc/ethernet_cfg.txt
			else
				sed -i "1i\lan=$lan_iface $wan_iface" /etc/ethernet_cfg.txt
			fi
		else
			sed -i "1i\lan=$lan_iface" /etc/ethernet_cfg.txt
		fi
		if [ $isEagle == "1" ];then
			sed -i "/^ext_phy_port/cext_phy_port=0 8" /etc/ethernet_cfg.txt
		fi
		board_name=`cat /tmp/sysinfo/board_name | awk -F "," '{ print $2 }'`
		if [ "$board_name" == "en7523" ]; then
			sed -i "/^ext_phy_port/cext_phy_port=7" /etc/ethernet_cfg.txt
			echo "board_name:$board_name, set ext_phy_port=7"
		fi
		if [[ "$board_name" == *"7987"* ]]; then
			if [[ "$board_name" == *"an8801sb"* ]]; then
				sed -i "/^ext_phy_port/cext_phy_port=15 31" /etc/ethernet_cfg.txt
				echo "board_name:$board_name, set ext_phy_port=15(WAN) 31(2.5G LAN)"
			else
				sed -i "/^ext_phy_port/cext_phy_port=15 11" /etc/ethernet_cfg.txt
				echo "board_name:$board_name, set ext_phy_port=15(WAN) 11(2.5G LAN)"
			fi
		fi
		if expr "$board_name" : ".*7981" > /dev/null; then
			sed -i "/^ext_phy_port/cext_phy_port=0" /etc/ethernet_cfg.txt
			echo "board_name:MT7981(cheetah), set ext_phy_port=0"
		fi
		sed -i "/br_lan=.*/d" /etc/ethernet_cfg.txt
		sed -i "1i\br_lan=$bridge_name" /etc/ethernet_cfg.txt

		#loop all eth intf in bridge from /tmp/eth_itfs.txt
		#save each lan intf to /etc/map/1905d.cfg
		#change hw ether mac for each intf(original rule)
		while read -r intf; do
			let "intf_idx=intf_idx+1"
			exist=`ifconfig $intf | grep HWaddr`
			if [ $intf ] && [ "$exist" != "" ]; then
				#append lan=lanx or ethx to 1905d.cfg for each loop
				lan_insert_str=$addlinestr$lanstr$intf
				sed -i "$lan_insert_str" /etc/map/1905d.cfg

				let "mac_new=mac+(intf_idx *16)"
				mac_str=`printf "%02x" $mac_new`
				m_str=${mac_str:0-2}
				ifconfig $intf down
				ifconfig $intf hw ether $first_three_octets$m_str$last_two_octets
				ifconfig $intf up
				echo "lan_if=$intf"
				echo "lan_if_mac=$first_three_octets$m_str$last_two_octets"
			fi
		done < "$eth_itfs_file"
		rm $eth_itfs_file

		#if [ `grep -c "lan=$lan_iface" /etc/map/1905d.cfg` -ne '0' ]; then
		#elif [ `grep -c "lan=" /etc/map/1905d.cfg` -ne '0' ]; then
		sed -i "s/radio_band=.*/radio_band=${radio_band}/g" /etc/map/1905d.cfg
		sed -i "s/map_controller_alid=.*/map_controller_alid=${ctrlr_al_mac}/g" /etc/map/1905d.cfg
		sed -i "s/map_agent_alid=.*/map_agent_alid=${agent_al_mac}/g" /etc/map/1905d.cfg
		if [ $DeviceRole = "1" ]
		then
			sed -i "s/map_agent=.*/map_agent=0/g" /etc/map/1905d.cfg
			sed -i "s/map_root=.*/map_root=1/g" /etc/map/1905d.cfg
		else
			sed -i "s/map_agent=.*/map_agent=1/g" /etc/map/1905d.cfg
			sed -i "s/map_root=.*/map_root=0/g" /etc/map/1905d.cfg
		fi

		#######mode
		if [ $mode = "1" ]; then
			echo "bridge mode"
			wan_insert_str=$addlinestr$wanstr$wan_iface
			sed -i "$wan_insert_str" /etc/map/1905d.cfg
			brctl addif $bridge_name $wan_iface
			echo "cmd: brctl addif $bridge_name $wan_iface"
		else
			echo "router mode"
			brctl delif $bridge_name $wan_iface
			echo "cmd: brctl delif $bridge_name $wan_iface"
		fi
	fi
}
reset_lan_interface()
{
	br0_mac=$(cat /sys/class/net/br-lan/address)
	lan_per_iface=`echo $lan_iface | awk -F " " '{ print $1 }'`
	if [ $lan_per_iface ]; then
		ifconfig $lan_per_iface down
		ifconfig $lan_per_iface hw ether $br0_mac
		ifconfig $lan_per_iface up
	fi
	lan_per_iface=`echo $lan_iface | awk -F " " '{ print $2 }'`
	if [ $lan_per_iface ]; then
		ifconfig $lan_per_iface down
		ifconfig $lan_per_iface hw ether $br0_mac
		ifconfig $lan_per_iface up
	fi
	lan_per_iface=`echo $lan_iface | awk -F " " '{ print $3 }'`
	if [ $lan_per_iface ]; then
		ifconfig $lan_per_iface down
		ifconfig $lan_per_iface hw ether $br0_mac
		ifconfig $lan_per_iface up
	fi
	lan_per_iface=`echo $lan_iface | awk -F " " '{ print $4 }'`
	if [ $lan_per_iface ]; then
		ifconfig $lan_per_iface down
		ifconfig $lan_per_iface hw ether $br0_mac
		ifconfig $lan_per_iface up
	fi
	lan_per_iface=`echo $lan_iface | awk -F " " '{ print $5 }'`
	if [ $lan_per_iface ]; then
		ifconfig $lan_per_iface down
		ifconfig $lan_per_iface hw ether $br0_mac
		ifconfig $lan_per_iface up
	fi
}
prepare_logging_config()
{
echo "
/tmp/log/log.mapd {
	size 64K
	copytruncate
	rotate 2
}
" > /etc/logrotate.d/mapd.log.conf
}


reset_default_configs()
{
	ETC_DPP_CFG="/etc/dpp_cfg.txt"
	ETC_DPP_CFG_TEST="/etc/dpp_cfg_test.txt"
	ETC_MAP_1905_DPP_KEYS="/etc/map/1905_dpp_keys.txt"

	echo "####reset_default_configs####"

	if [ "$check_default" = "default" ];then
		echo "reset $ETC_DPP_CFG"
		## /etc/dpp_cfg.txt
		echo "//dpp config file" > $ETC_DPP_CFG
		echo "curve_name=prime256v1" >> $ETC_DPP_CFG
		echo "allowed_role=1" >> $ETC_DPP_CFG
		echo "map_support=1" >> $ETC_DPP_CFG

		## /etc/dpp_cfg_test.txt
		echo "reset $ETC_DPP_CFG_TEST"
		echo "" > $ETC_DPP_CFG_TEST

		echo "reset $ETC_MAP_1905_DPP_KEYS"
		## /etc/map/1905_dpp_keys.txt
		echo "# private net access key of 1905 layer" > $ETC_MAP_1905_DPP_KEYS
		echo "netAccessKey=" >> $ETC_MAP_1905_DPP_KEYS
		echo "/* public Csign key to check the signature of connector */" >> $ETC_MAP_1905_DPP_KEYS
		echo "CsignKey=" >> $ETC_MAP_1905_DPP_KEYS
		echo "# connector of 1905 layer" >> $ETC_MAP_1905_DPP_KEYS
		echo "connector=" >> $ETC_MAP_1905_DPP_KEYS
	fi
}


#preapre config file for map steering parameters
prepare_mapd_strng_configs()
{
	echo "####prepare_mapd_strng_configs####"
	if [ ! -f "/etc/mapd_strng.conf" -o "$check_default" = "default" ];then
		echo "Make mapd_strng.conf"
echo "LowRSSIAPSteerEdge_RE=40
CUOverloadTh_2G=70
CUOverloadTh_5G_L=80
CUOverloadTh_5G_H=80
CUOverloadTh_6G=70
MetricPolicyChUtilThres_24G=70
MetricPolicyChUtilThres_5GL=80
MetricPolicyChUtilThres_5GH=80
MetricPolicyChUtilThres_6G=80
ChPlanningChUtilThresh_24G=70
ChPlanningChUtilThresh_5GL=80
ChPlanningChUtilThresh_6G=80
ChPlanningEDCCAThresh_24G=200
ChPlanningEDCCAThresh_5GL=200
ChPlanningEDCCAThresh_6G=200
ChPlanningOBSSThresh_24G=200
ChPlanningOBSSThresh_5GL=200
ChPlanningOBSSThresh_6G=200
ChPlanningR2MonitorTimeoutSecs=300
ChPlanningR2MonitorProhibitSecs=900
ChPlanningR2MetricReportingInterval=10
ChPlanningR2MinScoreMargin=10
MetricRepIntv=10
MetricPolicyRcpi_24G=100
MetricPolicyRcpi_5GL=100
MetricPolicyRcpi_5GH=100
MetricPolicyRcpi_6G=100
Forbidden_Force_Steer=0
" > /etc/mapd_strng.conf
	fi
}
#call routines for mapd_cfg.txt preparation
prepare_mapd_config()
{
	echo "####prepare_mapd_config####"
	need_loop=1
	line_count=1
	if [ $isLogan == "0" -o  $isEagle == "0" -o ${MapMode} == "4" ];
	then
		cp /etc/map/mapd_default.cfg /etc/map/mapd_cfg
	fi
	if [ "$check_default" = "default" ];then
		need_loop=0
		echo "###!UserConfigs!!!" > /etc/map/mapd_user.cfg
	fi
	sed -i "s/lan_interface=.*/lan_interface=${lan_iface}/g" /etc/map/mapd_cfg
	sed -i "s/wan_interface=.*/wan_interface=${wan_iface}/g" /etc/map/mapd_cfg
	while [ $need_loop == "1" ]
	do
		line=`sed -n "$line_count"p /etc/map/mapd_user.cfg`
		echo $line
		if [ -z $line ]
		then
			need_loop=0
		else
			key=`echo ${line} | awk -F "=" '{ print $1 }'`
			value=`echo ${line} | cut -d'=' -f2-`
			echo "Key = ${key}, value = ${value}"
			datconf -f /etc/map/mapd_cfg set $key "${value}"
		fi
		line_count=`expr $line_count + 1`
	done
	enhanced_logging=`cat /etc/map/mapd_cfg | grep "EnhancedLogging" | awk -F "=" '{ print $2 }'`
	if [ $enhanced_logging = "1" ]
	then
		prepare_logging_config
	fi
	sed -i "s/bss_config_priority=.*/bss_config_priority=${bh_priority_list}/g" /etc/map/mapd_cfg
	prepare_mapd_strng_configs
}


disconnect_all_sta()
{
	need_loop=1
	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./main_ifname`
		if [ "$isLogan" = "1" ];
		then
			`mwctl ${if_name} set DisConnectAllSta=`
		else
			`iwpriv ${if_name} set DisConnectAllSta=`
		fi
		loop_count=`expr $loop_count + 1`
	done
}

ApCliIntfUpForCert()
{
        need_loop=1
        loop_count=1
        while [ $loop_count -le $active_cards ]
        do
                if_name=`sed -n "${loop_count}"p ./apcli_ifname`
                `ifconfig | grep "br" > br_name`
                bridge_name=`cat br_name | awk '{ print $1}'`
		#Due to HW Limitation only on AX7800, need to skip apcli0.
		if [ "$isAX7800" = "1" -a "$if_name" = "apcli0" ]
		then
			loop_count=`expr $loop_count + 1`
			continue
		fi
                `ifconfig ${if_name} up`
                `brctl addif ${bridge_name} ${if_name}`
		if [ "$isLogan" = "1" ]
               	then
			`mwctl ${if_name} set mapEnable=4`
			`mwctl ${if_name} set ApCliEnable=0`
		else
	                `iwpriv ${if_name} set mapEnable=4`
        	        `iwpriv ${if_name} set ApCliEnable=0`
		fi
                loop_count=`expr $loop_count + 1`
        done
	Cert_6G=`cat /etc/map/mapd_default.cfg | grep Cert_6G | awk -F "=" '{ print $2 }'`
	echo "$Cert_6G"

	if [ "$is6G" = "1" -a "$Cert_6G" = "0" ]
	then
		if [ "$isEagle" = "1" -o "$isAX7800" = "1" ]
		then
			`ifconfig "${apcli_6G}0" down`
			`ifconfig "${ra_6G}0" down`
		fi
	fi
        sleep 1

	if [ "$isLogan" = "1" ];
	then
		mwctl "${apcli_6G}0" scan psc=1
	fi

        sleep 2
}

Enable_Apcli_MLO()
{
	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./apcli_ifname`
		ifconfig $if_name down
		sleep 2
		loop_count=`expr $loop_count + 1`
	done

	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./apcli_ifname`
		if [ $is6GBE = "1" ];
		then
			mwctl $if_name set mlo_switch 1
		fi
		sleep 1;
		loop_count=`expr $loop_count + 1`
	done
}

ApCliIntfUp()
{
	Enable_Apcli_MLO
	sleep 2
	need_loop=1
	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./apcli_ifname`
		`ifconfig | grep "br" > br_name`
		bridge_name=`cat br_name | awk '{ print $1}'`
		#Due to HW Limitation only on AX7800, need to skip apcli0.
		if [ "$isAX7800" = "1" -a "$if_name" = "apcli0" ]
		then
			loop_count=`expr $loop_count + 1`
			continue
		fi
		`ifconfig ${if_name} up`
		`brctl addif ${bridge_name} ${if_name}`
		if [ "$isLogan" = "1" ];
                then
                        `mwctl ${if_name} set mapEnable=1`
                        `mwctl ${if_name} set ApCliEnable=0`
                        wpa_cli -i ${if_name} remove_network all
                        wpa_cli -i ${if_name} sta_autoconnect 0
                else
			`iwpriv ${if_name} set mapEnable=1`
			`iwpriv ${if_name} set ApCliEnable=0`
		fi
		loop_count=`expr $loop_count + 1`
	done
	if [ "$isLogan" = "1" ];
	then
		mwctl "${apcli_6G}0" scan psc=1
		mwctl phy0 set csa_2g 1
	fi
	sleep 2
}

ApCliIntfDown()
{
	need_loop=1
	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./apcli_ifname`
		`ifconfig | grep "br" > br_name`
		bridge_name=`cat br_name | awk '{ print $1}'`
		`ifconfig ${if_name} down`
		`brctl addif ${bridge_name} ${if_name}`
		if [ "$isLogan" = "1" ];
		then
			`mwctl ${if_name} set ApCliEnable=0`
		else
			`iwpriv ${if_name} set ApCliEnable=0`
		fi
		loop_count=`expr $loop_count + 1`
	done
	sleep 2
}

perportpervlan_test()
{
	#per port per vlan setting
	br0_mac=$(cat /sys/class/net/br-lan/address)
	eth0=`uci get network.@device[0].ports|awk -F " " '{print $1}'`
	bridge_name=`cat br_name | awk '{ print $1}'`
	lan_iface1=vlan1
	lan_iface2=vlan2
	lan_iface3=vlan3
	lan_iface4=vlan4
	br0_mac=$(cat /sys/class/net/br-lan/address)
	br0_mac_first_five_str=${br0_mac%:*}
	lan_addr2=$br0_mac_first_five_str:22
	lan_addr3=$br0_mac_first_five_str:33
	lan_addr4=$br0_mac_first_five_str:44
	echo "#####################perportpervlan_test"
	echo $lan_iface1
	echo $lan_iface2
	echo $lan_iface3
	echo $lan_iface4
	echo $lan_addr2
	echo $lan_addr3
	echo $lan_addr4

	brctl delif $bridge_name $eth0
	vconfig add $eth0 1
	vconfig add $eth0 2
	vconfig add $eth0 3
	vconfig add $eth0 4

	ifconfig $lan_iface1 hw ether $br0_mac
	ifconfig $lan_iface1 up
	ifconfig $lan_iface2 hw ether $lan_addr2
	ifconfig $lan_iface2 up
	ifconfig $lan_iface3 hw ether $lan_addr3
	ifconfig $lan_iface3 up
	ifconfig $lan_iface4 hw ether $lan_addr4
	ifconfig $lan_iface4 up

	switch vlan set 0 1 10000011
	switch vlan set 1 2 01000011
	switch vlan set 2 3 00100011
	switch vlan set 3 4 00010011
	switch vlan set 5 5 00001101
	switch vlan pvid 0 1
	switch vlan pvid 1 2
	switch vlan pvid 2 3
	switch vlan pvid 3 4
	switch vlan pvid 4 5
	switch vlan pvid 5 5

	switch reg w 2610 81000000
	#tag mode
	switch reg w 2604 20ff0003

	brctl addif $bridge_name $lan_iface1
	brctl addif $bridge_name $lan_iface2
	brctl addif $bridge_name $lan_iface3
	brctl addif $bridge_name $lan_iface4
}

DHCP_INIT()
{
	echo "####DHCP_INIT####"
	DeviceRole=`cat /etc/map/mapd_cfg|\
		grep DeviceRole|awk -F "=" '{print $2}'`
	echo "DeviceRole: $DeviceRole (0: Auto 1:Controller 2:Agent)"
	DHCP_CTRL=`cat /etc/map/mapd_cfg|\
		grep DhcpCtl| awk -F "=" '{print $2}'`
	ThrdPrtCon=`cat /etc/map/mapd_cfg|grep ThirdPartyConnection\
		|awk -F "=" '{print $2}'`
	echo "DHCP Server setting: $DeviceRole $DHCP_CTRL $ThrdPrtCon $mode ($mode == "1")"
	if [ $DHCP_CTRL != "1" ];then
		return 0
	fi
		
	if [ $ThrdPrtCon == "1" -a "${MapMode}" = "1"  ];then
	echo "Role($DeviceRole ) ThrdPrtCon($ThrdPrtCon):\
	Disable DHCP Server!"
		uci set dhcp.lan.ignore=1
		uci commit
		/etc/init.d/dnsmasq reload
	else
	if [ $mode != "1" ];then
		echo "Role($DeviceRole ) ThrdPrtCon($ThrdPrtCon):\
		Enable DHCP Server!"
			if [ -z "$(uci -q get network.lan.ipaddr)" ];then
				echo "no IP, reload network ip to 192.168.1.1"
				uci -q set network.lan.ipaddr=192.168.1.1;
				`ifconfig ${bridge_name} 192.168.1.1 up`
				uci set dhcp.lan.ignore='0'
				uci commit
				/etc/init.d/dnsmasq restart
				/etc/init.d/network reload
			 else
				br_ip=`uci -q get network.lan.ipaddr`
				echo "br_ip: $br_ip"
				`ifconfig ${bridge_name} $br_ip up`
				uci set dhcp.lan.ignore='0'
				uci commit
				/etc/init.d/dnsmasq restart
			fi
		fi
	fi
	sleep 1

	if [ $mode == "1" ];then
		echo "bridge mode"
		uci set network.wan.proto=none
		uci commit
		#Disable DHCP Server
		uci set dhcp.lan.ignore=1
		uci commit
		/etc/init.d/dnsmasq reload
		udhcpc -i ${bridge_name} &
	else
		echo "router mode"
		uci set network.wan.proto=dhcp
		uci commit
	fi

	return 1
}

Traffic_Separation_Init()
{
	for index in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
	do
		if [ $isLogan == "1" ];
        	then
		mwctl ra$index set vlan_tag 1
		mwctl rax$index set  vlan_tag 1
		mwctl rai$index set vlan_tag 1
		mwctl ra$index set vlan_policy 0:4
		mwctl rax$index set vlan_policy 0:4
		mwctl rai$index set vlan_policy 0:4
		mwctl ra$index set vlan_policy 1:2
		mwctl rai$index set vlan_policy 1:2
		mwctl rai$index set vlan_policy 1:2
		else
		iwpriv ra$index set VLANTag=1
		iwpriv rax$index set VLANTag=1
		iwpriv rai$index set VLANTag=1
		iwpriv ra$index set VLANPolicy=0:4
		iwpriv rax$index set VLANPolicy=0:4
		iwpriv rai$index set VLANPolicy=0:4
		iwpriv ra$index set VLANPolicy=1:2
		iwpriv rai$index set VLANPolicy=1:2
		iwpriv rai$index set VLANPolicy=1:2
		fi
	done
	if [ $isLogan == "1" ];
        then
	mwctl apcli0 set vlan_tag 1
	mwctl apcli0 set vlan_policy 0:4
	mwctl apcli0 set vlan_policy 1:2
	mwctl apclix0 set vlan_tag 1
	mwctl apclix0 set vlan_policy 0:4
	mwctl apclix0 set vlan_policy 1:2
	mwctl apclii0 set vlan_tag 1
	mwctl apclii0 set vlan_policy 0:4
	mwctl apclii0 set vlan_policy 1:2
	else
	iwpriv apcli0 set VLANTag=1
	iwpriv apcli0 set VLANPolicy=0:4
	iwpriv apcli0 set VLANPolicy=1:2
	iwpriv apclix0 set VLANTag=1
	iwpriv apclix0 set VLANPolicy=0:4
	iwpriv apclix0 set VLANPolicy=1:2
	iwpriv apclii0 set VLANTag=1
	iwpriv apclii0 set VLANPolicy=0:4
	iwpriv apclii0 set VLANPolicy=1:2
	fi
}

Traffic_Separation_Init_Cert()
{
	if [ $isLogan == "1" ];
	then
	mwctl ra0 set VLANEn=0
        mwctl rax0 set VLANEn=0
        mwctl rai0 set VLANEn=0
	else
	iwpriv ra0 set VLANEn=0
	iwpriv rax0 set VLANEn=0
	iwpriv rai0 set VLANEn=0
	fi
}

StartStandAloneBS()
{
	sleep 3
	echo "WAPP starting..."
	wapp_openwrt.sh > /dev/null
	sleep 3
	echo "BS2.0 Daemon starting..."
	bs20 &
	sleep 3
	disconnect_all_sta
	echo "Stand Alone BS2.0 is ready"
}

prepare_uci2map_files()
{
	if [ "$check_default" == "default" ];then
		cp /etc/mapd.uci /etc/config/mapd
	fi
	/etc/uci2map.lua
}

StartHostapd()
{
	echo "####StartHostapd####"
	if ps | grep -v grep | grep -v $0 | grep /usr/sbin/hostapd > /dev/null
	then
		echo "hostapd  service running already"
	else
		echo "hostapd is not running"
		wifi down
		rm /tmp/hostapd.log
		/usr/sbin/hostapd -B -t -dddd -f /tmp/hostapd.log -g /var/run/hostapd/global /etc/hostapd_rai0_MTK_MAP.conf /etc/hostapd_ra0_MTK_MAP.conf /etc/hostapd_rax0_MTK_MAP_6G.conf
		sleep 10
	fi
	if ps | grep -v grep | grep -v $0 | grep /usr/sbin/wpa_supplicant > /dev/null
	then
		echo "supplicant  service running already"
		wpa_cli -iapcli0 remove_network all
		wpa_cli -iapclii0 remove_network all
		wpa_cli -iapclix0 remove_network all
		mwctl apclix0 scan psc=1
	else
		echo "supplicant is not running"
		rm /tmp/wpa_log.log
		mkdir /var/run/wpa_supplicant/
		/usr/sbin/wpa_supplicant -g /var/run/wpa_supplicant/global -bbr-lan -Dnl80211 -iapcli0 -c/etc/wpa_supplicant_apcli0_MTK_MAP.conf -N -Dnl80211 -iapclii0 -c/etc/wpa_supplicant_apclii0_MTK_MAP.conf -N -Dnl80211 -iapclix0 -c/etc/wpa_supplicant_apclix0_MTK_MAP.conf -t -ddd -f /tmp/wpa_log.log -B
		sleep 5
		mwctl apclix0 scan psc=1
	fi
}
StartMapTurnkey()
{
	echo "####StartMapTurnkey####"
#	SwitchSetting
#	echo $lan_iface > /sys/kernel/debug/hnat/hnat_ppd_if
	if [ "${perportpervlan}" = "1" ] && [ $sw_arch = "GSW" ]; then
		echo "GSW switch:StartMapTurnkey perportpervlan enabled"
		perportpervlan_test
	fi
	R2_config_check
	ulimit -c unlimited
	#Controller
	DeviceRole=`cat /etc/map/mapd_cfg|\
	grep DeviceRole|awk -F "=" '{ print $2 }'`
	echo "DeviceRole=$DeviceRole"
	echo "dhcp starting..."
	DHCP_INIT
	Traffic_Separation_Init
	#reset static puncture bitmap
	iwpriv rai0 set ppcapctrl=1-0-2-0x0000-1
	echo "WAPP starting..."
	wapp_openwrt.sh > /dev/null
	echo "1905 starting..."
	if [ $DeviceRole = "1" ]
	then
		p1905_managerd -r0 -f "/etc/map/1905d.cfg" -F "/etc/map/wts_bss_info_config" > /dev/console&
	else
		p1905_managerd -r1 -f "/etc/map/1905d.cfg" -F "/etc/map/wts_bss_info_config" > /dev/console&
	fi
	sleep 2
	echo "MAP Daemon starting..."
	if [ $enhanced_logging = "1" ]
	then
		mapd -I "/etc/map/mapd_cfg" -O "/etc/mapd_strng.conf" > /tmp/log/log.mapd&
	else
		mapd -I "/etc/map/mapd_cfg" -O "/etc/mapd_strng.conf" > /dev/console&
	fi
#	ModifySwitchReg
	sleep 3
	echo -e "----- ${RED}MAP DEVICE STARTED${NC} -----"
}

clean
sync
get_platform
get_switch_arch
sync
get_operating_mode
sync
if [ $isLogan == "1" -a  $isEagle == "1" -a ${MapMode} != "4" ];
then
	prepare_uci2map_files
fi
prepare_ifname
sync
if [ $isEagle == "1" ];
then
prepare_platform_variables_eagle
else
prepare_platform_variables
fi
sync
reset_default_configs
sync
prepare_mapd_config
sync
prepare_1905_config
sync
disable_R2_config
sync
disable_R3_config
sync

echo "kill fwdd daemon and remove mtfwd module"
#Enable QuickChChange feature.

ulimit -c unlimited

echo "####start MAP with MapMode=$MapMode####"
if [ "${MapMode}" = "0" ];
	then
		echo "Enable QoSR1"
		datconf -f /tmp/mtk/wifi/2860 set QoSR1Enable 1
		datconf -f /tmp/mtk/wifi/rtdev set QoSR1Enable 1
		datconf -f /tmp/mtk/wifi/wifi3 set QoSR1Enable 1

	echo "dhcp starting..."
	if [ "${LastMapMode}" = "1" ]
	then
	echo "default dhcp server enable..."
	sync
	DHCP_INIT
	sync
	echo "defautl ApCliIntfDown..."
	sync
	ApCliIntfDown
	sync
	echo "defautl dat apcli disable..."
	nvram_set 2860 ApCliEnable 0
	nvram_set rtdev ApCliEnable 0
	nvram_set wifi3 ApCliEnable 0
	fi
	echo "Non MAP mode"
	need_loop=1
	loop_count=1
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./main_ifname`
		if [ $isLogan = "1" ];
        	then
			mwctl ${if_name} set mapEnable=0
		else
			iwpriv ${if_name} set mapEnable=0
		fi
		loop_count=`expr $loop_count + 1`
	done
	sync
	reset_lan_interface
	sync
	wapp_openwrt.sh
	sync
	modprobe mtfwd
	sleep 1
	fwdd -p ra0 apcli0 -p rai0 apclii0 -p rax0 apclix0 -p wlan0 wlan-apcli0 -e eth0 5G&
	sync
elif [ ${MapMode} = "2" ];
	then
	rmmod mapfilter
	echo "BS2.0 mode"
	echo "Disable CentralizedSteering"
	uci set mapd.mapd_cfg.CentralizedSteering=0
	uci commit
	while [ $loop_count -le $active_cards ]
	do
		if_name=`sed -n "${loop_count}"p ./main_ifname`
		if [ $isLogan = "1" ];
                then
			mwctl ${if_name} set mapEnable=2
		else
			iwpriv ${if_name} set mapEnable=2
		fi
		loop_count=`expr $loop_count + 1`
	done
	sleep 1
	StartStandAloneBS
	modprobe mtfwd
	sleep 1
	fwdd -p ra0 apcli0 -p rai0 apclii0 -p rax0 apclix0 -p wlan0 wlan-apcli0 -e eth0 5G&
elif [ ${MapMode} = "4" ];
	then
	killall -15 fwdd
	sleep 1
	rmmod mtfwd
	echo "Certification"
	mkdir /libmapd
	cp /usr/lib/libmapd_interface_client.so /libmapd/
	modprobe mapfilter
	ApCliIntfUpForCert
	sync
	if [ $isAX7800 == "1" -o $isLogan == "1" ];
	then
		if [ $isAX7800 == "1" ];
		then
			map_config_agent.lua start rai0
		fi

		if [ $isLogan == "1" -a  $isBellwether == "1" ];
		then
			map_config_agent.lua start Bellwether
		fi

		if [ $isLogan == "1" -a  $isEagle == "1" ];
                then
                        map_config_agent.lua start Eagle
                fi

	else
		map_config_agent.lua start
	fi
	echo 458752 > /proc/sys/net/core/rmem_max
	Traffic_Separation_Init_Cert
	R2_config_check
else
	if [ "${MapMode}" = "1" ];
	then
		echo "TurnKeyMode"
		echo "Disable QoSR1"
		datconf -f /tmp/mtk/wifi/2860 set QoSR1Enable 0
		datconf -f /tmp/mtk/wifi/rtdev set QoSR1Enable 0
		datconf -f /tmp/mtk/wifi/wifi3 set QoSR1Enable 0

		killall -15 fwdd
		sleep 1
		rmmod mtfwd
		mkdir /libmapd
		cp /usr/lib/libmapd_interface_client.so /libmapd/
		modprobe mapfilter
		sync
		ApCliIntfUp
		sync
		#need_loop=1
		#loop_count=1
		#while [ $loop_count -le $active_cards ]
		#do
		#	if_name=`sed -n "${loop_count}"p ./main_ifname`
		#	iwpriv ${if_name} set mapEnable=1
		#	loop_count=`expr $loop_count + 1`
		#done
		sleep 1
		sync
		StartMapTurnkey
		sync
	fi
fi
/etc/init.d/easymesh stop > /dev/null 2>&1
