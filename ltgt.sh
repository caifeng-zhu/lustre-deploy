#!/bin/bash

declare -a mgs_nids

K=1024
BLKSZ=$(( 4 * K ))
STRIPESZ=$(( 1 * K * K ))

oper=unknown
configfile="./ltgt.conf"
dryrun=
sshrun=

# set in the config file
declare -a tgt_name_list
declare -a tgt_nids_list
declare -a tgt_vdev_list
declare -a tgt_raid_list

tgt=				# current working tgt (by name)
tgt_idx=			# current working tgt (by index)
tgt_fsname=			# set by config file
tgt_osdtype=			# set by config file
tgt_opts=			# options passed to mkfs.lustre
tgt_mountdev=
tgt_mountpoint=
tgt_ipaddr2=			# backup or second ip addr

declare -a ldiskfs_devices
declare -a ldiskfs_journaldevs
declare -a ldiskfs_datadevs

declare -a mdraid_devices
mdraid_tmpconf=
mdraid_name=
mdraid_options=
mdraid_level=


errexit() {
	printf "$*\n"
	exit 1
}

usage() {
	cat <<EOF
${0##*/} [-n] [-f config] create|destroy
EOF
	exit 1
}

runcmd() {
	$dryrun $sshrun $*
}

runcmd_nodry() {
	$sshrun $*
}

tgt_check_env() {
	local ip=$1

	# check that lustre module config file is correct.
	runcmd_nodry [ -f /etc/modprobe.d/lustre.conf ] ||
		errexit "/etc/modprobe.d/lustre.conf does not exist"
	nic=$(runcmd_nodry cat /etc/modprobe.d/lustre.conf |
	      grep 'networks=' |
	      awk '{ print $3 }' |
	      sed -e 's/networks=\w\+(\(\w\+\))/\1/')
	runcmd_nodry ip addr show dev $nic | grep $ip >& /dev/null ||
		errexit "$nic has no address as $ip"

	# check that lustre module exist and nid is set corretly.
	runcmd_nodry modprobe lustre >& /dev/null ||
		errexit "no lustre module probed"
	nids=$(runcmd_nodry lctl list_nids)
	echo $nids | grep -e $ip@$proto >& /dev/null ||
		errexit "other nids exists: $nids"

	# check that zfs module exist.
	runcmd_nodry modprobe zfs >& /dev/null ||
		errexit "no zfs module probed"
}

# Create a tmp configure file. It would be renamed as the formal
# configure file in mdraid_end_conf() if everything is OK.
#
mdraid_begin_conf() {
	mdraid_tmpconf=/tmp/$tgt.conf.$$
	touch $mdraid_tmpconf
}

mdraid_add_conf() {
	mdadm --examine --scan | grep $mdraid_name | tee -a $mdraid_tmpconf
}

mdraid_end_conf() {
	if [ ! -s $mdraid_tmpconf ]; then
		# nothing is configured, that ocuurs only for raw disks.
		# the file is not needed and is deleted.
		rm $mdraid_tmpconf
		return
	fi

	[ -e /etc/mdadm/$tgt.conf ] && \
		mv /etc/mdadm/$tgt.conf /etc/mdadm/$tgt.conf.$$
	mv $mdraid_tmpconf /etc/mdadm/$tgt.conf
}

mdraid_sync_conf() {
        [ -e /etc/mdadm/$tgt.conf ] && \
		scp /etc/mdadm/$tgt.conf $tgt_ipaddr2:/etc/mdadm
}

mdraid_create() {
	mdadm --create $mdraid_name --force --homehost=any --data-offset=1M \
		--level=$mdraid_level $mdraid_options \
		-n ${#mdraid_devices[@]} ${mdraid_devices[@]}
	mdraid_add_conf
}

mdraid_config() {
	mdraid_realpath=$(realpath /dev/md/$mdraid_name)
	mdadm --action=frozen $mdraid_realpath

	echo $1 > /sys/block/${mdraid_realpath##*/}/md/group_thread_cnt
	echo $2 > /sys/block/${mdraid_realpath##*/}/md/skip_copy

	mdadm --action=idle $mdraid_realpath
}

ldiskfs_mkpart() {
	for disk in ${ldiskfs_devices[@]}; do
		npart=0
		if parted -s $disk print | grep -q ${tgt}-journal; then
			npart=$((npart + 1))
		fi
		if parted -s $disk print | grep -q ${tgt}-data; then
			npart=$((npart + 1))
		fi
		if [ $npart -eq 2 ]; then
			# both partitions exist.
			wipefs -a $disk-part1
			wipefs -a $disk-part2
			continue
		fi

		wipefs -a $disk
		parted -s $disk mklabel gpt
		parted -s $disk mkpart ${tgt}-journal 16MiB 1GiB
		parted -s $disk mkpart ${tgt}-data 1GiB 100%
		partprobe $disk
	done
	sleep 1	# waiting partition table to settle
}

ldiskfs_wipepart() {
	for disk in ${ldiskfs_devices[@]}; do
		npart=0
		if parted -s $disk print | grep -q ${tgt}-journal; then
			npart=$((npart + 1))
		fi
		if parted -s $disk print | grep -q ${tgt}-data; then
			npart=$((npart + 1))
		fi
		if [ $npart -eq 2 ]; then
			# both partitions exist.
			wipefs -a $disk-part1
			wipefs -a $disk-part2
			continue
		fi

		wipefs -a $disk
	done
}

# Create object storage device for ldiskfs. The osd must
# have a data volume and optionally a journal volume.
#
ldiskfs_create_osd() {
	read -r data_raid jncopy <<< ${tgt_raid_list[$tgt_idx]}
	ldiskfs_devices=( ${tgt_vdev_list[$tgt_idx]} )
	ldiskfs_datadevs=( ${ldiskfs_devices[@]} )

	mdraid_begin_conf

	if [ ! -z "$jncopy" ]; then
		ldiskfs_mkpart
		ldiskfs_journaldevs=( $(printf "%s-part1 " ${ldiskfs_devices[@]:0:$jncopy}) )
		ldiskfs_datadevs=( $(printf "%s-part2 " ${ldiskfs_devices[@]}) )

		mdraid_name=${tgt}-journal
		mdraid_devices=( ${ldiskfs_journaldevs[@]} )
		mdraid_level=raid1
		mdraid_options=""
		mdraid_create

		jraid=/dev/md/$mdraid_name
		mke2fs -O journal_dev -b $BLKSZ $jraid

		mkfs_opts+=" "
		mkfs_opts+="-j -J device=$jraid"

		# this option is required. host reboot will change dev num
		# recored in ldiskfs superblock. this option makes mount always
		# find the right journal device path.
		mntfs_opts+=" "
		mntfs_opts+="journal_path=$jraid"
	fi

	mdraid_name=${tgt}-data
	mdraid_devices=( ${ldiskfs_datadevs[@]} )
	mdraid_level=$data_raid
	case $mdraid_level in
	raid1)
		mdraid_options=""
		mdraid_create

		mkfs_opts+=" "
		case $tgt in
		mdt*)	mkfs_opts+="-E lazy_itable_init='1',nodiscard"	;;
		*)	mkfs_opts+="-E lazy_itable_init='1'"		;;
		esac
		tgt_mountdev=/dev/md/$mdraid_name
		;;

	raid10)
		chunksz=$(( 4 * K ))
		mdraid_options="--chunk=$(( chunksz / K ))K --bitmap=none"
		mdraid_create

		mkfs_opts+=" "
		mkfs_opts+="-E stride=$(( chunksz / BLKSZ )),stripe_width=$(( STRIPESZ / BLKSZ ))"
		tgt_mountdev=/dev/md/$mdraid_name
		;;

	raid6)
		chunksz=$(( STRIPESZ / (${#mdraid_devices[@]} - 2) ))
		mdraid_options="--chunk=$(( chunksz / K ))K --bitmap=none"
		mdraid_create
		mdraid_config 16 1

		mkfs_opts+=" "
		mkfs_opts+="-E stride=$(( chunksz / BLKSZ )),stripe_width=$(( STRIPESZ / BLKSZ ))"
		tgt_mountdev=/dev/md/$mdraid_name
		;;

	# both raid5 and raw are for testing env.
	raid5)
		chunksz=$(( STRIPESZ / (${#mdraid_devices[@]} - 1) ))
		mdraid_options="--chunk=$(( chunksz / K ))K --bitmap=none"
		mdraid_create

		mkfs_opts+=" "
		mkfs_opts+="-E stride=$(( chunksz / BLKSZ )),stripe_width=$(( STRIPESZ / BLKSZ ))"
		tgt_mountdev=/dev/md/$mdraid_name
		;;

	raw)
		mkfs_opts+=" "
		mkfs_opts+="-E lazy_itable_init=1"
		tgt_mountdev=${ldiskfs_devices[0]}
		;;

	*)
		errexit "raid level $raidlevel not supported"
		;;
	esac

	mdraid_end_conf
}

ldiskfs_destroy_osd() {
	read -r data_raid jncopy <<< ${tgt_raid_list[$tgt_idx]}

	if [ $data_raid = "raw" ]; then
		return
	fi

	[ ! -z "$jncopy" ] && \
		mdadm --stop /dev/md/${tgt}-journal
	mdadm --stop /dev/md/${tgt}-data

	ldiskfs_devices=( ${tgt_vdev_list[$tgt_idx]} )
	ldiskfs_wipepart
}

ldiskfs_sync_backup() {
	mdraid_sync_conf
}

# Create object storage device for zfs. The osd is a zpool.
#
zfs_create_osd() {
	opts=""
	opts+="-o multihost=on -o cachefile=none -o ashift=12 -O canmount=off"
	case $tgt in
	ost*)
		opts+=" "
		opts+="-O recordsize=1024K"
		;;
	esac

	pool=${tgt_fsname}-${tgt}pool
	zpool create $opts $pool ${tgt_vdev_list[$tgt_idx]} ||
		errexit "zpool create for $tgt failed"

	tgt_mountdev=$pool/$tgt
}

zfs_destroy_osd() {
	zpool destroy ${tgt_fsname}-${tgt}pool
}

zfs_sync_backup() {
	true	# nothing specific to sync
}

# Set variables for the lustre target. These variables are treated
# as global variables by subroutines.
#
tgt_init_vars() {
	tgt_idx=$1
	tgt=${tgt_name_list[$tgt_idx]}

	tgt_opts=""
	tgt_opts+="--backfstype=$tgt_osdtype --reformat"
	case $tgt in
	mgt)
		tgt_opts+=" "
		tgt_opts+="--mgs"
		;;

	mdt*)
		tgt_opts+=" "
		tgt_opts+="--mdt --index ${tgt#mdt} --fsname $tgt_fsname"

		tgt_opts+=" "
		tgt_opts+=$(printf " --mgsnode %s " ${mgs_nids[@]})
		;;

	ost*)
		tgt_opts+=" "
		tgt_opts+="--ost --index ${tgt#ost} --fsname $tgt_fsname"

		tgt_opts+=" "
		tgt_opts+=$(printf " --mgsnode %s " ${mgs_nids[@]})
		;;

	*)
		errexit "unknown target $tgt"
		;;
	esac

	nids=( ${tgt_nids_list[$tgt_idx]} )
	tgt_opts+=" "
	tgt_opts+=$(printf " --servicenode %s " ${nids[@]})

	if [ ${#nids[@]} -eq 2 ]; then
		tgt_ipaddr2=${nids[1]%%@*}	# first one of the pair 'ip1@net1,ip2@net2'
	fi

	tgt_mountpoint=/var/lib/lustre/$tgt_fsname/$tgt
}

tgt_sync_backup() {
	if [ -z "$tgt_ipaddr2" ]; then
		return
	fi

	ssh $tgt_ipaddr2 mkdir -p $tgt_mountpoint

	case $tgt_osdtype in
	ldiskfs)	ldiskfs_sync_backup	;;
	zfs)		zfs_sync_backup		;;
	esac
}

