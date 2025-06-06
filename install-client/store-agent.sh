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

safe_cp() {
	new=$1
	old=$2/$(basename $new)
	if [ -e $old ]; then
		runcmd mv $old ${old}.orig
	fi
	runcmd cp -f $new $old
}

errexit() {
	printf "$*\n"
	exit 1
}

apt_install() {
	runcmd apt install -y $*
}

apt_remove() {
	runcmd apt remove -y $*
}

cmd_run() {
	runcmd $*
}

nvme_config_discovery() {
	local discovery=$1

	# delete existing config lines
	runcmd "sed -i '/^--/d' /etc/nvme/discovery.conf"

	while read line; do
		local netmask=$(echo $line | \
			sed -n 's/.*--host-traddr=\([^ ]*\).*/\1/p')

		host=$(ip addr show to $netmask | awk '/inet / {print $2}')
		host=${host%%/*}
		if [ -z "$host" ]; then
			errexit "can't find $netmask"
		fi

		echo $line | \
			sed "s/--host-traddr=[^ ]*/--host-traddr=$host/" | \
			tee -a /etc/nvme/discovery.conf
	done < $discovery
}

etc_install_one() {
	local file=$1

	case $(basename $file) in
	# lfs install
	*lustre.conf)
		runcmd cp -f $file /etc/modprobe.d/lustre.conf
		#runcmd modprobe lustre
		;;
	*.mount)
		unit=$(basename $file)
		runcmd cp -f $file /etc/systemd/system/
		runcmd systemctl enable $unit
		runcmd systemctl start $unit
		;;
	*.target)
		unit=$(basename $file)
		runcmd cp -f $file /etc/systemd/system/
		runcmd systemctl enable $unit
		runcmd systemctl start $unit
		;;

	# nvme install
	nvme-rdma.ko | nvme_rdma.ko)
		safe_cp $file /lib/modules/$(uname -r)/updates/dkms/
		module=$(basename $file .ko)
		runcmd modprobe -r $module
		runcmd modprobe $module
		;;
	*discovery.conf)
		nvme_config_discovery $file
		runcmd nvme connect-all
		;;

	# lvm install
	sanlock)
		safe_cp $file /etc/default/
		runcmd systemctl stop wdmd
		runcmd systemctl disable wdmd
		runcmd systemctl restart sanlock
		;;
	lvmlocal.conf)
		hn=$(hostname)
		case $hn in
		gpu-a800-*)
			id=${hn##*-}
			id=$((id + 1000))	# distinguish with h800 ids
			;;
		gpu-h800-*)
			id=${hn##*-}
			;;
		hcyb-*)
			id=${hn##*-*0}		# for test only
			;;
		*)
			errexit "hostname invalid"
			;;
		esac
		runcmd "sed -i -e 's/# host_id = 0$/host_id = $id/g' $file"

		# no need to restart lvmlockd since host id is accessed
		# when vgchange is run.
		#runcmd systemctl restart lvmlockd
		;;
	lvm.conf)
		safe_cp $file /etc/lvm/
		;;
	*)
		errexit "unkonwn file: $file"
		;;
	esac
}

etc_install() {
	for file in $*; do
		etc_install_one $file
	done
}

etc_uninstall_one() {
	local file=$1

	case $(basename $file) in
	# lfs uninstall
	*lustre.conf)
		runcmd rmmod lustre
		runcmd "cat /dev/null > /etc/modprobe.d/lustre.conf"
		;;
	*.mount)
		unit=$(basename $file)
		runcmd systemctl stop $unit
		runcmd systemctl disable $unit
		runcmd rm -f /etc/systemd/system/$unit
		;;
	*.target)
		unit=$(basename $file)
		runcmd systemctl stop $unit 
		runcmd systemctl disable $unit
		runcmd rm -f /etc/systemd/system/$unit
		;;

	# nvme uninstall
	nvme-rdma.ko | nvme_rdma.ko)
		module=$(basename $file .ko)
		runcmd rmmod $module
		;;
	*discovery.conf)
		runcmd nvme disconnect-all
		runcmd "cat /dev/null > /etc/nvme/discovery.conf"
		;;

	# lvm uninstall
	sanlock)
		runcmd systemctl stop sanlock
		runcmd systemctl disable sanlock
		;;
	lvmlocal.conf)
		runcmd systemctl stop lvmlockd
		runcmd systemctl disable lvmlockd
		;;
	lvm.conf)
		;;
	*)
		errexit "unkonwn file: $file"
		;;
	esac
}

etc_uninstall() {
	for file in $*; do
		etc_uninstall_one $file
	done
}

host_check() {
	local machine=$1

	case $machine in
	a800)
		cnt=$(hostname | grep a800 | wc -l)
		if [ $cnt -eq 0 ]; then
			errexit "hostname mismatch"
		fi

		cnt=$(ip addr show to 10.2.0.0/24 | wc -l)
		if [ $cnt -eq 0 ]; then
			errexit "ip address mismatch"
		fi
		;;
	h800)
		cnt=$(hostname | grep h800 | wc -l)
		if [ $cnt -eq 0 ]; then
			errexit "hostname mismatch"
		fi

		cnt=$(ip addr show to 10.2.1.0/24 | wc -l)
		if [ $cnt -eq 0 ]; then
			errexit "ip address mismatch"
		fi
		;;
	4090)
		;;
	cpu)
		;;
	*)
		errexit "unknown machine type $machine"
		;;
	esac
}

if [ "x$CLIENT_DEBUG" == "x1" ]; then
	debug=1
fi

echo "$*"

oper=$1; shift 1
case $oper in
'apt_install')		apt_install $*		;;
'apt_remove') 		apt_remove $*		;;

'cmd_run')		cmd_run $*		;;

'etc_install')		etc_install $*		;;
'etc_uninstall')	etc_uninstall $*	;;

'host_check')		host_check $*		;;

*)			errexit "unknown op: $oper";;
esac
