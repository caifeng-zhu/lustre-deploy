#!/bin/bash

set -e

debug=0

runcmd() {
	echo "-> $*" >&2
	if [ $debug -eq 1 ]; then
		return
	fi
	eval "$*"
}

errexit() {
	printf "$*\n"
	exit 1
}

cmd_run() {
	runcmd $*
}

cmd_exist() {
	local cmd=$1
	which $cmd | wc -l
}

apt_install() {
	runcmd apt install -y $*
}

apt_uninstall() {
	runcmd apt remove -y $*
}

lfs_add_networks() {
	local net nics cfgval

	cfgval=""
	while [ ${#*} -gt 0 ]; do
		net=$1
		nics=$2
		shift 2
		cfgval+="$net($nics),"
	done
	cfgval=${cfgval%,}

	echo "options lnet networks=$cfgval" | tee /etc/modprobe.d/lustre.conf
}

lfs_del_networks() {
	local cfgpath=/etc/modprobe.d/lustre.conf

	if [ -e /sys/module/lustre ]; then
		runcmd rmmod lustre
	fi

	if [ -e $cfgpath ]; then
		runcmd rm -f $cfgpath
	fi
}

lfs_chk_networks() {
	local net nics

	while [ ${#*} -gt 0 ]; do
		net=$1
		nics=$2
		shift 2

		net=${net%[0-9]}
		ipaddr=$(ip -4 -br addr show dev $nics | awk '$2=="UP" {print $3}' | sed -e 's/\/.*$//g')
		if [ -z $ipaddr ]; then
			errexit "can't find ipaddr from $nics"
		fi

		n=$(lctl list_nids | grep "$ipaddr@$net" | wc -l)
		if [ $n -ne 1 ]; then
			errexit "list nids $ipaddr@$net error"
		fi
	done
}

lfs_dump_networks() {
	runcmd lctl list_nids
}

lfs_add_routes() {
	local cfgval net nid

	cfgval=""
	while [ ${#*} -gt 0 ]; do
		net=$1
		nid=$2
		shift 2
		cfgval+="$net $nid;"
	done
	cfgval=${cfgval%;}

	echo "options lnet routes=\"$cfgval\"" | tee -a /etc/modprobe.d/lustre.conf
}

lfs_del_routes() {
	return
}

lfs_chk_routes() {
	local net nid

	while [ ${#*} -gt 0 ]; do
		net=$1
		nid=$2
		shift 2

		n=$(lnetctl route show --net $net --gateway $nid | grep "gateway: $nid" | wc -l)
		if [ $n -eq 0 ]; then
			errexit "show route net=$net gateway=$nid error"
		fi
	done
}

lfs_dump_routes() {
	runcmd lnetctl route show
}

lfs_add_mount() {
	local srcpath=$1
	local dstpath=$(realpath $2)
	local options=$3
	local srvname=$(echo $dstpath | sed -e 's|^/||' -e 's|/|-|g')

	cat > "/etc/systemd/system/$srvname.mount" <<EOF
[Unit]
Description=Mount ${srcpath} to ${dstpath}
Requires=network-online.target
After=network-online.target

[Mount]
What=${srcpath}
Where=${dstpath}
Type=lustre
Options=${options}
TimeoutSec=60

[Install]
WantedBy=multi-user.target
EOF
}

lfs_del_mount() {
	local dstpath=$(realpath $1)
	local srvname=$(echo $dstpath | sed 's|^/||; s|/|-|g')
	local srvpath=/etc/systemd/system/$srvname.mount

	if [ -e $srvpath ]; then
		runcmd rm -f $srvpath
	fi
}

lfs_find_mount() {
	local srcpath=$1
	local dstpath=$2

	runcmd findmnt -n --source $srcpath --target $dstpath --type lustre | wc -l
}

lfs_start_mount() {
	local srcpath=$1
	local dstpath=$(realpath $2)
	local srvname=$(echo $dstpath | sed 's|^/||; s|/|-|g')

	runcmd systemctl enable $srvname.mount --now

	n=$(lfs_find_mount $srcpath $dstpath)
	if [ $n -eq 0 ]; then
		errexit "mount $srcpath to $dstpath failed"
	fi
}

lfs_stop_mount() {
	local srcpath=$1
	local dstpath=$(realpath $2)
	local srvname=$(echo $dstpath | sed 's|^/||; s|/|-|g')
	local srvpath=/etc/systemd/system/$srvname.mount

	if [ -e $srvpath ]; then
		runcmd systemctl disable $srvname.mount --now
	fi

	n=$(lfs_find_mount $srcpath $dstpath)
	if [ $n -ne 0 ]; then
		errexit "unmount $dstpath failed"
	fi
}

lfs_dump_mounts() {
	runcmd mount -t lustre
}

lvm_add_nvmets() {
	local traddr htraddr transport trsvcid append
	local cfgline="--nr-io-queues=4 --ctrl-loss-tmo=20 --reconnect-delay=1 --keep-alive-tmo=1"

	append=""
	while [ ${#*} -gt 0 ]; do
		traddr=$1
		htraddr=$2
		transport=$3
		trsvcid=$4
		shift 4

		htraddr=$(ip -4 -br addr show to $htraddr | awk '$2=="UP" {print $3}' | sed -e 's/\/.*$//g')
		if [ -z htraddr ]; then
			errexit "can't find $htraddr"
		fi

		echo "$cfgline --traddr=$traddr --host-traddr=$htraddr --transport=$transport --trsvcid=$trsvcid" | tee $append /etc/nvme/discovery.conf
		append='-a'
	done
}

lvm_del_nvmets() {
	runcmd rm -f /etc/nvme/discovery.conf
}

lvm_get_nvmets() {
	# the local nvme nqn formart is nqn.2019-10.com.kioxia:KCM6XRUL3T84
	# the remote nvme nqn format is n34-000:01:00.0
	# so NQN!=nqn.* is remote nvme connection
	runcmd nvme list-subsys | awk -F'NQN=' '{print $2}' | grep -v '^nqn\.'
}

lvm_start_nvmets() {
	runcmd systemctl enable nvmf-autoconnect.service
	runcmd nvme connect-all
}

lvm_stop_nvmets() {
	if [ $(cmd_exist nvme) -eq 1 ]; then
		runcmd nvme disconnect-all

		if [[ $(lvm_get_nvmets) -ne 0 ]]; then
			errexit 'nvme disconnect failed'
		fi
	fi
	runcmd systemctl disable nvmf-autoconnect.service
}

lvm_dump_nvmets() {
	if [ $(cmd_exist nvme) -eq 1 ]; then
		runcmd nvme list-subsys
	fi
}

lvm_add_iscsits() {
        local iqn=$1
        local addr=$2
        local port=$3
	runcmd iscsiadm -m discovery -t st -p $addr:$port
}

lvm_del_iscsits() {
        local iqn=$1
        local addr=$2
        local port=$3

	if [ -d /etc/iscsi/nodes/$iqn ] && [ -d /etc/iscsi/send_targets/"$addr,$port" ]; then
		runcmd iscsiadm -m discoverydb -t st -p $addr:$port -o delete
	fi
}

lvm_start_iscsits() {
        local iqn=$1
        local addr=$2
        local port=$3
	if ! $(iscsiadm -m session 2>/dev/null | grep -q "$addr:$port.*$iqn"); then
		runcmd iscsiadm -m node -l -T $iqn -p $addr:$port
	fi
}

lvm_stop_iscsits() {
        local iqn=$1
        local addr=$2
        local port=$3
	if $(iscsiadm -m session 2>/dev/null | grep -q "$addr:$port.*$iqn"); then
		runcmd iscsiadm -m node -u -T $iqn -p $addr:$port
	fi
}

lvm_dump_iscsits() {
	runcmd iscsiadm -m session
	runcmd iscsiadm -m node
}

lvm_add_vg() {
	local vg=$1
	local hn id idbase

	hn=$(hostname)
	case $hn in
	gpu-a800-*)
		idbase=1000
		;;
        gpu-h800-*)
		idbase=0
                ;;
        cpu-*)
		idbase=0	# for test
                ;;
        *)
                errexit "hostname invalid"
                ;;
	esac
	id=${hn##*-}
	id=$((10#$id + idbase))	# distinguish a800 with h800

	cat > "/etc/lvm/lvmlocal.conf" << EOF
local {
	host_id = $id
}
EOF
}

lvm_del_vg() {
	runcmd "cat /dev/null > /etc/lvm/lvmlocal.conf"
}

lvm_start_vg() {
	local vg=$1

	if ! ls /dev/mapper/*-lvmlock > /dev/null 2>&1; then
		runcmd systemctl disable wdmd --now

		runcmd systemctl enable sanlock
		runcmd systemctl restart sanlock
		runcmd systemctl enable lvmlockd
		runcmd systemctl restart lvmlockd
		runcmd systemctl enable lvmagent.service --now
	fi

	runcmd vgchange --lockstart $vg
	if [ ! -e /dev/mapper/$vg-lvmlock ]; then
		errexit "start vg=$vg failed"
	fi
}

lvm_stop_vg() {
	local vg=$1

	if [ -e /dev/mapper/$vg-lvmlock ]; then
		runcmd vgchange -an $vg
		runcmd vgchange --lockstop $vg
	fi
	if [ -e /dev/mapper/$vg-lvmlock ]; then
		errexit "stop vg=$vg failed"
	fi

	runcmd systemctl disable lvmagent.service --now
	runcmd systemctl disable lvmlockd --now
	runcmd systemctl disable sanlock --now
}

lvm_dump_vgs() {
	runcmd vgs
	if [ $(cmd_exist lvmlockctl) -eq 1 ]; then
		runcmd lvmlockctl -i
	fi
	if [ $(cmd_exist sanlock) -eq 1 ]; then
		runcmd sanlock client status
	fi
}

if [ "x$CLIENT_DEBUG" == "x1" ]; then
	debug=1
fi

echo "$*"

oper=$1; shift 1
case $oper in
'apt_install')			apt_install $*			;;
'apt_uninstall') 		apt_uninstall $*		;;
'cmd_run')			cmd_run $*			;;
'lfs_add_networks')		lfs_add_networks $*		;;
'lfs_del_networks')		lfs_del_networks $*		;;
'lfs_chk_networks')		lfs_chk_networks $*		;;
'lfs_dump_networks')		lfs_dump_networks $*		;;
'lfs_add_routes')		lfs_add_routes $*		;;
'lfs_del_routes')		lfs_del_routes $*		;;
'lfs_chk_routes')		lfs_chk_routes $*		;;
'lfs_dump_routes')		lfs_dump_routes $*		;;
'lfs_add_mount')		lfs_add_mount $*		;;
'lfs_del_mount')		lfs_del_mount $*		;;
'lfs_start_mount')		lfs_start_mount $*		;;
'lfs_stop_mount')		lfs_stop_mount $*		;;
'lfs_dump_mounts')		lfs_dump_mounts $*		;;
'lvm_add_nvmets')		lvm_add_nvmets $*		;;
'lvm_del_nvmets')		lvm_del_nvmets $*		;;
'lvm_start_nvmets')		lvm_start_nvmets $*		;;
'lvm_stop_nvmets')		lvm_stop_nvmets $*		;;
'lvm_dump_nvmets')		lvm_dump_nvmets $*		;;
'lvm_add_iscsits')		lvm_add_iscsits $*		;;
'lvm_del_iscsits')		lvm_del_iscsits $*		;;
'lvm_start_iscsits')		lvm_start_iscsits $*		;;
'lvm_stop_iscsits')		lvm_stop_iscsits $*		;;
'lvm_dump_iscsits')		lvm_dump_iscsits $*		;;
'lvm_add_vg')			lvm_add_vg $*			;;
'lvm_del_vg')			lvm_del_vg $*			;;
'lvm_start_vg')			lvm_start_vg $*			;;
'lvm_stop_vg')			lvm_stop_vg $*			;;
'lvm_dump_vgs')			lvm_dump_vgs $*			;;
*)				errexit "unknown op: $oper"	;;
esac
