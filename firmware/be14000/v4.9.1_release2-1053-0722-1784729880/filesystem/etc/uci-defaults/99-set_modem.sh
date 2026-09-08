#!/bin/sh

set_modem_signal()
{
	local section=`uci -q get glmodem.signal`
	if [ "$section" = "" ];then
		uci set glmodem.signal='signal'
		uci set glmodem.signal.enable='1'
		uci set glmodem.signal.signal_capture_interval='10'
		uci set glmodem.signal.signal_capture_cycle='1800'
		uci set glmodem.signal.signal_cloud_cycle='300'

		uci commit glmodem
	fi
}


set_modem()
{
	local model=`cat /proc/gl-hw-info/model`

	case $model in
        "x3000"   |\
        "x2000" |\
        "xe300v2" |\
		"xe3000")
			set_modem_signal
		;;
	esac
}

set_modem
