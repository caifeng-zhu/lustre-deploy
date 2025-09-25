#!/usr/bin/env python

import sys
import os
import yaml
import argparse
from typing import List, Dict

from tgtconfig import ConfigAgent


class DiskGroup:
    def __init__(self, cfg):
        self.cfg = cfg
        self._disks = None

    @property
    def disks(self):
        if self._disks:
            return self._disks
        diskdir = self.cfg['diskdir']
        if 'disknames' in self.cfg:
            self._disks = [Disk(f'{diskdir}/{diskname}')
                           for diskname in self.cfg['disknames']]
        elif 'diskids' in self.cfg and 'hostids' in self.cfg:
            self._disks = [Disk(f'{diskdir}/{hostid}-{diskid}')
                           for diskid in self.cfg['diskids']
                           for hostid in self.cfg['hostids']]
        return self._disks


def new_partitions(disks, partprefix, partsizes):
    if len(disks) == 1:
        return [Partition(partprefix, partsizes, disks[0])]
    else:
        return [Partition(partprefix + f'-{i}', partsizes, disk)
                for i, disk in enumerate(disks)]


class Disk:
    gpt_table = {}

    def __init__(self, devpath):
        self.devpath = devpath

    def mklabel(self, agent):
        if self.devpath not in Disk.gpt_table:
            agent.execute('parted_label', self.devpath)
            Disk.gpt_table[self.devpath] = 1


class Partition:
    def __init__(self, name, partsizes, disk):
        self.name = name
        self.partsizes = partsizes
        self.disk = disk

    @property
    def devpath(self):
        return f'/dev/disk/by-partlabel/{self.name}'

    def create(self, agent):
        self.disk.mklabel(agent)
        agent.execute('parted_mkpart', self.disk.devpath, self.name,
                      self.partsizes[0], self.partsizes[1])

    def destroy(self, agent):
        agent.execute('parted_rm', self.disk.devpath, self.name)


class NullDevice:
    """
    used for a nil journal volume to unify volume usage.
    """
    def __init__(self):
        pass

    @property
    def devpath(self):
        return '/dev/null'

    def create(self, agent):
        pass

    def destroy(self, agent):
        pass


class ZpoolDevice:
    def __init__(self, cfg, diskgroups):
        self.cfg = cfg
        self.diskgroups = diskgroups
        self.created = 0

    @property
    def name(self):
        return self.cfg['name']

    @property
    def raid(self):
        return self.cfg['type']

    @property
    def diskpaths(self):
        diskgroup = self.diskgroups[self.cfg['diskgroup']]
        return [disk.devpath for disk in diskgroup.disks]

    @property
    def devpath(self):
        return self.name

    def create(self, agent):
        if self.created:
            return
        agent.execute('zpool_create', self.name, self.raid, *self.diskpaths)
        self.created = 1

    def destroy(self, agent):
        agent.execute('zpool_destroy', self.name)


class RaidDevice:
    def __init__(self, cfg, diskgroups):
        self.cfg = cfg
        self.diskgroups = diskgroups
        self._partitions = None

    @property
    def name(self):
        return self.cfg['name']

    @property
    def raid(self):
        return self.cfg['type']

    @property
    def partitions(self):
        if self._partitions:
            return self._partitions
        diskgroup = self.diskgroups[self.cfg['diskgroup']]
        disks = diskgroup.disks
        if 'disknum' in self.cfg:
            n = int(cfg['disknum'])
            disks = disks[0:n]
        self._partitions = new_partitions(disks, self.cfg['name'], self.cfg['partsizes'])
        return self._partitions

    @property
    def devpath(self):
        return f'/dev/md/{self.name}'

    def create(self, agent):
        for part in self.partitions:
            part.create(agent)
        partpaths = [part.devpath for part in self.partitions]
        agent.execute('mdraid_create', self.name, self.raid, *partpaths)

    def destroy(self, agent):
        partpaths = [part.devpath for part in self.partitions]
        agent.execute('mdraid_destroy', self.name, self.raid, *partpaths)
        for part in self.partitions:
            part.destroy(agent)


class RawDevice:
    """
    Raw devices exist to act as trivial wrappers on partition devices.
    Their names are the same as the ones of patition devices.
    """
    def __init__(self, cfg, diskgroups):
        self.cfg = cfg
        self.diskgroups = diskgroups
        self._partitons = None

    @property
    def name(self):
        return self.cfg['name']

    @property
    def partition(self):
        if self._partitons:
            return self._partitons[0]
        diskgroup = self.diskgroups[self.cfg['diskgroup']]
        self._partitons = new_partitions(diskgroup.disks, self.name, self.cfg['partsizes'])
        return self._partitons[0]

    @property
    def devpath(self):
        return self.partition.devpath

    def create(self, agent):
        self.partition.create(agent)

    def destroy(self, agent):
        self.partition.destroy(agent)


