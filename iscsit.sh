#!/bin/bash

declare -a iscsit_iqn
declare -a iscsit_acls
declare -a iscsit_luns
declare -a iscsit_portals
declare -A device_table

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

	iqn=${iscsit_iqn[$idx]}
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

	luns=( ${iscsit_luns[$idx]} )
	for lun in ${luns[@]}; do
		targetcli /backstores/block create $lun ${device_table[$lun]}
		targetcli /iscsi/$iqn/tpg1/luns create /backstores/block/$lun
	done
}

iscsit_populate() {
	for i in ${!iscsit_iqn[@]}; do
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
