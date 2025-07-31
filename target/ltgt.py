#!/usr/bin/env python

import sys
import os
import yaml
import argparse
from typing import List, Dict
import pyinotify

from tgtconfig import ConfigAgent, ConfigData


class DiskGroup:
    def __init__(self, cfg):
        cfgdt = ConfigData(cfg)
        if 'disknames' in cfgdt.cfg:
            disknames = cfgdt.disknames
        else:
            disknames = [
                f'{hostid}-{diskid}'
                for diskid in cfgdt.diskids
                for hostid in cfgdt.hostids
            ]

        self.disks = [Disk(f'{cfgdt.diskdir}/{name}') for name in disknames]

    def partitions(self, partprefix, partsizes, ndisk):
        parts = []
        if ndisk <= 0:
            ndisk = len(self.disks)
        for i in range(ndisk):
            partname = partprefix if ndisk == 1 else f'{partprefix}-{i}'
            parts.append(Partition(partname, partsizes, self.disks[i]))
        return parts


class Disk:
    gpt_table = {}

    def __init__(self, devpath):
        self.devpath = devpath

    def mkpart(self, agent, partname, partstart, partend):
        if self.devpath not in Disk.gpt_table:
            Disk.gpt_table[self.devpath] = 1
            agent.execute('parted_label', self.devpath)
        agent.execute('parted_mkpart', self.devpath, partname,
                      partstart, partend)

    def rmpart(self, agent, partname):
        agent.execute('parted_rm', self.devpath, partname)


class Partition:
    def __init__(self, name, partsizes, disk):
        self.name = name
        self.partsizes = partsizes
        self.disk = disk

    @property
    def devpath(self):
        return f'/dev/disk/by-partlabel/{self.name}'

    def create(self, agent):
        self.disk.mkpart(agent, self.name, self.partsizes[0], self.partsizes[1])

    def destroy(self, agent):
        self.disk.rmpart(agent, self.name)


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
        cfgdt = ConfigData(cfg)
        dg = diskgroups[cfgdt.diskgroup]

        self.name = cfgdt.name
        self.raid = cfgdt.type
        self.diskpaths = [disk.devpath for disk in dg.disks]
        self.created = 0

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
        cfgdt = ConfigData(cfg)
        dg = diskgroups[cfgdt.diskgroup]
        ndisk = int(cfgdt.disknum) if 'disknum' in cfgdt.cfg else -1

        self.name = cfgdt.name
        self.type = cfgdt.type
        self.partitions = dg.partitions(cfgdt.name, cfgdt.partsizes, ndisk)

    @property
    def devpath(self):
        return f'/dev/md/{self.name}'

    def create(self, agent):
        for part in self.partitions:
            part.create(agent)
        partpaths = [part.devpath for part in self.partitions]
        agent.execute('mdraid_create', self.name, self.type, *partpaths)

    def destroy(self, agent):
        partpaths = [part.devpath for part in self.partitions]
        agent.execute('mdraid_destroy', self.name, self.type, *partpaths)
        for part in self.partitions:
            part.destroy(agent)


class RawDevice:
    """
    Raw devices exist to act as trivial wrappers on partition devices.
    Their names are the same as the ones of patition devices.
    """
    def __init__(self, cfg, diskgroups):
        cfgdt = ConfigData(cfg)
        dg = diskgroups[cfgdt.diskgroup]

        self.name = cfgdt.name
        self.partitions = dg.partitions(self.name, cfgdt.partsizes, 1)

    @property
    def devpath(self):
        return self.partitions[0].devpath

    def create(self, agent):
        self.partitions[0].create(agent)

    def destroy(self, agent):
        self.partitions[0].destroy(agent)


class LustreTgt:
    def __init__(self, cfg, lfs: str, mgsnids: str, osdtype: str, devices):
        cfgdt = ConfigData(cfg)
        mydevs = [devices[name] for name in cfgdt.devs]
        mydevs.append(NullDevice())

        self.lfs = lfs
        self.osdtype = osdtype
        self.mgsnids = ':'.join(mgsnids)
        self.svcnids = ':'.join(cfgdt.nids)
        self.name = cfgdt.name
        self.ddev = mydevs[0]
        self.jdev = mydevs[1]

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
        cfgdt = ConfigData(cfg)
        lfscfg = cfgdt.lustre
        diskgroups = {
            cfg['name']: DiskGroup(cfg)
            for cfg in cfgdt.diskgroups
        }
        devices = {
            cfg['name']:
            find_device_class(lfscfg['osdtype'], cfg['type'])(cfg, diskgroups)
            for cfg in cfgdt.devices
        }

        self.targets = [
            LustreTgt(cfg, lfscfg['fsname'], lfscfg['mgsnids'], lfscfg['osdtype'], devices)
            for cfg in cfgdt.targets
        ]

    def create(self, agent):
        for tgt in self.targets:
            tgt.create(agent)

    def destroy(self, agent):
        self.targets.reverse()
        for tgt in self.targets:
            tgt.destroy(agent)

device_classes = {
    'ldiskfs': {
        'raid1':    RaidDevice,
        'raid5':    RaidDevice,
        'raid6':    RaidDevice,
        'raw':      RawDevice,
    },
    'zfs': {
        'mirror':   ZpoolDevice,
        'raidz1':   ZpoolDevice,
        'raidz2':   ZpoolDevice,
    },
}
def find_device_class(osdtype, raid):
    global device_classes
    if osdtype in device_classes and raid in device_classes[osdtype]:
        return device_classes[osdtype][raid]
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
