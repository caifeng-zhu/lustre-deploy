#!/bin/bash

copyset_fsname=		# lustre file system name
copyset_name=		# copyset name
copyset_nodes=
copyset_resource_types=

declare -A node_auth_table
declare -A node_ipmi_table
declare -A node_ltgt_table
node_pcmk_delay=

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
	pcs resource create $resource_name ocf:heartbeat:Lustre \
		target=$lustre_mountdev mountpoint=$lustre_mountpoint
}

resource_group_create() {
	tgt=$1
	node_active=$2
	node_backup=$3

	group_name=$tgt-group
	for rt in $copyset_resource_types; do
		case $rt in
		zfs)
			resource_name=$tgt-zfs
			zfs_pool=$copyset_fsname-${tgt}pool
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
			lustre_mountpoint=/var/lib/lustre/$copyset_fsname/$tgt
			resource_lustre_create
			;;

		*)
			errexit "unknown raid type"
			;;
		esac

		pcs resource group add $group_name $resource_name
	done

	pcs constraint location $group_name prefers $node_active=200 $node_backup=100
}

node_add_auth() {
	node=$1

	read -r addr user pass <<< ${node_auth_table[$node]}
	pcs host auth $1 addr=$addr -u $user -p $pass
}

node_add_groups() {
	node=$1
	next=$2
	for ltgt in ${node_ltgt_table[$node]}; do
		resource_group_create $ltgt $node $next
	done
}

node_add_stonith() {
	node=$1

	read -r addr login pass <<< ${node_ipmi_table[$node]}
	pcs stonith create ipmi-$node fence_ipmilan \
		lanplus=true ip=$addr username=$login password=$pass \
		privlvl=operator pcmk_host_list=$node $node_pcmk_delay
}

# Start pcs cluster. The setup can be handled by pcsd on cluster nodes.
# No ssh is needed.
#
# Reference:
# https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/\
# high_availability_add-on_reference/ch-clusteradmin-haar#s2-configurestartnodes-HAAR
#
copyset_start_pcs() {
	# build auth among hosts
	node_list=( $copyset_nodes )
	for node in ${node_list[@]}; do
		node_add_auth $node
	done

	# setup the cluster
	pcs cluster setup $copyset_fsname-$copyset_name ${node_list[@]} --force
	pcs cluster start --all

	# Ignore quorum for a two node copyset
	if [ ${#node_list[@]} -eq 2 ]; then
		pcs property set no-quorum-policy=ignore
	fi
}

copyset_create_groups() {
	node_list=( $copyset_nodes )
	for ((i = 0; i < ${#node_list[@]}; i++)); do
		j=$((i+1))
		if [ $j -eq ${#node_list[@]} ]; then
			j=0
		fi
		node_add_groups ${node_list[$i]} ${node_list[$j]}
	done
}

copyset_create_stoniths() {
	node_list=( $copyset_nodes )

	node_pcmk_delay=
	if [ ${#node_list[@]} -eq 2 ]; then
		# For a two node copyset, the first node is the active
		# one and its fencing should be delayed.
		node_pcmk_delay="pcmk_delay_base=2 pcmk_delay_max=3"
	fi

	for ((i = 0; i < ${#node_list[@]}; i++)); do
		node_add_stonith ${node_list[$i]}
		node_pcmk_delay=	# clear delay for all remaining nodes
	done
}

while getopts "nf:" opt; do
        case $opt in
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
	copyset_start_pcs
	copyset_create_groups
	copyset_create_stoniths
}

main
