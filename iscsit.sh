#!/bin/bash

declare -a iscsi_target
declare -a iscsi_acl
declare -a iscsi_lun
declare -a iscsi_tgt_iqn

dryrun=
config_file="./iscsit.conf"

usage() {
cat <<EOF
Usage: $(basename "$0") [-h] [-n] <command> [config file]
Options:
 -h	Display this help message
 -n	Dry run mode (echo commands instead of executing them)
Commands:
 create|export [config file]
EOF
}

errexit() {
	printf "$*\n"
	exit 1
}

backstore_block_create() {
	read -r path name <<< $*

	if targetcli ls /backstores/block/$name &> /dev/null; then
		return
	fi

	$dryrun targetcli /backstores/block create $name $path
}

target_create() {
	read -r iqn <<< $*

	if targetcli ls /iscsi/$iqn &> /dev/null; then
		return
	fi

	$dryrun targetcli /iscsi create $iqn

	if targetcli ls /iscsi/$iqn/tpg1/portals/0.0.0.0:3260 &> /dev/null; then
		$dryrun targetcli /iscsi/$iqn/tpg1/portals delete 0.0.0.0 3260
	fi
}

target_add_portal() {
	read -r ip port tgtid <<< $*

	iqn=${iscsi_target[tgtid]}

	if targetcli ls /iscsi/$iqn/tpg1/portals/$ip:$port &> /dev/null; then
		return
	fi

	$dryrun targetcli /iscsi/$iqn/tpg1/portals create $ip $port
}

target_add_lun() {
	read -r path name tgtid <<< $*

	iqn=${iscsi_target[tgtid]}

	if targetcli ls /iscsi/$iqn/tpg1/luns &> /dev/null && \
		targetcli ls /iscsi/$iqn/tpg1/luns | grep -q $name; then
		     return
	fi

	$dryrun targetcli /iscsi/$iqn/tpg1/luns create /backstores/block/$name
}

target_add_acl() {
	read -r acl tgtid <<< $*

	iqn=${iscsi_target[tgtid]}

	if targetcli ls /iscsi/$iqn/tpg1/acls/$acl &> /dev/null; then
		return
	fi

	$dryrun targetcli /iscsi/$iqn/tpg1/acls create $acl
}

iscsi_create() {
	for i in ${!iscsi_target[*]}; do
		iqn=${iscsi_target[i]}

		target_create $iqn
	done

	for i in ${!iscsi_portal[*]}; do
		read -r ip port tgtid <<< ${iscsi_portal[i]}

		target_add_portal $ip $port $tgtid
	done

	for i in ${!iscsi_lun[*]}; do
		read -r path name tgtid <<< ${iscsi_lun[i]}

		backstore_block_create $path $name
		target_add_lun $path $name $tgtid
	done

	for i in ${!iscsi_acl[*]}; do
		read -r acl tgtids <<< ${iscsi_acl[i]}
		read -r -a tgtids <<< $(echo $tgtids | tr ',' ' ')

		for tgtid in ${tgtids[*]}; do
			target_add_acl $acl $tgtid
		done
	done

	$dryrun targetcli / saveconfig
}

while getopts "hn" opt; do
	case $opt in
	h)	usage;;
	n)	dryrun=echo;;
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
		iscsi_create

		;;
	*)
		errexit "unknow options $1"

		;;
esac