class LustreTgt:
    def __init__(self, cfg, lfs: str, mgsnids: str, osdtype: str, devices):
        self.cfg = cfg
        self.devices = devices
        self.lfs = lfs
        self.osdtype = osdtype
        self.mgsnids = ':'.join(mgsnids)

    @property
    def name(self):
        return self.cfg['name']

    @property
    def ddev(self):
        return self.devices[self.cfg['devs'][0]]

    @property
    def jdev(self):
        if len(self.cfg['devs']) <= 1:
            return NullDevice()
        return self.devices[self.cfg['devs'][1]]

    @property
    def svcnids(self):
        return ':'.join(self.cfg['nids'])

    def create(self, agent):
        self.jdev.create(agent)
        self.ddev.create(agent)

        tgttype = self.name[0:3]
        cmd = f'{self.osdtype}_{tgttype}_create'
        agent.execute(cmd, self.lfs, self.name, self.svcnids, self.mgsnids,
                      self.ddev.devpath, self.jdev.devpath)

    def destroy(self, agent):
        cmd = f'{self.osdtype}_tgt_destroy'
        agent.execute(cmd, self.lfs, self.name, self.ddev.devpath)
        #print('destroy volumes', self.jdev, self.ddev, flush=True)

        self.jdev.destroy(agent)
        self.ddev.destroy(agent)


class LustreNode:
    def __init__(self, cfg):
        self.cfg = cfg
        self._diskgroups = None
        self._devices = None
        self._targets = None

    @property
    def lfs_osdtype(self):
        return self.cfg['lustre']['osdtype']

    @property
    def lfs_fsname(self):
        return self.cfg['lustre']['fsname']

    @property
    def lfs_mgsnids(self):
        return self.cfg['lustre']['mgsnids']

    @property
    def diskgroups(self):
        if not self._diskgroups:
            self._diskgroups = {}
            for dgc in self.cfg['diskgroups']:
                self._diskgroups[dgc['name']] = DiskGroup(dgc)
        return self._diskgroups

    @property
    def devices(self):
        if not self._devices:
            self._devices = {}
            for devc in self.cfg['devices']:
                cls = find_device_class(self.lfs_osdtype, devc['type'])
                self._devices[devc['name']] = cls(devc, self.diskgroups)
        return self._devices

    @property
    def targets(self):
        if not self._targets:
            self._targets = [LustreTgt(tgtc, self.lfs_fsname, self.lfs_mgsnids,
                                       self.lfs_osdtype, self.devices)
                             for tgtc in self.cfg['targets']]
        return self._targets

    def create(self, agent):
        for tgt in self.targets:
            tgt.create(agent)

    def destroy(self, agent):
        self.targets.reverse()
        for tgt in self.targets:
            tgt.destroy(agent)

device_classes = {
    'ldiskfs/raid1':    RaidDevice,
    'ldiskfs/raid5':    RaidDevice,
    'ldiskfs/raid6':    RaidDevice,
    'ldiskfs/raw':      RawDevice,
    'zfs/mirror':       ZpoolDevice,
    'zfs/raidz1':       ZpoolDevice,
    'zfs/raidz2':       ZpoolDevice,
}
def find_device_class(osdtype, raid):
    global device_classes
    tag = osdtype + '/' + raid
    if tag in device_classes:
        return device_classes[tag]
    raise ValueError(f'unknown raidtype {raid} for osdtype {osdtype}')


def build(config):
    lnode = LustreNode(config)
    agents = ConfigAgent.from_config(config['agents'])
    return agents, lnode


def create(agents, lnode):
    for agent in agents:
        lnode.create(agent)


def destroy(agents, lnode):
    for agent in agents:
        lnode.destroy(agent)


def main():
    parser = argparse.ArgumentParser(description="target script")
    parser.add_argument(dest='operation', choices=['create', 'destroy'],
                        help="create/destroy/monitor lustre deployment")
    parser.add_argument('-c', '--config', type=str, default='./ltgt.yaml',
                        help="Path to the config file")
    args = parser.parse_args()

    with open(args.config, 'r') as f:
        config = yaml.safe_load(f)

    agents, lnode = build(config)
    if args.operation == 'create':
        create(agents, lnode)
    elif args.operation == 'destroy':
        destroy(agents, lnode)


if __name__ == "__main__":
    main()
