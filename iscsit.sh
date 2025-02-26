#!/bin/bash

iscsit_host=
declare -a iscsit_name
declare -a iscsit_acls
declare -a iscsit_luns
declare -a iscsit_portals

config_file="./iscsit.conf"

usage() {
cat <<EOF
Usage: $(basename "$0") [-h] <command> [config file]
Options:
 -h	Display this help message
Commands:
 create|export [config file]
EOF
}

errexit() {
	printf "$*\n"
	exit 1
}

iscsit_create() {
	idx=$1

	iqn="iqn.2024-04.com.ebtech.${iscsit_host}.${iscsit_name[$idx]}"
	targetcli /iscsi create $iqn

	targetcli /iscsi/$iqn/tpg1/portals delete 0.0.0.0 3260
	portals=( ${iscsit_portals[$idx]} )
	for addrport in ${portals[@]}; do
		read -r addr port <<< $(echo $addrport | tr ':' ' ')
		targetcli /iscsi/$iqn/tpg1/portals create $addr $port
	done

	acls=( ${iscsit_acls[$idx]} )
	for acl in ${acls[@]}; do
		targetcli /iscsi/$iqn/tpg1/acls create $acl
	done
	if [ ${#acls[@]} -eq 0 ]; then
		# generate acl automatically if no acl is specified.
		targetcli /iscsi/$iqn/tpg1 set attribute generate_node_acls=1
	fi

	luns=( ${iscsit_luns[$idx]} )
	for lun in ${luns[@]}; do
		# lunid is to be the model attribute for an iscsi disk. Model attribute
		# can be  queried by `udevadm info` and its length must be less than 16,
		# a limit imposed by kernel module.
		lunid="${iscsit_host}-${lun##*-}"
		if [ ${#lunid} -ge 16 ]; then
			errexit "too long lunid: $lunid"
		fi

		targetcli /backstores/block create $lunid $lun
		targetcli /iscsi/$iqn/tpg1/luns create /backstores/block/$lunid
	done
}

iscsit_populate() {
	for i in ${!iscsit_name[@]}; do
		iscsit_create $i
	done

	targetcli / saveconfig
}

while getopts "hn" opt; do
	case $opt in
	h)	usage;;
	esac
done
shift $((OPTIND - 1))

case $1 in
	create|export)
		if [ ! -z $2 ]; then
			config_file=$2
		fi
		if [ ! -e $config_file ]; then
			errexit "invalid $config_file"
		fi
		source $config_file

		iscsit_populate
		;;
	*)
		errexit "unknow options $1"
		;;
esac
