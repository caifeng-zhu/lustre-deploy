#!/bin/bash

declare -a mgs_ips
declare -a mgt
declare -a mdt
declare -a ost

oper=create
configfile=
dryrun=
sshcmd=

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
	less -F <<EOF
${0##*/} [-n] -f config
EOF
	exit 1
}

is_local_ip() {
	hostname -i | grep -wq $1
}

osd_mkpool() {
	opts=" -o multihost=on -o cachefile=none -o ashift=12 -O canmount=off"
	if [ $osd_type == "ost" ]; then
		opts+=" -O recordsize=1024K"
	fi

	$dryrun $sshcmd zpool create $opts $osd_pool $osd_vdevs || \
		errexit "zpool create for $osd_type failed"
}

osd_mkfs() {
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

	$dryrun $sshcmd mkfs.lustre $opts $osd_pool/$osd_dataset || \
		errexit "mkfs.lustre for $osd_type failed"
}

osd_mount() {
	$dryrun $sshcmd mkdir -p $osd_mountpoint
	if [ ${#osd_ips[@]} -eq 2 ]; then
		$dryrun ssh ${osd_ips[1]} -C "partprobe; mkdir -p $osd_mountpoint"
	fi

	$dryrun $sshcmd mount -t lustre $osd_pool/$osd_dataset $osd_mountpoint
}


#
# Set the pool, dataset, and mount point for the osd,
# based on osd type and index.
#
osd_set_variables() {
	if [ $osd_type == "mgs" ]; then
		osd_dataset=mgt
		osd_pool=mgtpool
		osd_mountpoint=/var/lib/lustre/$fsname/mgt
	else
		osd_dataset=${osd_type}${osd_index}
		osd_pool=${fsname}-${osd_dataset}pool
		osd_mountpoint=/var/lib/lustre/$fsname/$osd_dataset
	fi
}

#
# Create an osd with the specified type, index, ips and vdevs.
#
osd_create() {
	osd_type=$1; shift
	osd_index=$1; shift
	read -r addrs osd_vdevs <<< $*
	read -r -a osd_ips <<< $(echo $addrs | tr ',' ' ')

	osd_set_variables

	osd_mkpool
	osd_mkfs
	osd_mount

	echo ""
}

osd_destroy() {
	osd_type=$1; shift
	osd_index=$1; shift

	osd_set_variables

	$dryrun umount $osd_mountpoint
	$dryrun zpool destroy $osd_pool
}

create_osd() {
	n=${#mgs_ips[*]}
	if [ $n -ne 1 -a $n -ne 2 ]; then
		errexit "mgs ips should be supplied"
	fi

	for i in ${!mgt[*]}; do
		if [ $i -ne 0 ]; then
			errexit "too many mgts";
		fi
		osd_create mgs 0 ${mgt[0]}
	done

	for i in ${!mdt[*]}; do
		osd_create mdt $i ${mdt[i]}
	done

	for i in ${!ost[*]}; do
		osd_create ost $i ${ost[i]}
	done
}

destroy_osd() {
	for i in ${!mgt[*]}; do
		if [ $i -ne 0 ]; then
			errexit "too many mgts";
		fi
		osd_destroy mgs 0
	done

	for i in ${!mdt[*]}; do
		osd_destroy mdt $i
	done

	for i in ${!ost[*]}; do
		osd_destroy ost $i
	done
}

while getopts "hf:nd" opt; do
	case $opt in
	h)	usage;;
	f)	configfile=$OPTARG;;
	n)	dryrun=echo;;
	d)	oper=destroy;;
	*)	errexit "unknown option $opt";;
	esac
done
shift $((OPTIND - 1))

if [ -z $configfile ] || [ ! -e $configfile ]; then
	usage
fi

source $configfile

case $oper in
create)
	create_osd
	;;

destroy)
	destroy_osd
	;;

*)
	errexit "unknown operation: $oper"
	;;
esac
