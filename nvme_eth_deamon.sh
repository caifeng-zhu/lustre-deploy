#!/bin/bash -x

#config_path="/etc/nvme/connection.conf"
config_path="/home/zhongyuling/nvmet/connections.conf"
config_tmppath="/tmp/~connections.conf"
controller_path="/sys/class/nvme-fabrics/ctl"

nvme_confirm_mounted()
{
	subnqn=$1
	address="traddr=$2,trsvcid=$3"

	for ctl_path in $controller_path/nvme*; do
		if [[ -f $ctl_path/subsysnqn && -f $ctl_path/address ]]; then
			if grep -qx $subnqn $ctl_path/subsysnqn \
				&& grep -qx $address $ctl_path/address; then
					return 0
			fi
		fi
	done

	return 1
}

nvme_confirm()
{
	opt=$1

	while read -r line; do
		line=$(echo $line | cut -d ' ' -f 2-)
		case $opt in
			mounted)
				nvme_confirm_mounted $line || return 1
				;;
			unmounted)
				nvme_confirm_mounted $line && return 1
				;;
		esac
	done < $config_path

	return 0
}

nvme_connect_one()
{
	trtype=$1
	subnqn=$2
	traddr=$3
	trport=$4
	address="traddr=$traddr,trsvcid=$trport"

	nvme_confirm_mounted $subnqn $traddr $trport && return 0

	nvme discover -t $trtype -a $traddr -s $trport | grep -q $subnqn 
	if [ $? -ne 0 ]; then
		return 1
	fi

	nvme connect -t $trtype -a $traddr -s $trport -n $subnqn 
	if [ $? -ne 0 ]; then
		return 1
	fi

	return 0
}

nvme_connect()
{
	while read -r line; do
		nvme_connect_one $line || return 1
	done < $config_path

	return 0
}

nvme_disconnect_one()
{
	subnqn=$1

	nvme_confirm_mounted $* || return 0

	nvme disconnect -n $subnqn
	if [ $? -ne 0 ]; then
		return 1
	fi

	return 0
}

nvme_disconnect()
{
	while read -r line; do
		line=$(echo $line | cut -d ' ' -f 2-)

		nvme_disconnect_one $line || return 1
	done < $config_path

	return 0
}

start()
{
	nvme_connect || return 1
	nvme_confirm mounted || return 1

	return 0
}

stop()
{
	nvme_disconnect || return 1
	nvme_confirm unmounted || return 1

	return 0
}

case $1 in
	start|reload)
		start
		;;
	stop)
		stop
		;;
	restart)
		stop
		sleep 5
		start
		;;
	*)
		echo "Usage: $0 {start|stop|restart|reload}"
esac