tgt_create() {
	#tgt_check_env ${tgt_ips[0]}

	# fs specific options for mkfs and mount are set during
	# mountdev creation.
	mkfs_opts=
	mntfs_opts=

	case $tgt_osdtype in
	ldiskfs)	ldiskfs_create_osd	;;
	zfs)		zfs_create_osd		;;
	*)		errexit "unknown osd fs type $tgt_osdtype" ;;
	esac

	# delete leading whitespace to satisfy --mkfsoptions and --mountfsoptions
	mkfs_opts=${mkfs_opts## }
	mntfs_opts=${mntfs_opts## }

	# make lustre fs
	printf "$tgt mkfs start:  $(date)\n"
	if [ ! -z "$mkfs_opts" ] && [ ! -z "$mntfs_opts" ]; then
		mkfs.lustre --mkfsoptions="$mkfs_opts" --mountfsoptions="$mntfs_opts" \
			$tgt_opts $tgt_mountdev
	elif [ ! -z "$mkfs_opts" ]; then
		mkfs.lustre --mkfsoptions="$mkfs_opts" 	\
			$tgt_opts $tgt_mountdev
	elif [ ! -z "$mntfs_opts" ]; then
		mkfs.lustre --mountfsoptions="$mntfs_opts" \
			$tgt_opts $tgt_mountdev
	else
		mkfs.lustre $tgt_opts $tgt_mountdev
	fi
	printf "$tgt mkfs end: $(date)\n"

	mkdir -p $tgt_mountpoint
	mount -t lustre $tgt_mountdev $tgt_mountpoint ||
		errexit "mount failed"
}

tgt_destroy() {
	echo "tgt_destroy $tgt"

	umount $tgt_mountpoint

	case $tgt_osdtype in
	ldiskfs)	ldiskfs_destroy_osd	;;
	zfs)		zfs_destroy_osd  	;;
	*)		errexit "unknown osd fs type $tgt_osdtype" ;;
	esac
}

tgt_populate() {
	for i in ${!tgt_name_list[@]}; do
		tgt_init_vars $i
		set -e 
		tgt_create
		set +e
		tgt_sync_backup
	done
}

tgt_killall() {
	for i in ${!tgt_name_list[@]}; do
		tgt_init_vars $i
		tgt_destroy
	done
}

while getopts "hf:n" opt; do
	case $opt in
	h)	usage				;;
	f)	configfile=$OPTARG		;;
	n)	dryrun=echo			;;
	*)	errexit "unknown option $opt"	;;
	esac
done
shift $((OPTIND - 1))

if [ $# -ne 1 ]; then
	usage
fi
oper=$1

if [ ! -f $configfile ]; then
	usage
fi
source $configfile

n=${#mgs_nids[@]}
if [ $n -ne 1 ] && [ $n -ne 2 ]; then
	errexit "mgs ips should be supplied"
fi

case $oper in
create)		tgt_populate			;;
destroy)	tgt_killall			;;
*)		errexit "unknown operation: $oper" ;;
esac
