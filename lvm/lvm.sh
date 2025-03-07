#!/bin/bash

dryrun=

declare -A pv_tag

errexit() {
        echo $*
        exit 1
}

pv_add_tag() {
        for host in $vg_hostids; do
                for disk in $vg_diskids; do
                        pvchange --addtag ${pv_tag[$host]} $vg_disk_path/$host-$disk
                done
        done
}

vg_create() {
	pvs=()
        for host in $vg_hostids; do
                for disk in $vg_diskids; do
			pvs+=("$vg_disk_path/$host-$disk")
                done
        done
        vgcreate --share --locktype sanlock --alloc cling $vg_name ${pvs[@]}
}

vg_extend() {
	pvs=()
        for host in $vg_hostids; do
                for disk in $vg_diskids; do
			pvs+=("$vg_disk_path/$host-$disk")
                done
        done
	vgextend $vg_name ${pvs[@]}
}

source ./lvm.conf

oper=$1; shift 1
case $oper in
	create)
		vg_create
		pv_add_tag
		;;
	extend)
		vg_extend
		pv_add_tag
		;;
	*)
		errexit "unknown operation: $oper"
		;;
esac
