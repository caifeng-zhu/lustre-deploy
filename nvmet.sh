#!/bin/bash

#TODO:
# - debug as option
# - config file as option
#
nvmet_config_path="/sys/kernel/config/nvmet"
nvmet_work_path=
nvmet_debug=0
dryrun=

declare -a nvmet_port
declare -a nvmet_disk

debug_print() {
	[ $nvmet_debug -ne 0 ] && printf "%*s $nvmet_work_path\n" $(($1 * 4)) $2
}

errexit() {
	printf "$*\n"
	exit 1
}

usage() {
	less -F <<EOF
${0##*/} create [-n --dryrun]
${0##*/} ls [-n --dryrun]
${0##*/} clear [-n --dryrun]
EOF
	exit 1
}

node_create() {
	local depth ndtype ndname ndval
	local saved_path=$nvmet_work_path

	read -r depth ndtype ndname ndval  <<< $*
	nvmet_work_path=$nvmet_work_path/$ndname
	debug_print $depth '=>'

	case $ndtype in
	PORT)
		if [ ! -e $nvmet_work_path ]; then
			$dryrun mkdir $nvmet_work_path

			read -r traddr trsvcid trtype <<< $ndval
			node_create $((depth + 1)) ATTR addr_adrfam ipv4
			node_create $((depth + 1)) ATTR addr_traddr $traddr
			node_create $((depth + 1)) ATTR addr_trsvcid $trsvcid
			node_create $((depth + 1)) ATTR addr_trtype $trtype
		fi
		;;

	SUBSYS)
		if [ ! -e $nvmet_work_path ]; then
			$dryrun mkdir $nvmet_work_path
			node_create $((depth + 1)) ATTR attr_allow_any_host 1
		fi
		;;

	NS)
		if [ ! -e $nvmet_work_path ]; then
			$dryrun mkdir $nvmet_work_path

			uuidpath=/sys/block/${ndval##*/}/uuid
			node_create $((depth + 1)) ATTR device_path $ndval
			if [ -e $uuidpath ]; then
				node_create $((depth + 1)) ATTR \
					device_uuid $(cat $uuidpath)
			fi
			node_create $((depth + 1)) ATTR enable 1
		fi
		;;

	ATTR)
		# Attriute files are created automatically as empty by the
		# driver. Here they are set with values from user space.
		if [ -z "$dryrun" ]; then
			echo $ndval > $nvmet_work_path
		else
			printf "%*s echo %8s > %s\n" $((depth * 4)) ' ' \
				$ndval $nvmet_work_path
		fi
		;;

	*)
		errexit "unknown node type: $ndtype"
		;;
	esac

	debug_print $depth '<='
	nvmet_work_path=$saved_path
}

node_clear() {
	local saved_path=$nvmet_work_path
	local ndtype ndname depth

	read -r depth ndtype ndname <<< $*
	nvmet_work_path=$nvmet_work_path/$ndname
	debug_print $depth '=>'

	case $ndtype in
	PORTS)
		for p in $(ls $nvmet_work_path); do
			node_clear $((depth + 1)) PORT ${p##*/}
		done
		;;

	PORT)
		node_clear $((depth + 1)) SUBSYSTEMS subsystems

		$dryrun rmdir $nvmet_work_path
		;;

	SUBSYSTEMS)
		for s in $(ls $nvmet_work_path); do
			node_clear $((depth + 1)) SUBSYS ${s##*/}
		done
		;;

	SUBSYS)
		if [ -h $nvmet_work_path ]; then
			$dryrun unlink $nvmet_work_path
		elif [ -d $nvmet_work_path ]; then
			node_clear $((depth + 1)) NAMESPACES namespaces

			$dryrun rmdir $nvmet_work_path
		else
			errexit "unexpected path $nvmet_work_path"
		fi
		;;

	NAMESPACES)
		for n in $(ls $nvmet_work_path); do
			node_clear $((depth + 1)) NS ${n##*/}
		done
		;;

	NS)
		$dryrun rmdir $nvmet_work_path
		;;

	*)
		errexit "unknown node type $ndtype"
		;;
	esac

	debug_print $depth '<='
	nvmet_work_path=$saved_path
}

node_show() {
	local saved_path=$nvmet_work_path
	local ndtype ndname depth

	read -r depth ndtype ndname <<< $*
	nvmet_work_path=$nvmet_work_path/$ndname

	debug_print $depth '=>'
	printf "%*s" $((depth * 4)) ' '

	case $ndtype in
	PORTS)
		$dryrun printf "$ndname:\n"

		local p
		for p in $(ls $nvmet_work_path); do
			node_show $((depth + 1)) PORT ${p##*/}
		done
		;;

	PORT)
		$dryrun printf "p$ndname:\n"

		local pa
		for pa in addr_trtype addr_trsvcid addr_traddr addr_adrfam \
		    param_inline_data_size; do
			node_show $((depth + 1)) ATTR $pa
		done
		node_show $((depth + 1)) SUBSYSTEMS subsystems
		;;

	SUBSYSTEMS)
		$dryrun printf "$ndname:\n"

		local s
		for s in $(ls $nvmet_work_path); do
			node_show $((depth + 1)) SUBSYS ${s##*/}
		done
		;;

	SUBSYS)
		if [ -h $nvmet_work_path ]; then
			$dryrun printf "$ndname\n"
		else
			$dryrun printf "$ndname:\n"
			node_show $((depth + 1)) ATTR attr_allow_any_host
			node_show $((depth + 1)) NAMESPACES namespaces
		fi
		;;

	NAMESPACES)
		$dryrun printf "$ndname:\n"

		local n
		for n in $(ls $nvmet_work_path); do
			node_show $((depth + 1)) NS ${n##*/}
		done
		;;

	NS)
		$dryrun printf "n$ndname:\n"

		local na
		for na in device_path device_uuid enable ana_grpid; do
			node_show $((depth + 1)) ATTR $na
		done
		;;

	ATTR)
		$dryrun printf "%-16s %s\n" "$ndname:" $(cat $nvmet_work_path)
		;;

	*)
		errexit "unknown node type $ndtype"
		;;
	esac

	debug_print $depth '<='
	nvmet_work_path=$saved_path
}

nvmet_create() {
	nvmet_work_path=$nvmet_config_path
	for i in ${!nvmet_disk[*]}; do
		read -r devpath pt subsys ns <<< ${nvmet_disk[$i]}
		node_create 1 PORT ports/$pt ${nvmet_port[$pt]}
		node_create 1 SUBSYS subsystems/$subsys 0
		node_create 1 NS subsystems/$subsys/namespaces/$ns $devpath

		$dryrun ln -s $nvmet_config_path/subsystems/$subsys \
		    $nvmet_config_path/ports/$pt/subsystems/$subsys
	done
}

nvmet_clear() {
	nvmet_work_path=$nvmet_config_path
	node_clear 1 PORTS ports
	node_clear 1 SUBSYSTEMS subsystems
}

nvmet_show() {
	nvmet_work_path=$nvmet_config_path
	node_show 1 PORTS ports
	node_show 1 SUBSYSTEMS subsystems
}

source ./nvmet.conf

if [[ $2 == "-n" || $2 == "--dryrun" ]]; then
	dryrun=echo
fi

case $1 in
	-h) 	usage;;
	create) nvmet_create;;
	clear) 	nvmet_clear;;
	ls) 	nvmet_show;;
	*) 	errexit "unknow options $1";;
esac
