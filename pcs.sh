#!/bin/bash

ha_fsname=		# lustre file system name
ha_csname=		# copyset name

declare -a node_list
declare -a node_auth_list
declare -a node_ipmi_list
declare	   node_idx

declare -a group_lustretgt_list
declare -a group_resources_list
declare -a group_locations_list
declare    group_name

# general resource variables
resource_name=		# resource name

# mdraid resource variables
mdraid_conf=
mdraid_dev=

# zfs resource variables
zfs_pool=

# lustre resource variables
lustre_mountdev=
lustre_mountpoint=

dryrun=
configfile="./pcs.conf"

errexit() {
        printf "$*\n"
        exit 1
}

resource_zfs_create() {
	pcs resource create $resource_name ocf:heartbeat:ZFS $zfs_pool
}

resource_mdraid_create() {
	pcs resource create $resource_name ocf:heartbeat:mdraid \
		mdadm_conf=$mdraid_conf md_dev=$mdraid_dev
}

resource_lustre_create() {
	# NOTE: mountpoint path must NOT have trailing / since
	# realpath will complain by error.
	pcs resource create $resource_name ocf:lustre:Lustre \
		target=$lustre_mountdev mountpoint=$lustre_mountpoint
}

resource_group_create() {
	idx=$1
	tgt=$2

	group_name=$tgt-group

	resources=( ${group_resources_list[$idx]} )
	for resrc in ${resources[@]}; do
		case $resrc in
		zpool)
			resource_name=$tgt-zpool
			zfs_pool=$ha_fsname-${tgt}pool
			resource_zfs_create

			lustre_mountdev=$zfs_pool/$tgt
			;;

		mdraid_journal)
			resource_name=$tgt-journal
			mdraid_conf=/etc/mdadm/$tgt.conf
			mdraid_dev=/dev/md/$tgt-journal
			resource_mdraid_create
			;;

		mdraid_data)
			resource_name=$tgt-data
			mdraid_conf=/etc/mdadm/$tgt.conf
			mdraid_dev=/dev/md/$tgt-data
			resource_mdraid_create

			lustre_mountdev=$mdraid_dev
			;;

		lustre)
			resource_name=$tgt-lustre
			lustre_mountpoint=/var/lib/lustre/$ha_fsname/$tgt
			resource_lustre_create
			;;

		*)
			errexit "unknown raid type"
			;;
		esac

		pcs resource group add $group_name $resource_name
	done

	pcs constraint location $group_name prefers ${group_locations_list[$idx]}
}

# Start pcs cluster. The setup can be handled by pcsd on cluster nodes.
# No ssh is needed.
#
# Reference:
# https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/\
# high_availability_add-on_reference/ch-clusteradmin-haar#s2-configurestartnodes-HAAR
#
ha_start_cluster() {
	# build host auth among hosts
	for i in ${!node_name_list[@]}; do
		node=${node_name_list[$i]}
		read -r addr user pass <<< ${node_auth_list[$i]}
		pcs host auth $node addr=$addr -u $user -p $pass
	done

	# setup the cluster
	pcs cluster setup $ha_fsname-$ha_csname ${node_name_list[@]}
	pcs cluster start --all
}

ha_create_groups() {
	for i in ${!group_lustretgt_list[@]}; do
		resource_group_create $i ${group_lustretgt_list[$i]}
	done
}

ha_create_stoniths() {
	for i in ${!node_name_list[@]}; do
		node=${node_name_list[$i]}
		read -r addr login pass <<< ${node_ipmi_list[$i]}
		pcs stonith create ipmi-$node fence_ipmilan \
			lanplus=true ipaddr=$addr login=$login passwd=$pass \
			pcmk_host_list=$node
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
