#!/bin/bash

declare -a mgs_nids
declare -a mgt
declare -a mdt
declare -a ost
declare -a osd_vdev_hosts

K=1024
BLKSZ=$(( 4 * K ))
STRIPESZ=$(( 1 * K * K ))

osd_vdev_type=
osd_vdev_diskdir=

oper=unknown
configfile="./osd.conf"
dryrun=
sshrun=

# osd(mgt, mdt, ost) info
osd_type=
osd_index=

# these are used for osd creation.
osd_vdevs=
osd_nids=

# these are set based on type and index
osd_pool=
osd_dataset=
osd_datadev=
osd_mountpoint=
osd_opts=

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

osd_check_env() {
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

#
# Set the pool, dataset, and mount point for the osd,
# based on osd type and index.
#
osd_set_variables() {
	read -r osd_type osd_index nidstr osd_vdevs <<< $*
	read -r -a osd_nids <<< $(echo $nidstr | tr ':' ' ')

	osd_opts=""
	if [ $osd_type == "mgt" ]; then
		osd_dataset=$osd_type
	else
		osd_dataset=${osd_type}${osd_index}
	fi
	osd_pool=${fsname}-${osd_dataset}pool
	osd_mountpoint=/var/lib/lustre/$fsname/$osd_dataset

	#
	# Set the current command to execute locally or remotely
	#
	osd_ip=${osd_nids[0]%%@*}	# first one of the pair 'ip1@net1,ip2@net2'
	if ip addr | grep -w -q $osd_ip; then
		sshrun=
	else
		sshrun="ssh $osd_ip"
	fi
}

ldiskfs_mkpart() {
	for disk in ${ldiskfs_disks[*]}; do
		if parted -s $disk print | grep -q ${osd_dataset}-data; then
			# partitions already exist.
			return
		fi
		
		wipefs -a $disk
		parted -s $disk mklabel gpt
		parted -s $disk mkpart ${osd_dataset}-journal 16MiB 1GiB
		parted -s $disk mkpart ${osd_dataset}-data 1GiB 100%
		partprobe $disk
	done
	sleep 1	# waiting partition table to settle
}

ldiskfs_create_journal() {
	nmirrors=$1

	ldiskfs_mkpart
	jparts=( $(printf "%s-part1 " ${ldiskfs_disks[*]}) )

	jpath=/dev/md/${osd_dataset}-journal

	mdadm --create ${osd_dataset}-journal --force --homehost=any \
		--level=raid1 -n $nmirrors ${jparts[@]:0:$nmirrors}

	mke2fs -O journal_dev -b $BLKSZ $jpath

	mkfs_opts+=" "
	mkfs_opts+="-j -J device=$jpath"

	#mntfs_opts+=" "
	#mntfs_opts+="journal_path=$jpath"
}

ldiskfs_create_data_raid6() {
	ldiskfs_mkpart
	dparts=( $(printf "%s-part2 " ${ldiskfs_disks[*]}) )

	chunksz=$(( STRIPESZ / (${#dparts[*]} - 2) ))
	mdadm --create ${osd_dataset}-data --force 		\
		--homehost=any --chunk=$((chunksz / K))K 	\
		--data-offset=1M --bitmap=none --level=raid6 	\
		-n ${#ldiskfs_disks[*]} ${dparts[*]}

	mkfs_opts+=" "
	mkfs_opts+="-E stride=$((chunksz / BLKSZ)),stripe_width=$((STRIPESZ / BLKSZ))"
}

ldiskfs_create_data_raid10() {
	ldiskfs_mkpart
	dparts=( $(printf "%s-part2 " ${ldiskfs_disks[*]}) )

	chunksz=$(( 4 * K ))
	mdadm --create ${osd_dataset}-data --force 		\
		--homehost=any --chunk=$((chunksz / K))K 	\
		--data-offset=1M --bitmap=none --level=raid10 	\
		-n ${#ldiskfs_disks[*]} ${dparts[*]}

	#mkfs_opts+=" "
	#mkfs_opts+="-E stride=2"
}

ldiskfs_create_data_raid1() {
	mdadm --create ${osd_dataset}-data --force 		\
		--homehost=any --data-offset=1M 		\
		--level=raid1 -n ${#ldiskfs_disks[*]} ${ldiskfs_disks[*]}

	mkfs_opts+=" "
	mkfs_opts+="-E lazy_itable_init='1'"

}

ldiskfs_create_data_vanilla() {
	if [ $osd_type = "mdt" ]; then
		mkfs_opts+=" "
		mkfs_opts+="-E lazy_itable_init=1"
	fi
}

ldiskfs_prepare() {
	read -r raidlevel disks <<< $osd_vdevs
	ldiskfs_disks=( $disks )

	case $raidlevel in
	raid6)
		ldiskfs_create_journal 3
		ldiskfs_create_data_raid6
		osd_datadev=/dev/md/${osd_dataset}-data
		;;

	raid1)
		ldiskfs_create_data_raid1
		osd_datadev=/dev/md/${osd_dataset}-data
		;;

	raid10)
		ldiskfs_create_journal 2
		ldiskfs_create_data_raid10
		osd_datadev=/dev/md/${osd_dataset}-data
		;;

	vanilla)
		ldiskfs_create_data_vanilla
		osd_datadev=${ldiskfs_disks[0]}
		;;

	*)
		errexit "raid level $raidlevel not supported"
		;;
	esac
}

zfs_prepare() {
	# make zpool
	zpool_opts=" -o multihost=on -o cachefile=none -o ashift=12 -O canmount=off"
	if [ $osd_type == "ost" ]; then
		zpool_opts+=" -O recordsize=1024K"
	fi
	runcmd zpool create $zpool_opts $osd_pool $osd_vdevs ||
		errexit "zpool create for $osd_type failed"

	osd_datadev=$osd_pool/$osd_dataset
}

#
# Create an osd with the specified type, index, ips and vdevs.
#
osd_create() {
	echo "osd_create $*"

	osd_set_variables $*
	#osd_check_env ${osd_ips[0]}

	set -e

	# fs specific options for mkfs and mount are set by
	# *fs_prepare().
	mkfs_opts=""
	mntfs_opts=""
	case $osd_fstype in
	ldiskfs)
		ldiskfs_prepare
		;;

	zfs)
		zfs_prepare
		;;

	*)
		errexit "unknown osd fs type $osd_fstype"
		;;
	esac
	mkfs_opts=${mkfs_opts## }	# delete leading whitespace
	mntfs_opts=${mntfs_opts## }	# delete leading whitespace
	
	# make lustre fs
	osd_opts+="--backfstype=$osd_fstype --reformat"
	osd_opts+=" "
	osd_opts+=$(printf " --servicenode %s " ${osd_nids[@]})
	if [ $osd_type == "mgt" ]; then
		osd_opts+=" "
		osd_opts+="--mgs"
	else
		osd_opts+=" "
		osd_opts+="--$osd_type --index $osd_index --fsname $fsname"
		osd_opts+=" "
		osd_opts+=$(printf " --mgsnode %s " ${mgs_nids[@]})
	fi

	printf "mkfs start: $(date)\n"
	if [ ! -z "$mkfs_opts" ] && [ ! -z "$mntfs_opts" ]; then
		mkfs.lustre --mkfsoptions="$mkfs_opts" 	\
			--mountfsoptions="$mntfs_opts"	\
			$osd_opts $osd_datadev 
	elif [ ! -z "$mkfs_opts" ]; then
		mkfs.lustre --mkfsoptions="$mkfs_opts" 	\
			$osd_opts $osd_datadev 
	elif [ ! -z "$mntfs_opts" ]; then
		mkfs.lustre --mountfsoptions="$mntfs_opts" \
			$osd_opts $osd_datadev 
	else
		mkfs.lustre $osd_opts $osd_datadev 
	fi
	printf "mkfs end: $(date)\n"

	# mount the new fs
	runcmd mkdir -p $osd_mountpoint
	#if [ ${#osd_nids[@]} -eq 2 ]; then
	#	other_ip=${osd_nids[1]%%@*}
	#	$dryrun ssh $other_ip -C "partprobe; mkdir -p $osd_mountpoint"
	#fi
	runcmd mount -t lustre_tgt $osd_datadev $osd_mountpoint ||
		errexit "mount failed"

	set +e
	echo ""
}

ldiskfs_finish() {
	read -r raidlevel disks <<< $osd_vdevs

	if [ $raidlevel = "vanilla" ]; then
		return
	fi

	if [ $osd_type != "mgt" ]; then
		mdadm --stop /dev/md/${osd_dataset}-journal
	fi
	mdadm --stop /dev/md/${osd_dataset}-data
}

zfs_finish() {
	runcmd zpool destroy $osd_pool
}

osd_destroy() {
	echo "osd_destroy $*"

	osd_set_variables $*

	runcmd umount $osd_mountpoint

	case $osd_fstype in
	ldiskfs)	ldiskfs_finish 	;;
	zfs)		zfs_finish 	;;
	*)		errexit "unknown osd fs type $osd_fstype" ;;
	esac
}

while getopts "hf:n" opt; do
	case $opt in
	h)	usage;;
	f)	configfile=$OPTARG;;
	n)	dryrun=echo;;
	*)	errexit "unknown option $opt";;
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

n=${#mgs_nids[*]}
if [ $n -ne 1 ] && [ $n -ne 2 ]; then
	errexit "mgs ips should be supplied"
fi

case $oper in
create)
	for i in ${!mgt[*]}; do osd_create mgt 0 ${mgt[0]}; done
	for i in ${!mdt[*]}; do osd_create mdt $i ${mdt[i]}; done
	for i in ${!ost[*]}; do osd_create ost $i ${ost[i]}; done
	;;

destroy)
	for i in ${!mgt[*]}; do osd_destroy mgt 0 ${mgt[0]}; done
	for i in ${!mdt[*]}; do osd_destroy mdt $i ${mdt[i]}; done
	for i in ${!ost[*]}; do osd_destroy ost $i ${ost[i]}; done
	;;

*)
	errexit "unknown operation: $oper" ;;
esac
