#!/bin/bash

declare -a mgs_ips
declare -a mgt
declare -a mdt
declare -a ost

oper=unknown
configfile="./osd.conf"
dryrun=
sshrun=

# osd(mgt, mdt, ost) info
osd_type=
osd_index=

# these are used for osd creation.
osd_vdevs=
osd_ips=

# these are set based on type and index
osd_pool=
osd_dataset=
osd_mountpoint=

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
	read -r osd_type osd_index csv_addrs osd_vdevs <<< $*
	read -r -a osd_ips <<< $(echo $csv_addrs | tr ',' ' ')
	if [ $osd_type == "mgs" ]; then
		osd_dataset=$osd_type
	else
		osd_dataset=${osd_type}${osd_index}
	fi
	osd_pool=${fsname}-${osd_dataset}pool
	osd_mountpoint=/var/lib/lustre/$fsname/$osd_dataset

	#
	# Set the current command to execute locally or remotely
	#
	if ip addr | grep -q ${osd_ips[0]}; then
		sshrun=
	else
		sshrun="ssh ${osd_ips[0]}"
	fi
}

#
# Create an osd with the specified type, index, ips and vdevs.
#
osd_create() {
	echo "osd_create $*"

	osd_set_variables $*
	osd_check_env ${osd_ips[0]}

	# make zpool
	opts=" -o multihost=on -o cachefile=none -o ashift=12 -O canmount=off"
	if [ $osd_type == "ost" ]; then
		opts+=" -O recordsize=1024K"
	fi
	runcmd zpool create $opts $osd_pool $osd_vdevs ||
		errexit "zpool create for $osd_type failed"

	# make lustre zfs
	opts=$(printf  " --servicenode %s@$proto " ${osd_ips[@]})
	if [ $osd_type == "mgs" ]; then
		opts+=" --$osd_type"
	else
		opts+=" --$osd_type"
		opts+=" --index ${osd_index}"
		opts+=" --fsname ${fsname}"
		opts+=$(printf " --mgsnode %s@$proto " ${mgs_ips[@]})
	fi
	opts+=" --backfstype=zfs"
	runcmd mkfs.lustre $opts $osd_pool/$osd_dataset ||
		errexit "mkfs.lustre for $osd_type failed"

	# mount the newly maked fs
	runcmd mkdir -p $osd_mountpoint
	if [ ${#osd_ips[@]} -eq 2 ]; then
		$dryrun ssh ${osd_ips[1]} -C "partprobe; mkdir -p $osd_mountpoint"
	fi
	runcmd mount -t lustre $osd_pool/$osd_dataset $osd_mountpoint ||
		errexit "mount failed"

	echo ""
}

osd_destroy() {
	echo "osd_destroy $*"

	osd_set_variables $*

	runcmd umount $osd_mountpoint
	runcmd zpool destroy $osd_pool
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

n=${#mgs_ips[*]}
if [ $n -ne 1 ] && [ $n -ne 2 ]; then
	errexit "mgs ips should be supplied"
fi
n=${#mgt[*]}
if [ $n -ne 1 ]; then
	errexit "the number of mgts should be ONE";
fi

case $oper in
create)
	for i in ${!mgt[*]}; do osd_create mgs 0 ${mgt[0]}; done
	for i in ${!mdt[*]}; do osd_create mdt $i ${mdt[i]}; done
	for i in ${!ost[*]}; do osd_create ost $i ${ost[i]}; done
	;;

destroy)
	for i in ${!mgt[*]}; do osd_destroy mgs 0 ${mgt[0]}; done
	for i in ${!mdt[*]}; do osd_destroy mdt $i ${mdt[i]}; done
	for i in ${!ost[*]}; do osd_destroy ost $i ${ost[i]}; done
	;;

*)
	errexit "unknown operation: $oper" ;;
esac
