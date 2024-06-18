#!/bin/bash

GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PINK='\e[1;35m'
RESET='\033[0m'
CYAN='\033[36m'
MAGENTA='\033[35m'
WHITE='\033[37m'

nvmet_config_path="/sys/kernel/config/nvmet"
dryrun=

source ./nvmet.conf

errexit() {
	printf "$*\n"
	exit 1
}

dir_is_empty() {
	return `ls -A $1 | wc -w`
}

write_file() {
	var=$1
	file=$2

	[ -n "$dryrun" ] && $dryrun echo $var \> $file || echo $var > $file
}

component_destroy() {
	local dir=$1
	shift
	local cmds=("$@")

	if dir_is_empty "`pwd`/$dir"; then
		printf "%s has been empty\n" "`pwd`/$dir"
	else
		spushd $dir

		for cmd in "${cmds[@]}"; do
			$cmd
		done

		spopd $dir
	fi
}

usage() {
	less -F <<EOF
${0##*/} create [-n --dryrun]
${0##*/} ls [-n --dryrun]
${0##*/} clear [-n --dryrun]
EOF
	exit 1
}

show() {
	case $1 in
		lv0)
			printf "+- /\n"
			;;
		lv1-d)
			printf "  +-$PINK %s $RESET\n" "$2"
			;;
		lv1-f)
			;;
		lv2-d)
			printf "  | +-  $WHITE%s$RESET" "$2"
			;;
		lv2-f)
			printf "  $GREEN[ %s ]$RESET \n" "$2"
			;;
		lv3-d)
			printf "  |    +-  $YELLOW%s$RESET\n" "$2"
			;;
		lv3-f)
			;;
		lv4-d)
			printf "  |      $CYAN%s$RESET" "$2"
			;;
		lv4-l)
			printf "  |      $CYAN%s$RESET\n" "$2"
			;;
		lv4-f)
			printf "  $GREEN[ %s ]$RESET \n" "$2"
			;;
	esac
}

srmdir() {
	 $dryrun rmdir --ignore-fail-on-non-empty $1
}

smkdir() {
	mkdir -p $1
}

spushd() {
	if [ ! -e $1 ]; then
		smkdir $1
	fi

	pushd $1 > /dev/null
}

spopd()
{
	popd > /dev/null

	if [ -n "$dryrun" ] && [ -n "$1" ]; then
		rmdir `pwd`/$1 &> /dev/null && [ -n "$2" ] && rmdir `pwd`/$2 &> /dev/null
	fi
}

port_create() {
	read -r port trtype traddr trsvcid adrfam <<< $*

	[ -e ports/$port ] && return

	spushd ports/$port

	for var in trtype traddr trsvcid adrfam; do
		write_file ${!var} "`pwd`/addr_$var"
	done

	spopd ports/$port
}

nvmet_create_ports() {
	for i in ${!nvmet_port[*]}; do
		port_create ${nvmet_port[$i]}
	done
}

subsys_create() {
	subnqn=$1

	[ -e subsystems/$subnqn ] && return

	spushd subsystems/$subnqn

	write_file 1 "`pwd`/attr_allow_any_host"

	spopd subsystems/$subnqn
}

namespace_create() {
	read -r subnqn ns path uuid <<< $*

	[ -e subsystems/$subnqn/namespaces/$ns ] && return

	spushd subsystems/$subnqn/namespaces/$ns

	for var in path uuid; do
		write_file ${!var} "`pwd`/device_$var"
	done
	write_file 1 "`pwd`/enable"

	spopd "subsystems/$subnqn/namespaces/$ns" "subsystems/$subnqn"
}

link_create() {
	read -r port subnqn <<< $*

	[ -e ports/$port/subsystems/$subnqn ] && return

	$dryrun ln -s `pwd`/subsystems/$subnqn `pwd`/ports/$port/subsystems/$subnqn
}

nvmet_export_device_one() {
	read -r dev subnqn ns port uuid <<< $*

	subsys_create $subnqn
	namespace_create $subnqn $ns $dev $uuid
	link_create $port $subnqn
}

