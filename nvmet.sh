#!/bin/bash

nvmet_path="/sys/kernel/config/nvmet"
node_path=
debug=0
dryrun=

config_file="./nvmet.conf"

declare -a nvmet_port
declare -a nvmet_disk

debug_print() {
	[ $debug -ne 0 ] && printf "%*s $node_path\n" $(($1 * 4)) $2
}

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
 clear|clr
 list|ls
EOF
	exit 0
}

node_create() {
	local depth ndtype ndname ndval
	local saved_path=$node_path

	read -r depth ndtype ndname ndval  <<< $*
	node_path=$node_path/$ndname
	debug_print $depth '=>'

	case $ndtype in
	PORT)
		if [ ! -e $node_path ]; then
			$dryrun mkdir $node_path

			read -r traddr trsvcid trtype <<< $ndval
			node_create $((depth + 1)) ATTR addr_adrfam ipv4
			node_create $((depth + 1)) ATTR addr_traddr $traddr
			node_create $((depth + 1)) ATTR addr_trsvcid $trsvcid
			node_create $((depth + 1)) ATTR addr_trtype $trtype
		fi
		;;

	SUBSYS)
		if [ ! -e $node_path ]; then
			$dryrun mkdir $node_path
			node_create $((depth + 1)) ATTR attr_allow_any_host 1
		fi
		;;

	NS)
		if [ ! -e $node_path ]; then
			$dryrun mkdir $node_path

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
			echo $ndval > $node_path
		else
			printf "%*s echo %8s > %s\n" $((depth * 4)) ' ' \
				$ndval $node_path
		fi
		;;

	*)
		errexit "unknown node type: $ndtype"
		;;
	esac

	debug_print $depth '<='
	node_path=$saved_path
}

node_clear() {
	local saved_path=$node_path
	local ndtype ndname depth

	read -r depth ndtype ndname <<< $*
	node_path=$node_path/$ndname
	debug_print $depth '=>'

	case $ndtype in
	PORTS)
		for p in $(ls $node_path); do
			node_clear $((depth + 1)) PORT ${p##*/}
		done
		;;

	PORT)
		node_clear $((depth + 1)) SUBSYSTEMS subsystems

		$dryrun rmdir $node_path
		;;

	SUBSYSTEMS)
		for s in $(ls $node_path); do
			node_clear $((depth + 1)) SUBSYS ${s##*/}
		done
		;;

	SUBSYS)
		if [ -h $node_path ]; then
			$dryrun unlink $node_path
		elif [ -d $node_path ]; then
			node_clear $((depth + 1)) NAMESPACES namespaces

			$dryrun rmdir $node_path
		else
			errexit "unexpected path $node_path"
		fi
		;;

	NAMESPACES)
		for n in $(ls $node_path); do
			node_clear $((depth + 1)) NS ${n##*/}
		done
		;;

	NS)
		$dryrun rmdir $node_path
		;;

	*)
		errexit "unknown node type $ndtype"
		;;
	esac

	debug_print $depth '<='
	node_path=$saved_path
}

node_show() {
	local saved_path=$node_path
	local ndtype ndname depth

	read -r depth ndtype ndname <<< $*
	node_path=$node_path/$ndname

	debug_print $depth '=>'
	printf "%*s" $((depth * 4)) ' '

	case $ndtype in
	PORTS)
		$dryrun printf "$ndname:\n"

		local p
		for p in $(ls $node_path); do
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
		for s in $(ls $node_path); do
			node_show $((depth + 1)) SUBSYS ${s##*/}
		done
		;;

	SUBSYS)
		if [ -h $node_path ]; then
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
		for n in $(ls $node_path); do
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
		$dryrun printf "%-16s %s\n" "$ndname:" $(cat $node_path)
		;;

	*)
		errexit "unknown node type $ndtype"
		;;
	esac

	debug_print $depth '<='
	node_path=$saved_path
}

nvmet_create() {
	node_path=$nvmet_path
	for i in ${!nvmet_disk[*]}; do
		read -r devpath pt subsys ns <<< ${nvmet_disk[$i]}
		node_create 1 PORT ports/$pt ${nvmet_port[$pt]}
		node_create 1 SUBSYS subsystems/$subsys 0
		node_create 1 NS subsystems/$subsys/namespaces/$ns $devpath

		[ ! -e $nvmet_path/ports/$pt/subsystems/$subsys ] \
			&& $dryrun ln -s $nvmet_path/subsystems/$subsys \
		    $nvmet_path/ports/$pt/subsystems/$subsys
	done
}

nvmet_clear() {
	node_path=$nvmet_path
	node_clear 1 PORTS ports
	node_clear 1 SUBSYSTEMS subsystems
}

nvmet_show() {
	node_path=$nvmet_path
	node_show 1 PORTS ports
	node_show 1 SUBSYSTEMS subsystems
}

while getopts "hnd" opt; do
	case $opt in
	h)	usage;;
	n)	dryrun=echo;;
	d)	debug=1;;
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

	clear|clr)
		nvmet_clear
		;;
	list|ls)
		nvmet_show
		;;
	*)
		errexit "unknow options $1"
		;;
esac
