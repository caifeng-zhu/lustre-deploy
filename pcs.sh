#!/bin/bash

declare -A pcs_host
declare -A pcs_ipmi
declare -A pcs_lsvc

filesys=
cluster=

dryrun=
sshcmd=
configfile="./pcs.conf"

errexit() {
        printf "$*\n"
        exit 1
}

sorted() {
	printf "%s\n" $* | sort
}

resource_zpool_create() {
	read -r svc <<< $*

	$dryrun $sshcmd pcs resource create $filesys-$svc-zpool ocf:heartbeat:ZFS \
		pool=$filesys-${svc}pool
}

resource_lustre_create() {
	read -r svc <<< $*

	$dryrun $sshcmd pcs resource create $filesys-$svc-lustre ocf:lustre:Lustre \
		target=$filesys-${svc}pool/$svc \
		mountpoint=/var/lib/lustre/$filesys/$svc/
}

resource_group_create() {
	read -r svc <<< $*

	$dryrun $sshcmd pcs resource group add $filesys-$svc-group \
		$filesys-$svc-zpool $filesys-$svc-lustre
}

resource_constraint_create() {
	svc=$1; shift
	read -r -a hosts <<< $*

	credit=200
	len=${#hosts[*]}
	delta=$((credit / len))

	locations=

	for h in ${hosts[*]}; do
		locations="$locations $h=$credit "
		credit=$((credit - delta))
	done

	$dryrun $sshcmd pcs constraint location $filesys-$svc-group prefers $locations
}

host_auth_create() {
	read -r host addr user passwd <<< $*

	$dryrun $sshcmd pcs host auth $host addr=$addr -u $user -p $passwd
}

ipmi_stonith_create() {
	read -r h addr login passwd interval base max <<< $*

	$dryrun $sshcmd pcs stonith create ipmi-$h fence_ipmilan lanplus=true \
		ipaddr=$addr login=$login passwd=$passwd pcmk_host_list=$h
}

lsvc_create_resources() {
	svc=$1; shift
	read -r hosts <<< $*

	resource_zpool_create $svc
	resource_lustre_create $svc
	resource_group_create $svc
	resource_constraint_create $svc $hosts
}

pcs_set_sshcmd() {
	read -r -a hosts <<< $(sorted ${!pcs_host[*]})
	read -r addr user passwd <<< ${pcs_host[$hosts]}

	if ! ip addr | grep -q $addr; then
		sshcmd="ssh $addr -C"
	else
		sshcmd=
	fi
}

pcs_create_cluster() {
	pcs_set_sshcmd

	hosts=

	for h in $(sorted ${!pcs_host[*]}); do
		host_auth_create $h ${pcs_host[$h]}

		read -r addr user passwd <<< ${pcs_host[$h]}

		hosts=" $hosts $h addr=$addr"
	done

	$dryrun $sshcmd pcs cluster setup $cluster $hosts
}

pcs_create_resources() {
	pcs_set_sshcmd

	for s in $(sorted ${!pcs_lsvc[*]}); do
		lsvc_create_resources $s ${pcs_lsvc[$s]}
	done
}

pcs_create_ipmi_stoniths() {
	for h in $(sorted ${!pcs_ipmi[*]}); do
		ipmi_stonith_create $h ${pcs_ipmi[$h]}
	done
}

pcs_start_service() {
	for h in $(sorted ${!pcs_host[*]}); do
		read -r -a addr <<< ${pcs_host[$h]}

		if ! ip addr | grep -q $addr; then
			sshcmd="ssh $addr -C"
		fi
		$dryrun $sshcmd systemctl start pacemaker.service
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
	pcs_create_cluster
	pcs_start_service
	pcs_create_resources
	pcs_create_ipmi_stoniths
}

main
