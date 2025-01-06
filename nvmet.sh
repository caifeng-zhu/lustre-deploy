#!/bin/bash

debug=0

config_file="./nvmet.conf"

declare -a nvmet_trinfo_list
declare -a nvmet_subsys_list
declare -a nvmet_subsys_ns_list
nvmet_offload=0
nvmet_diskdir=/dev/disk/nvme
nvmet_idx=
nvmet_nextport=0

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

nvmet_subsys_namespace_create() {
	nqn=$1
	ns=$2
	devpath=$3

	nvmetcli /subsystems/$nqn/namespaces create $ns
	nvmetcli /subsystems/$nqn/namespaces/$ns set device path=$devpath
	nvmetcli /subsystems/$nqn/namespaces/$ns enable
}

nvmet_subsys_create() {
	nqn=$1

	nvmetcli /subsystems create $nqn
	nvmetcli /subsystems/$nqn set attr allow_any_host=1
	if [ $nvmet_offload -ge 1 ]; then
		# enable rdma offload
		nvmetcli /subsystems/$nqn set attr offload=1
	fi

	# create namespaces for subsys
	namespaces=( ${nvmet_subsys_ns_list[$nvmet_idx]} )
	for ns in ${namespaces[@]}; do
		devpath=$nvmet_diskdir/$nqn-n$ns
		nvmet_subsys_namespace_create $nqn $ns $devpath
	done
}

nvmet_port_create() {
	pt=$1
	transport=$2

	read -r traddr trsvcid trtype <<< $(echo $transport | tr ':' ' ')
	nvmetcli /ports create $pt
	nvmetcli /ports/$pt set addr traddr=$traddr
	nvmetcli /ports/$pt set addr trsvcid=$trsvcid
	nvmetcli /ports/$pt set addr trtype=$trtype
	nvmetcli /ports/$pt set addr adrfam=ipv4
}

nvmet_port_add_subsys() {
	pt=$1
	nqn=$2

	nvmetcli /ports/$pt/subsystems create $nqn
}

nvmet_create() {
	ports=()
	transports=( ${nvmet_trinfo_list[$nvmet_idx]} )
	for transport in ${transports[@]}; do
		nvmet_port_create $nvmet_nextport $transport

		ports+=( $nvmet_nextport )
		nvmet_nextport=$((nvmet_nextport + 1))
	done

	bdfs=( ${nvmet_subsys_list[$nvmet_idx]} )
	for bdf in ${bdfs[@]}; do
		nqn=$(hostid)-$bdf
		nvmet_subsys_create $nqn

		for pt in ${ports[@]}; do
			nvmet_port_add_subsys $pt $nqn
		done
	done
}

nvmet_populate() {
	for i in ${!nvmet_trinfo_list[@]}; do
		nvmet_idx=$i
		nvmet_create
	done

	nvmetcli / saveconfig
}

while getopts "hndf:" opt; do
	case $opt in
	h)	usage			;;
	n)	dryrun=echo		;;
	f)	config_file=$OPTARG	;;
	d)	debug=1			;;
	esac
done
shift $((OPTIND - 1))

case "$1" in
create|export)
	if [ ! -e $config_file ]; then
		errexit "invalid $config_file"
	fi

	source $config_file
	nvmet_populate
	;;

*)
	errexit "unknow options $1"
	;;
esac
