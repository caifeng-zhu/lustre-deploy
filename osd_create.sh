#!/bin/bash

declare -a mgs_ips
declare -a mgt
declare -a mdt
declare -a ost

dryrun=
sshcmd=

# osd(mgt, mdt, ost) info
osd_ips=
osd_type=
osd_index=
osd_dataset=
osd_pool=
osd_mountpoint=

errexit() {
	printf "$*\n"
	exit 1
}

usage() {
	less -F <<EOF
${0##*/} -[F fsname] mgs_ip1[,mgs_ip2] mgs_ip1[,mgs_ip2] mgt zfsvdevs
${0##*/} -[F fsname] mgs_ip1[,mgs_ip2] mds_ip1[,mds_ip2] mdt/index zfsvdevs
${0##*/} -[F fsname] mgs_ip1[,mgs_ip2] oss_ip1[,oss_ip2] ost/index zfsvdevs
NOTE: index is started from 0
EOF
	exit 1
}

is_local_ip() {
	hostname -i | grep -wq $1
}

osd_mkpool() {
	if [ $osd_type == "ost" ]; then
		opt_recordsz="-O recordsize=1024K"
	else
		opt_recordsz=""
	fi

	$dryrun $sshcmd zpool create -o multihost=on -o cachefile=none -o ashift=12 \
		-O canmount=off $opt_recordsz \
		$osd_pool $osd_vdevs || \
			errexit "zpool create for $osd_type failed"
}

osd_mkfs() {
	if [ $osd_type == "mgs" ]; then
		opt_fsname=""
		opt_index=""
		opt_mgsnids=""
	else
		opt_fsname="--fsname ${fsname}"
		opt_index="--index ${osd_index}"
		opt_mgsnids=$(printf " --mgsnode %s@$proto " ${mgs_ips[@]})
	fi

	opt_svcnids=$(printf  " --servicenode %s@$proto " ${osd_ips[@]})

	$dryrun $sshcmd mkfs.lustre $opt_fsname --$osd_type $opt_index \
		$opt_mgsnids $opt_svcnids --backfstype=zfs \
		$osd_pool/$osd_dataset || \
			errexit "mkfs.lustre for $osd_type failed"
}

osd_mount() {
	$dryrun $sshcmd mkdir -p $osd_mountpoint
	if [ ${#osd_ips[@]} -eq 2 ]; then
		$dryrun ssh ${osd_ips[1]} -C "partprobe; mkdir -p $osd_mountpoint"
	fi

	$dryrun $sshcmd mount -t lustre $osd_pool/$osd_dataset $osd_mountpoint
}

osd_create() {
	osd_type=$1; shift
	osd_index=$1; shift
	if [ $osd_type == "mgs" ]; then
		osd_dataset=mgt
		osd_pool=mgtpool
		osd_mountpoint=/var/lib/lustre/$fsname/mgt
	else
		osd_dataset=${osd_type}${osd_index}
		osd_pool=${fsname}-${osd_dataset}pool
		osd_mountpoint=/var/lib/lustre/$fsname/$osd_dataset
	fi

	read -r addrs osd_vdevs <<< $*
	read -r -a osd_ips <<< $(echo $addrs | tr ',' ' ')

	osd_mkpool
	osd_mkfs
	osd_mount

	echo ""
}

main() {
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

while getopts "hF:n" opt; do 
	case $opt in
	h)	usage;;
	F)	fsname=$OPTARG;;
	n)	dryrun=echo;;
	*)	errexit "unknown option $opt";;
	esac
done
shift $((OPTIND - 1))

source ./osd.conf

main
