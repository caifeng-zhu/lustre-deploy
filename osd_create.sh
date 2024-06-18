#!/bin/bash

declare -a mgs_ips
declare -a mgt
declare -a mdt
declare -a ost

fsname=test1
proto=tcp
dryrun=
sshcmd=

# osd(mgt, mdt, ost) info
osd_ips=
osd_type=
osd_indx=
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

osd_create_zpool() {
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
		opt_index="--index ${osd_indx}"
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
	#first_ip=$(echo "$osd_ips" | awk '{printf $1}')
	is_local_ip ${osd_ips[0]}|| sshcmd="ssh ${osd_ips[0]} -C"

	osd_create_zpool
	osd_mkfs
	osd_mount

	echo ""
}

##osd_prepare() {
##	read -r osd_type osd_indx osd_ips 
##}

create_mgt() {
	if [ ${#mgt[*]} -ne 1 ]; then
		errexit "only ONE mgs can be specified"
	fi

	read -r osd_ips osd_vdevs <<< ${mgt[0]}

	osd_ips=$(echo $osd_ips | tr ',' ' ')
	read -r -a osd_ips <<< "$osd_ips"
	osd_type=mgs
	osd_indx=0
	osd_dataset=mgt
	osd_pool=mgtpool
	osd_mountpoint=/var/lib/lustre/$fsname/mgt
	osd_create
}

create_mdts() {
	if [ ${#mdt[*]} -lt 1 ]; then
		errexit "at least one mdt is required"
	fi

	for ((i = 0; i < ${#mdt[*]}; i++)); do
		read -r osd_ips osd_vdevs <<< ${mdt[i]}

		osd_ips=$(echo $osd_ips | tr ',' ' ')
		read -r -a osd_ips <<< "$osd_ips"
		osd_type=mdt
		osd_indx=$i
		osd_dataset=${osd_type}${osd_indx}
		osd_pool=${fsname}-${osd_dataset}pool
		osd_mountpoint=/var/lib/lustre/$fsname/$osd_dataset
		osd_create
	done
}

create_osts() {
	if [ ${#ost[*]} -lt 1 ]; then
		errexit "at least one ost is required"
	fi

	for ((i = 0; i < ${#ost[*]}; i++)); do
		read -r osd_ips osd_vdevs <<< ${ost[i]}

		osd_ips=$(echo $osd_ips | tr ',' ' ')
		read -r -a osd_ips <<< "$osd_ips"
		osd_type=ost
		osd_indx=$i
		osd_dataset=${osd_type}${osd_indx}
		osd_pool=${fsname}-${osd_dataset}pool
		osd_mountpoint=/var/lib/lustre/$fsname/$osd_dataset
		osd_create
	done
}

main() {
	n=${#mgs_ips[*]}
	if [ $n -ne 1 -a $n -ne 2 ]; then
		errexit "mgs ips should be supplied"
	fi

	create_mgt

	create_mdts

	create_osts
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
