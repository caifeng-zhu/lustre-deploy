#!/bin/bash

# this file is used by md-raid-device-lvm.rules to add
# a device to a running mdraid array. It should be put
# in directory /lib/lvm.

[ $# -ne 2 ] && exit 1

device=$1
raidname=${2##*:}
if [ ! -z "$raidname" ] && [ -e /dev/md/$raidname ]; then
	mdadm --add /dev/md/$raidname $device
fi
exit 0
