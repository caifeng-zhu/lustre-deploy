#!/bin/bash

logger_info() {
	logger -t "lvm_restore" -p user.info "$*"
}

runcmd() {
	logger_info $*
        eval "$*"
}

pv_get_vgname() {
	pvname=$1

	# the vg is obtained according to the pv
	vgname=$(pvs -o vgname --noheading --select="pv_name=$pvname")
	if [[ ${#vgname} == 0 ]]; then
		logger_info "can't get vgname from $pvname"
		exit 1
	fi
	echo $vgname
}

vg_get_refreshlv() {
	vgname=$1

	# the 5 character is state, X is unknown
	# the 6 character is device, X is unknown
	sublvs=$(lvs -a -o lvname --noheading --select "lv_attr=~....XX.*" $vgname)
	sublvs=$(echo $sublvs | tr '[]' ' ')

	# get toplv
	echo $sublvs | tr ' ' '\n' | cut -d'_' -f1 | sort | uniq
}

vg_get_unknownpv_cnt() {
	vgname=$1

	cnt=$(vgs -o pv_name --noheading $vgname | grep -c unknown)
	echo $cnt
}

dev_add() {
	pvname=$1
	vgname=$(pv_get_vgname $pvname)

	# restore vg
	# it is not possible to determine whether the missing device
	# is an lvmlock device, so add the lock space first.
	runcmd vgchange --lockstart $vgname
	# add a pv back into a vg after the pv was missing and then return.
	runcmd vgextend --restoremissing $vgname $pvname

	# restore lv
	# check wheather have unknown pvs, if so,
	# still need to wait for nvme to join.
	if [[ $(vg_get_unknownpv_cnt) -eq 0 ]]; then
		# restore lvs in vg
		lvs=$(vg_get_refreshlv $vgname)
		for lvname in $lvs; do
			# check again, if all the PVs for the VG are online.
			# if there is a pv that is in the missing state
			# but is not actually missing. update pv state.
			pvnames=$(vgs --noheading -o pv_name $vgname --select 'pv_missing=missing&&pv_name!=[unknown]')
			for pvname in $pvnames; do
				vg_restore $pvname
			done

			runcmd lvchange --refresh $vgname/$lvname
		done
	fi
}

dev_remove() {
	read -r major minor <<< $*

	dms=$(dmsetup deps -o devno | grep "($major, $minor)" | awk '{print $1}' | tr ':' ' ')
	for dm in $dms; do
		lvminfo=$(dmsetup splitname --nameprefixes --noheadings --rows $dm)
		lvname=$(echo $lvminfo | awk -F"DM_LV_NAME='" '{print $2}' | cut -d"'" -f1)
		vgname=$(echo $lvminfo | awk -F"DM_VG_NAME='" '{print $2}' | cut -d"'" -f1)

		if [[ $lvname == "lvmlock" ]]; then
			runcmd lvmlockctl -r $vgname
		fi
		runcmd dmsetup remove --force $dm
	done
}

oper=$1; shift 1
case $oper in
        add)
		logger_info "add" "$*"
		dev_add $*
                ;;
        remove)
		logger_info "remove" "$*"
		dev_remove $*
                ;;
        *)
                errexit "unknown operation: $oper"
                ;;
esac
