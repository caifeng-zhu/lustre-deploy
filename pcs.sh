#!/bin/bash

declare -A pcs_host
declare -A pcs_ipmi
declare -A pcs_lsvc

source ./pcs.conf

dryrun=

resource_zpool_create() {
	$dryrun pcs resource create $filesys-$1-zpool ocf:heartbeat:ZFS \
		pool=$filesys-${1}pool
}

resource_lustre_create() {
	$dryrun pcs resource create $filesys-$1-lustre ocf:lustre:Lustre \
		target=$filesys-${1}pool/$1 \
		mountpoint=/var/lib/lustre/$filesys/$1/
}

resource_group_create() {
	$dryrun pcs resource group add $filesys-$1-group  $filesys-$1-zpool  $filesys-$1-lustre

	locations=
	credit=200
	shift
	len=${#*}
	delta=$((credit / len))
	for h in $*; do
		locations="$locations $h=$credit "
		credit=$((credit - delta))
	done
	$dryrun pcs constraint location $filesys-$1-group prefers $locations
}

get_field() {
	i=$1; shift
	i=$((i - 1))

	fields=($*)
	$dryrun ${fields[$i]}
}

host_auth_create() {
	h=$1; shift

	$dryrun pcs host auth $h -u $(get_field 2 $*) -p $(get_field 3 $*)
}

ipmi_stonith_create() {
	h=$1; shift

	$dryrun pcs stonith create ipmi-$h fence_ipmilan lanplus=true \
		ipaddr="$(get_field 1 $*)" \
		login="$(get_field 2 $*)" \
		passwd="$(get_field 3 $*)" \
		pcmk_host_list=$h
}

lsvc_create_resources() {
	svc=$1; shift
	hosts="$*"

	resource_zpool_create $svc
	resource_lustre_create $svc
	resource_group_create $svc $hosts
}

sorted() {
	printf "%s\n" $* | sort
}

pcs_create_cluster() {
	hosts=
	for h in $(sorted ${!pcs_host[*]}); do
		host_auth_create $h ${pcs_host[$h]}
		hosts=" $hosts $h addr=$(get_field 1 ${pcs_host[$h]})"
	done

	$dryrun pcs cluster setup $cluster $hosts
}

pcs_create_resources() {
	for s in $(sorted ${!pcs_lsvc[*]}); do
		lsvc_create_resources $s ${pcs_lsvc[$s]}
	done
}

pcs_create_ipmi_stoniths() {
	for h in $(sorted ${!pcs_ipmi[*]}); do
		ipmi_stonith_create $h ${pcs_ipmi[$h]}
	done
}

main() {
	pcs_create_cluster
	pcs_create_resources
	pcs_create_ipmi_stoniths
}

main

while getopts "n" opt; do
        case $opt in
        n)      dryrun=echo;
        esac
done
