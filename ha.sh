#!/bin/bash

ha_fsname=		# lustre file system name
ha_csname=		# copyset name

declare -a node_list
declare -A node_auth_table
declare -A node_ipmi_table

declare -a tgt_raids
declare -A tgt_location_table
tgt_datadev=

dryrun=
sshcmd=
configfile="./ha.conf"

errexit() {
        printf "$*\n"
        exit 1
}

runcmd() {
	$*
}

resource_zpool_create() {
	rgroup=$1
	tgt=$2

	rname=$tgt-zpool
	pname=$ha_fsname-${tgt}pool
	pcs resource create $rname ocf:heartbeat:ZFS $pname
	pcs resource group add $rgroup $rname

	tgt_datadev=$pname/$tgt
}

resource_mdraid_create() {
	rgroup=$1
	tgt=$2
	jd=$3		# journal or data

	rname=$tgt-raid-$jd
	pcs resource create $rname ocf:heartbeat:mdraid \
		mdadm_conf=/etc/lustre_tgt/$tgt.conf md_dev=/dev/md/$tgt-$jd
	pcs resource group add $rgroup $rname

	tgt_datadev=/dev/md/$tgt-data
}

resource_raid_create() {
	rgroup=$1
	tgt=$2

	for raid in ${tgt_raids[@]}; do
		case $raid in
		zpool)
			resource_zpool_create $rgroup $tgt
			;;

		mdraid_journal)
			resource_mdraid_create $rgroup $tgt journal
			;;

		mdraid_data)
			resource_mdraid_create $rgroup $tgt data
			;;

		*)
			errexit "unknown raid type"
			;;
		esac
	done
}

resource_lustre_create() {
	rgroup=$1
	tgt=$2

	rname=$tgt-lustre
	pcs resource create $rname ocf:lustre:Lustre \
		target=$tgt_datadev \
		mountpoint=/var/lib/lustre/$ha_fsname/$tgt/
	pcs resource group add $rgroup $rname
}

resource_group_create() {
	tgt=$1

	rgroup=$tgt-group
	resource_raid_create $rgroup $tgt
	resource_lustre_create $rgroup $tgt
	pcs constraint location $rgroup prefers ${tgt_location_table[$tgt]}
}

stonith_create() {
	node=$1

	read -r addr login pass <<< ${node_ipmi_table[$node]}
	pcs stonith create ipmi-$node fence_ipmilan \
		lanplus=true ipaddr=$addr login=$login passwd=$pass \
		pcmk_host_list=$node
}

ha_start_cluster() {
	# build host auth among hosts
	for node in ${node_list[@]}; do
		read -r addr user pass <<< ${node_auth_table[$node]}
		pcs host auth $node addr=$addr -u $user -p $pass
	done

	# setup the cluster
	pcs cluster setup $ha_fsname-$ha_csname ${node_list[@]}
	pcs cluster start --all
}

ha_create_groups() {
	for tgt in ${tgt_list[@]}; do
		resource_group_create $tgt
	done
}

ha_create_stoniths() {
	for node in ${node_list[@]}; do
		stonith_create $node
	done
}

while getopts "nf:" opt; do
        case $opt in
        n)      dryrun=echo;;
	f)	configfile=$OPTARG;;
	*)	errexit "unknown option $opt";;
        esac
done
shift $((OPTIND - 1))

if [ -z $configfile ] || [ ! -e $configfile ]; then
	usage
fi

source $configfile

main() {
	ha_start_cluster
	ha_create_groups
	#ha_create_stoniths
}

main