nvmet_export_devices() {
	for i in ${!nvmet_disk[*]}; do
		nvmet_export_device_one ${nvmet_disk[$i]}
	done
}

nvmet_create() {
	nvmet_create_ports
	nvmet_export_devices
}

link_destroy() {
	dir_is_empty ./*/subsystems && return

	for path in `pwd`/*/subsystems/*; do
		$dryrun unlink $path
	done
}

namesapce_destroy() {
	dir_is_empty ./*/namespaces && return

	for path in `pwd`/*/namespaces/*; do
		srmdir $path
	done
}

subsys_destroy() {
	for path in `pwd`/*; do
		srmdir $path
	done
}

nvmet_clear_devices() {
	component_destroy "ports" "link_destroy"
	component_destroy "subsystems" "namesapce_destroy" "subsys_destroy"
}

port_destroy() {
	for path in `pwd`/*; do
		 srmdir $path
	done
}

nvmet_destroy_ports() {
	if dir_is_empty ./ports; then
		printf "%s/ports has been empty\n" `pwd`
	else
		spushd ports

		port_destroy

		spopd ports
	fi
}

nvmet_clear() {
	nvmet_clear_devices
	nvmet_destroy_ports
}

port_show_attr() {
	read trtype < ./addr_trtype
        read traddr < ./addr_traddr
	read trsvcid < ./addr_trsvcid
	read dsize < ./param_inline_data_size

	show lv2-f "trtype=$trtype, traddr=$traddr, trsvcid=$trsvcid, inline_data_size=$dsize"
}

port_show_link_subsys() {
	show lv3-d "subsystems"

	for subsys in ./subsystems/*; do
		show lv4-l "$(basename $subsys)"
	done
}

nvmet_show_port_one() {
	port=$1

	show lv2-d "$(basename $port)"

	spushd $port

	port_show_attr
	port_show_link_subsys

	spopd $port
}

nvmet_show_ports() {
	show lv1-d "ports"

	dir_is_empty ./ports && return

	spushd ports

	for port in ./*; do
		nvmet_show_port_one $port
	done

	spopd ports
}

subsys_show_attr() {
	read version < ./attr_version
	read allow_any < ./attr_allow_any_host
	read serial < ./attr_serial

	show lv2-f "version=$version, allow_any=$allow_any, serial=$serial"
}

namespace_show_attr() {
	read path < ./device_path
	read uuid < ./device_path
	read grpid < ./ana_grpid
	read enable < ./enable

	enable=$( ((enable)) && echo "enable" || echo "disable" )

	show lv4-f "path=$path, uuid=$uuid, grpid=$grpid, $enable"
}

subsys_show_namespace_one() {
	ns=$1

	show lv4-d "$(basename $ns)"

	dir_is_empty ./$ns && return

	spushd $ns

	namespace_show_attr

	spopd $ns
}

subsys_show_namespaces() {
	show lv3-d "namespaces"

	dir_is_empty ./namespaces && return

	spushd namespaces

	for ns in ./*; do
		subsys_show_namespace_one $ns
	done

	spopd namespaces
}

nvmet_show_subsys_one() {
	subsys=$1

	show lv2-d "$(basename $subsys)"

	dir_is_empty ./$(basename $subsys) && return

	spushd $subsys

	subsys_show_attr
	subsys_show_namespaces

	spopd $subsys
}

nvmet_show_subsystems() {
	show lv1-d "subsystems"

	dir_is_empty ./subsystems && return

	spushd subsystems

	for subsys in ./*; do
		nvmet_show_subsys_one $subsys
	done

	spopd subsystems
}

nvmet_show() {
	show lv0

	nvmet_show_ports
	nvmet_show_subsystems
}

if [[ $2 == "-n" || $2 == "--dryrun" ]]; then
	dryrun=echo
fi

spushd $nvmet_config_path
case $1 in
	-h)
		usage
		;;
	create)
		nvmet_create
		;;
	clear)
		nvmet_clear
		;;
	ls)
		nvmet_show
		;;
	*)
		errexit "unknow options $1"
		;;
esac

spopd $nvmet_config_path
