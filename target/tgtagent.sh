#!/bin/bash

set -e

STRIPESIZE=1024		# 1M in unit of K bytes

oper=

debug=0

errexit() {
	echo "$*" >&2
	exit 1
}

runcmd() {
	echo "-- $@" >&2
	if [ $debug -eq 1 ]; then
		return
	fi
	eval "$@"
}

wait_device() {
	local devpath=$1
	udevadm settle --exit-if-exists $devpath
}

apt_install() {
	runcmd apt install -y $*
}

apt_remove() {
	runcmd apt remove -y $*
}

nvmet_port_create() {
	local portid=$1
	local traddr=$2
	local trsvcid=$3
	local transport=$4

	runcmd modprobe nvmet-$transport

	case $mode in
	active)
		runcmd nvmetcli /ports create $portid
		runcmd nvmetcli /ports/$portid set addr traddr=$traddr
		runcmd nvmetcli /ports/$portid set addr trsvcid=$trsvcid
		runcmd nvmetcli /ports/$portid set addr trtype=$transport
		runcmd nvmetcli /ports/$portid set addr adrfam=ipv4
		;;
	client)
		hostaddr=$(ip addr show to $traddr/24 | sed -n '2p' | awk '{ print $2 }')
		hostaddr=${hostaddr%%/*}

		entry="--transport=$transport "
		entry+="--traddr=$traddr "
		entry+="--trsvcid=$trsvcid "
		entry+="--host-traddr=$hostaddr "
		entry+="--nr-io-queues=4 --ctrl-loss-tmo=3 --reconnect-delay=1 --keep-alive-tmo=1 "
		entry+="--persistent"

		sed -i "/$entry/d" /etc/nvme/discovery.conf
		echo $entry | tee -a /etc/nvme/discovery.conf
		;;
	esac
}

nvmet_port_destroy() {
	local portid=$1
	local traddr=$2
	local trsvcid=$3
	local transport=$4

	case $mode in
	active)
		# active side destroy all with 'nvmetcli clear'
		;;
	client)
		hostaddr=$(ip addr show to $traddr/24 | sed -n '2p' | awk '{ print $2 }')
		hostaddr=${hostaddr%%/*}

		entry="--transport=$transport "
		entry+="--traddr=$traddr "
		entry+="--trsvcid=$trsvcid "

		echo "delete nvme discovery entry: $entry"
		sed -i "/$entry/d" /etc/nvme/discovery.conf
		;;
	esac
}

nvmet_port_add_subsys() {
	local portid=$1
	local traddr=$2
	local trsvcid=$3
	local transport=$4
	local nqn=$5

	case $mode in
	active)
		runcmd nvmetcli /ports/$portid/subsystems create $nqn
		;;
	client)
		hostaddr=$(ip addr show to $traddr/24 | sed -n '2p' | awk '{ print $2 }')
		hostaddr=${hostaddr%%/*}
		runcmd nvme connect --nqn $nqn --traddr $traddr --trsvcid $trsvcid --transport $transport \
			--nr-io-queues=4 --ctrl-loss-tmo=3 --reconnect-delay=1 --keep-alive-tmo=1
		;;
	esac
}

nvmet_port_del_subsys() {
	local portid=$1
	local traddr=$2
	local trsvcid=$3
	local transport=$4
	local nqn=$5

	case $mode in
	active)
		;;
	client)
		runcmd nvme disconnect --nqn $nqn
		;;
	esac
}

nvmet_subsys_create() {
	local nqn=$1
	local offload=$2

	case $mode in
	active)
		runcmd nvmetcli /subsystems create $nqn
		runcmd nvmetcli /subsystems/$nqn set attr allow_any_host=1
		if [ $offload -ne 0 ]; then
		    runcmd nvmetcli /subsystems/$nqn set attr offload=1
		fi
		;;
	client)
		;;
	esac
}

nvmet_namespace_create() {
	local nqn=$1
	local ns=$2
	local devpath=$3

	case $mode in
	active)
		runcmd nvmetcli /subsystems/$nqn/namespaces create $ns
		runcmd nvmetcli /subsystems/$nqn/namespaces/$ns set device path=$devpath
		runcmd nvmetcli /subsystems/$nqn/namespaces/$ns enable
		;;
	client)
		;;
	esac
}

nvmet_saveconfig() {
	case $mode in
	active)
		runcmd nvmetcli / saveconfig
		;;
	client)
		;;
	esac
}

nvmet_clear() {
	case $mode in
	active)
		runcmd nvmetcli clear
		;;
	client)
		;;
	esac
}

iscsit_iqn_create() {
	local iqn=$1

	case $mode in
	active)
		runcmd targetcli /iscsi create $iqn
		runcmd targetcli /iscsi/$iqn/tpg1/portals delete 0.0.0.0 3260
		;;
	client)
		;;
	esac
}

iscsit_iqn_destroy() {
	local iqn=$1

	case $mode in
	active)
		;;
	client)
		;;
	esac
}

iscsit_portal_create() {
	local iqn=$1
	local addr=$2
	local port=$3

	case $mode in
	active)
		runcmd targetcli /iscsi/$iqn/tpg1/portals create $addr $port
		;;
	client)
		;;
	esac
}

iscsit_portal_connect() {
	local iqn=$1
	local addr=$2
	local port=$3

	runcmd iscsiadm -m discovery -t st -p $addr:$port
	runcmd iscsiadm -m node -l -T $iqn -p $addr:$port
}

iscsit_portal_disconnect() {
	local iqn=$1
	local addr=$2
	local port=$3

	set +e	# ignore error
	runcmd iscsiadm -m node -u -T $iqn -p $addr:$port
	runcmd iscsiadm -m discoverydb -t st -p $addr:$port -o delete
	set -e
}

iscsit_portal_destroy() {
	local iqn=$1
	local addr=$2
	local port=$3

	case $mode in
	active)
		# active side destroy by 'targetctl clear'
		;;
	client)
		;;
	esac
}

iscsit_acl_create() {
	local iqn=$1
	local acl=$2

	case $mode in
	active)
		runcmd targetcli /iscsi/$iqn/tpg1/acls create $acl
		;;
	client)
		;;
	esac
}

iscsit_lun_create() {
	local iqn=$1
	local lunid=$2
	local lunpath=$3

	case $mode in
	active)
		runcmd targetcli /backstores/block create $lunid $lunpath
		runcmd targetcli /iscsi/$iqn/tpg1/luns create /backstores/block/$lunid
		;;
	client)
		;;
	esac
}

iscsit_saveconfig() {
	case $mode in
	active)
		runcmd targetcli / saveconfig
		;;
	client)
		;;
	esac
}

iscsit_clear() {
	case $mode in
	active)
		runcmd targetctl clear
		;;
	client)
		;;
	esac
}

parted_label() {
	local disk=$1

	case $mode in
	active)
		runcmd wipefs -a $disk
		runcmd parted -s $disk mklabel gpt
		;;
	backup)
		runcmd partprobe $disk
		;;
	esac
}

parted_mkpart() {
	local disk=$1
	local partname=$2
	local partstart=$3
	local partend=$4

	case $mode in
	active)
		runcmd parted -s $disk mkpart $partname $partstart $partend
		;;
	backup)
		runcmd partprobe $disk
		;;
	esac
}

parted_rm() {
	local disk=$1
	local part=$2

	if [ ! -e $disk ]; then
		return 0
	fi

	partnum=$(parted -m $disk print | awk -F: -v p=$part '$0 ~ p { print $1 }')
	if [ -z "$partnum" ]; then
		return 0
	fi

	runcmd parted -s $disk rm $partnum
	return 0
}

mdraid_start() {
	local tgtname=$1
	local volname=$2

	if [ -e /etc/mdadm/${tgtname}.conf ]; then
		runcmd mdadm --assemble /dev/md/$volname --conf /etc/mdadm/${tgtname}.conf --force
		wait_device /dev/md/$volname
		return 0
	fi
	return -1
}

mdraid_stop() {
	local volname=$1

	if [ -e /dev/md/$volname ]; then
		runcmd mdadm --stop /dev/md/$volname
	fi
}

mdraid_create() {
	local volname=$1
	local level=$2
	shift 2
	local devices=( $* )

	level=${level##raid}
	for dev in ${devices[@]}; do
		wait_device $dev
	done

	case $mode in
	active)
		set -x
		local opt_chunk=''
		local chunksize=0
		local ndevice=${#devices[@]}
		case $level in
		5) 	chunksize=$((STRIPESIZE / (ndevice -1)));;
		6) 	chunksize=$((STRIPESIZE / (ndevice - 2)));;
		esac
		if [ $chunksize -ne 0 ]; then
			opt_chunk="--chunk=${chunksize}K"
		fi

		runcmd mdadm --create $volname --run --quiet --force --homehost=any \
			--data-offset=1M --level=$level $opt_chunk \
			-n ${#devices[@]} ${devices[@]}
		wait_device /dev/md/$volname
		set +x
		;;
	backup)
		;;
	esac
}

mdraid_destroy() {
	local volname=$1
	local level=$2
	shift 2
	local devices=( $* )

	case $mode in
	active|backup)
		mdraid_stop $volname

		# erase existent md signature if any.
		for dev in ${devices[@]}; do
			if [ ! -e $dev ]; then
				continue
			fi
			if mdadm --query $dev |  grep -q -E 'device .* in .* array'; then
				runcmd mdadm --zero-superblock $dev
			fi
		done
		;;
	esac
}

mdraid_new_config() {
	local tgtname=$1

	if grep -q -- 'AUTO -1.x' /etc/mdadm/mdadm.conf; then
		true
	else
		echo 'AUTO -1.x' | tee -a /etc/mdadm/mdadm.conf
	fi
	runcmd mdadm --examine --scan | grep "$tgtname-" | tee /etc/mdadm/$tgtname.conf
}

mdraid_del_config() {
	local tgtname=$1

	if [ -e "/etc/mdadm/$tgtname.conf" ]; then
		runcmd rm -f /etc/mdadm/$tgtname.conf
	fi
}

lustre_nidopt() {
	local opt=$1
	local nids=$2

	printf -- "$opt=%s " $(echo $nids | tr ':' ' ')
}

lustre_mount() {
	local mountdev=$1
	local mountpoint=$2

	if [ ! -e $mountpoint ]; then
		runcmd mkdir -p $mountpoint
	fi
	runcmd mount -t lustre $mountdev $mountpoint
}

lustre_umount() {
	local mountpoint=$1

	if findmnt -lc | grep -q $mountpoint; then
		runcmd umount -f $mountpoint
	fi
}

ldiskfs_mgt_create() {
	local lfsname=$1
	local tgtname=$2
	local svcnids=$3
	local mgsnids=$4
	local dvol=$5

	mdraid_new_config $tgtname

	case $mode in
	active)
		local opt_svcnids=$(lustre_nidopt '--servicenode' $svcnids)
		local opt_mgsnids=$(lustre_nidopt '--mgsnode' $mgsnids)
		runcmd "mkfs.lustre --mgs \
			--fsname=$lfsname --reformat --backfstype=ldiskfs \
			$opt_svcnids \
			--mkfsoptions='-E lazy_itable_init=1,nodiscard' \
			$dvol"
		lustre_mount $dvol /var/lib/lustre/$lfsname/$tgtname
		;;
	backup)
		runcmd mkdir -p /var/lib/lustre/$lfsname/$tgtname
		;;
	esac
}

ldiskfs_mdt_create() {
	local lfsname=$1
	local tgtname=$2
	local svcnids=$3
	local mgsnids=$4
	local dvol=$5

	mdraid_new_config $tgtname

	case $mode in
	active)
		local opt_svcnids=$(lustre_nidopt '--servicenode' $svcnids)
		local opt_mgsnids=$(lustre_nidopt '--mgsnode' $mgsnids)
		runcmd "mkfs.lustre --mdt --index=${tgtname#mdt} \
			--fsname=$lfsname --reformat --backfstype=ldiskfs \
			$opt_svcnids \
			$opt_mgsnids \
			--mkfsoptions='-E lazy_itable_init=1,nodiscard' \
			$dvol"
		lustre_mount $dvol /var/lib/lustre/$lfsname/$tgtname
		;;
	backup)
		runcmd mkdir -p /var/lib/lustre/$lfsname/$tgtname
		;;
	esac
}

ldiskfs_ost_create_mdraid() {
	local lfsname=$1
	local tgtname=$2
	local svcnids=$3
	local mgsnids=$4
	local dvol=$5
	local jvol=$6

	mdraid_new_config $tgtname

	case $mode in
	active)
		local opt_svcnids=$(lustre_nidopt '--servicenode' $svcnids)
		local opt_mgsnids=$(lustre_nidopt '--mgsnode' $mgsnids)

		runcmd mke2fs -O journal_dev -b 4096 $jvol

		mddev=$(basename $(realpath $dvol))
		chunk_size=$(cat /sys/block/$mddev/md/chunk_size)
		stride=$((chunk_size / 4096))
		runcmd "mkfs.lustre --ost --index=${tgtname#ost} \
			--fsname=$lfsname --reformat --backfstype=ldiskfs \
			$opt_svcnids \
			$opt_mgsnids \
			--mkfsoptions='-E lazy_itable_init=1,nodiscard,stride=$stride,stripe_width=256 -J device=$jvol' \
			--mountfsoptions='journal_path=$jvol' \
			$dvol"

		lustre_mount $dvol /var/lib/lustre/$lfsname/$tgtname
		;;
	backup)
		runcmd mkdir -p /var/lib/lustre/$lfsname/$tgtname
		;;
	esac

}

ldiskfs_ost_create_noraid() {
	local lfsname=$1
	local tgtname=$2
	local svcnids=$3
	local mgsnids=$4
	local dvol=$5

	case $mode in
	active)
		local opt_svcnids=$(lustre_nidopt '--servicenode' $svcnids)
		local opt_mgsnids=$(lustre_nidopt '--mgsnode' $mgsnids)

		runcmd "mkfs.lustre --ost --index=${tgtname#ost} \
			--fsname=$lfsname --reformat --backfstype=ldiskfs \
			$opt_svcnids \
			$opt_mgsnids \
			--mkfsoptions='-E lazy_itable_init=1,nodiscard' \
			$dvol"

		lustre_mount $dvol /var/lib/lustre/$lfsname/$tgtname
		;;
	backup)
		runcmd mkdir -p /var/lib/lustre/$lfsname/$tgtname
		;;
	esac
}

ldiskfs_ost_create() {
	local lfsname=$1
	local tgtname=$2
	local svcnids=$3
	local mgsnids=$4
	local dvol=$5
	local jvol=$6

	case $dvol in
	/dev/md/*)
		ldiskfs_ost_create_mdraid $lfsname $tgtname $svcnids $mgsnids $dvol $jvol
		;;
	*)
		ldiskfs_ost_create_noraid $lfsname $tgtname $svcnids $mgsnids $dvol
		;;
	esac
}

ldiskfs_tgt_destroy() {
	local lfsname=$1
	local tgtname=$2

	mdraid_del_config $tgtname

	case $mode in
	active)
		lustre_umount /var/lib/lustre/$lfsname/$tgtname
		;;
	esac
}

zpool_create() {
	local pool=$1
	shift 1
	local vdevs=( $* )

	if [ ! -e /sys/module/zfs ]; then
		runcmd modprobe zfs
	fi

	case $mode in
	active)
		if [ -e /proc/spl/kstat/zfs/$pool ]; then
			return 0
		fi
		runcmd zpool create -o multihost=on -o cachefile=none -o ashift=12 \
			-f $pool ${vdevs[@]}
		;;
	esac

}

zpool_destroy() {
	local pool=$1

	if [ ! -e /sys/module/zfs ]; then
		runcmd modprobe zfs
	fi

	if [ ! -e /proc/spl/kstat/zfs/$pool ]; then
		return 0
	fi

	if mount -t lustre | grep -q $pool; then
		# there is still user, so bail out
		return 0
	fi

	runcmd zpool destroy $pool
}

zfs_tgt_create() {
	local lfsname=$1
	local tgtname=$2
	local svcnids=$3
	local mgsnids=$4
	local dvol=$5

	case $mode in
	active)
		opt_svcnids=$(lustre_nidopt '--servicenode' $svcnids)
		opt_mgsnids=$(lustre_nidopt '--mgsnode' $mgsnids)
		case $tgtname in
		mgt)
			echo runcmd "mkfs.lustre --mgs
				--fsname=$lfsname --reformat --backfstype=zfs
				$opt_svcnids
				$dvol/$tgtname"
			;;
		mdt*)
			echo runcmd "mkfs.lustre --mdt --index=${tgtname#mdt}
				--fsname=$lfsname --reformat --backfstype=zfs
				$opt_svcnids
				$opt_mgsnids
				$dvol/$tgtname"
			;;
		ost*)
			echo runcmd "mkfs.lustre --ost --index=${tgtname#ost}
				--fsname=$lfsname --reformat --backfstype=zfs
				$opt_svcnids
				$opt_mgsnids
				$dvol/$tgtname"
			;;
		*)
			errexit "unknown target $tgtname"
			;;
		esac
		lustre_mount $dvol /var/lib/lustre/$lfsname/$tgtname
		;;
	backup)
		runcmd mkdir -p /var/lib/lustre/$lfsname/$tgtname
		;;
	esac
}

zfs_tgt_destroy() {
	local lfsname=$1
	local tgtname=$2

	case $mode in
	active)
		lustre_umount /var/lib/lustre/$lfsname/$tgtname
		;;
	esac
}

pcs_host_auth() {
	local name=$1
	local addr=$2
	local user=$3
	local passwd=$4

	runcmd pcs host auth $name addr=$addr -u $user -p $passwd
}

pcs_cluster_setup() {
	local name=$1
	shift 1
	local nameaddrs=( $* )

	runcmd pcs cluster setup $name ${nameaddrs[@]} --force
	runcmd pcs cluster start --all
}

pcs_cluster_destroy() {
	runcmd pcs cluster stop --all --force
	runcmd pcs cluster destroy --all
}

pcs_stonith_create() {
	local name=$1
	shift 1
	local params=( $* )

	runcmd pcs stonith create $name ${params[@]}
}

pcs_resgroup_create_ldiskfs_mdt() {
	local tgtname=$1
	local locations=( $2 $3 )
	shift 3
	local params=( $* )
	local -A pmap

	for kv in ${params[@]}; do
		key=${kv%%=*}
		val=${kv#*=}
		pmap[$key]=$val
	done
	local lfsname=${pmap['lfsname']}

	runcmd pcs resource create $tgtname-data \
		ocf:heartbeat:mdraid \
		md_dev=/dev/md/$tgtname-data \
		mdadm_conf=/etc/mdadm/$tgtname.conf \
		--group $tgtname-group

	runcmd pcs resource create $tgtname-lustre \
		ocf:heartbeat:Lustre \
		target=/dev/md/$tgtname-data \
		mountpoint=/var/lib/lustre/${lfsname}/$tgtname \
		--group $tgtname-group

	runcmd pcs constraint location $tgtname-group prefers ${locations[@]}
}

pcs_resgroup_create_ldiskfs_ost() {
	local tgtname=$1
	local locations=( $2 $3 )
	shift 3
	local params=( $* )
	local -A pmap

	for kv in ${params[@]}; do
		key=${kv%%=*}
		val=${kv#*=}
		pmap[$key]=$val
	done
	local lfsname=${pmap['lfsname']}

	runcmd pcs resource create $tgtname-journal \
		ocf:heartbeat:mdraid \
		md_dev=/dev/md/$tgtname-journal \
		mdadm_conf=/etc/mdadm/$tgtname.conf \
		--group $tgtname-group

	runcmd pcs resource create $tgtname-data \
		ocf:heartbeat:mdraid \
		md_dev=/dev/md/$tgtname-data \
		mdadm_conf=/etc/mdadm/$tgtname.conf \
		--group $tgtname-group

	runcmd pcs resource create $tgtname-lustre \
		ocf:heartbeat:Lustre \
		target=/dev/md/$tgtname-data \
		mountpoint=/var/lib/lustre/${lfsname}/$tgtname \
		--group $tgtname-group

	runcmd pcs constraint location $tgtname-group prefers ${locations[@]}
}

pcs_resgroup_create_zfs() {
	# TODO
	return 0
}

pcs_resgroup_create_lvm() {
	local tgtname=$1
	local locations=( $2 $3 )
	shift 3
	local params=( $* )
	local -A pmap

	for kv in ${params[@]}; do
		key=${kv%%=*}
		val=${kv#*=}
		pmap[$key]=$val
	done
	local volname=${pmap['volname']}
	local nic=${pmap['nic']}
	local traddr=${pmap['traddr']}
	local transport=${pmap['transport']}
	local nqn=n${traddr##*.}-$volname
	local uuid=$(uuidgen)

	runcmd pcs resource create $tgtname-mdraid \
		ocf:heartbeat:mdraid \
		md_dev=/dev/md/$volname \
		mdadm_conf=/etc/mdadm/$tgtname.conf \
		--group $tgtname-group

	runcmd pcs resource create $tgtname-virtualip \
		ocf:heartbeat:IPaddr2 \
		arp_sender=iputils_arping \
		cidr_netmask=32 \
		ip=$traddr \
		nic=$nic \
		--group $tgtname-group

	runcmd pcs resource create $tgtname-nvmet-subsystem \
		ocf:heartbeat:nvmet-subsystem \
		nqn=$nqn \
		--group $tgtname-group

	runcmd pcs resource create $tgtname-nvmet-namespace \
		ocf:heartbeat:nvmet-namespace \
		backing_path=/dev/md/$volname \
		namespace_id=1 \
		nqn=$nqn \
		uuid=$uuid \
		--group $tgtname-group

	# port id 0 is used for local export by default
	runcmd pcs resource create $tgtname-nvmet-port \
		ocf:heartbeat:nvmet-port \
		addr=$traddr \
		addr_fam=ipv4 \
		nqns=$nqn \
		port_id=1 \
		svcid=4420 \
		type=$transport \
		--group $tgtname-group

	runcmd pcs constraint location $tgtname-group prefers ${locations[@]}
}

pcs_property_set() {
	local kvs=( $* )

	runcmd pcs property set ${kvs[@]}
}

lvm_do_vg_destroy() {
	local vgname=$1
	local volname=$2

	mdraid_start $vgname $volname
	if [ $? -ne 0 ]; then
		return 0
	fi

	runcmd vgchange --lockstart $vgname
	runcmd vgremove --force $vgname

	mdraid_stop $volname
}

lvm_vg_create() {
	local vgname=$1
	local volpath=$2

	mdraid_new_config $vgname

	case $mode in
	active)
		runcmd vgcreate --share --locktype sanlock $vgname $volpath
		runcmd vgchange --lockstop $vgname
		;;
	esac
}

lvm_vg_destroy() {
	local vgname=$1
	local volname=$2

	case $mode in
	active)
		set +e
		lvm_do_vg_destroy $vgname $volname
		set -e
		;;
	esac

	mdraid_del_config $vgname
}

mode=$1; shift
oper=$1; shift
case $oper in
'apt_install')          	apt_install $*          	;;
'apt_remove')           	apt_remove $*           	;;

# operations for nvme target
'nvmet_port_create')		nvmet_port_create $* 		;;
'nvmet_port_destroy')		nvmet_port_destroy $*		;;
'nvmet_port_add_subsys')	nvmet_port_add_subsys $*	;;
'nvmet_port_del_subsys')	nvmet_port_del_subsys $*	;;
'nvmet_subsys_create')		nvmet_subsys_create $*		;;
'nvmet_subsys_destroy')		nvmet_subsys_destroy $*		;;
'nvmet_namespace_create')	nvmet_namespace_create $*	;;
'nvmet_saveconfig')		nvmet_saveconfig $*		;;
'nvmet_clear')			nvmet_clear $*			;;

# operations for iscsi target
'iscsit_iqn_create')		iscsit_iqn_create $*		;;
'iscsit_iqn_destroy')		iscsit_iqn_destroy $*		;;
'iscsit_portal_create')		iscsit_portal_create $*		;;
'iscsit_portal_connect')	iscsit_portal_connect $*	;;
'iscsit_portal_disconnect')	iscsit_portal_disconnect $*	;;
'iscsit_portal_destroy')	iscsit_portal_destroy $*	;;
'iscsit_acl_create')		iscsit_acl_create $*		;;
'iscsit_lun_create')		iscsit_lun_create $*		;;
'iscsit_saveconfig')		iscsit_saveconfig $*		;;
'iscsit_clear')			iscsit_clear $*			;;

# operations for target on ldiskfs
'parted_label')			parted_label $*			;;
'parted_mkpart')		parted_mkpart $*		;;
'parted_rm')			parted_rm $*			;;

'mdraid_create')		mdraid_create $*		;;
'mdraid_destroy')		mdraid_destroy $*		;;

'ldiskfs_mgt_create') 		ldiskfs_mgt_create $*		;;
'ldiskfs_mdt_create') 		ldiskfs_mdt_create $*		;;
'ldiskfs_ost_create') 		ldiskfs_ost_create $*		;;
'ldiskfs_tgt_destroy') 		ldiskfs_tgt_destroy $*		;;

# operations for target on zfs
'zpool_create')			zpool_create $*			;;
'zpool_destroy')		zpool_destroy $*		;;

'zfs_tgt_create') 		zfs_tgt_create $*		;;
'zfs_tgt_destroy')		zfs_tgt_destroy $*		;;

# operations for nfs

# operations for pcs
'pcs_host_auth')		pcs_host_auth $*		;;
'pcs_resgroup_create_ldiskfs_mdt')
				pcs_resgroup_create_ldiskfs_mdt $*
								;;
'pcs_resgroup_create_ldiskfs_ost')
				pcs_resgroup_create_ldiskfs_ost $*
								;;
'pcs_resgroup_create_zfs')	pcs_resgroup_create_zfs $*	;;
'pcs_resgroup_create_lvm')	pcs_resgroup_create_lvm $*	;;
'pcs_stonith_create')		pcs_stonith_create $*		;;
'pcs_property_set')		pcs_property_set $*		;;
'pcs_cluster_setup')		pcs_cluster_setup $*		;;
'pcs_cluster_destroy')		pcs_cluster_destroy $*		;;

# operations for lvm
'lvm_vg_create')		lvm_vg_create $*		;;
'lvm_vg_destroy')		lvm_vg_destroy $*		;;

'echo')			echo "$*"				;;	# for test
*)			errexit "UNKNOWN OPERATION $oper"	;;
esac
