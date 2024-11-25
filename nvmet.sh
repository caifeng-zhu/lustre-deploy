#!/bin/bash

nvmet_offload=0
nvmet_diskdir=/dev/disk/nvme

debug=0
dryrun=

config_file="./nvmet.conf"

declare -a nvmet_port
declare -a nvmet_subsys_entries
declare -a nvmet_subsys_namespaces

errexit() {
	printf "$*\n"
	exit 1
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [-h] [-n] [-d] <command> [config file]
Options:
 -h	Display this help message
 -n	Dry run mode (echo commands instead of executing them)
 -d	Enable debug mode
Commands:
 create|export <config file>
EOF
	exit 0
}

port_create() {
	pt=$1
	read traddr trsvcid trtype <<< ${nvmet_port[$pt]}

	if nvmetcli /ports/$pt ls >& /dev/null ; then
		return
	fi

	$dryrun nvmetcli /ports create $pt
	$dryrun nvmetcli /ports/$pt set addr traddr=$traddr
	$dryrun nvmetcli /ports/$pt set addr trsvcid=$trsvcid
	$dryrun nvmetcli /ports/$pt set addr trtype=$trtype
	$dryrun nvmetcli /ports/$pt set addr adrfam=ipv4
}

port_link_subsys() {
	if nvmetcli /ports/$pt/subsystems/$nqn ls >& /dev/null ; then
		return
	fi

	$dryrun nvmetcli /ports/$pt/subsystems create $nqn
}

subsys_create() {
	read nqn <<< $*

	if nvmetcli /subsystems/$nqn ls >& /dev/null ; then
		return
	fi

	$dryrun nvmetcli /subsystems create $nqn
	$dryrun nvmetcli /subsystems/$nqn set attr allow_any_host=1
	if [ $nvmet_offload -ne 0 ]; then
		$dryrun nvmetcli /subsystems/$nqn set attr offload=1	# XXX: enable rdma offload
	fi
}

namespace_create() {
	read nqn ns devpath <<< $*

	if nvmetcli /subsystems/$nqn/namespaces/$ns ls >& /dev/null ; then
		return
	fi

	$dryrun nvmetcli /subsystems/$nqn/namespaces create $ns
	$dryrun nvmetcli /subsystems/$nqn/namespaces/$ns set device path=$devpath
	$dryrun nvmetcli /subsystems/$nqn/namespaces/$ns enable
}

nvmet_create() {
	for i in ${!nvmet_subsys_entries[*]}; do
		read -r bdf pt <<< ${nvmet_subsys_entries[$i]}

		nqn=$(hostid)-$bdf
		port_create $pt
		subsys_create $nqn

		for ns in ${nvmet_subsys_namespaces[*]}; do
			namespace_create $nqn $ns $nvmet_diskdir/$nqn-n$ns
		done

		port_link_subsys $pt $nqn
	done

	nvmetcli / saveconfig
}

while getopts "hnd" opt; do
	case $opt in
	h)	usage		;;
	n)	dryrun=echo	;;
	d)	debug=1		;;
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
		nvmet_create
		;;

	*)
		errexit "unknow options $1"
		;;
esac
