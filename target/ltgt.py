#!/usr/bin/env python

import sys
import os
import yaml
import argparse
from typing import List, Dict

from tgtconfig import ConfigAgent, ConfigItem


class Disk:
    gpt_table = {}

    def __init__(self, devpath):
        self.devpath = devpath

    def mklabel(self, agent):
        if self.devpath in Disk.gpt_table:
            return
        agent.execute('parted_label', self.devpath)
        Disk.gpt_table[self.devpath] = 1

    def mkpart(self, agent, partname, partsizes):
        agent.execute('parted_mkpart', self.devpath, partname,
                      partsizes[0], partsizes[1])

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
        self.disk.mklabel(agent)
        self.disk.mkpart(agent, self.name, self.partsizes)

    def destroy(self, agent):
        self.disk.rmpart(agent, self.name)


class DiskGroup:
    def __init__(self, cfg):
        self.cfg = ConfigItem(cfg)
        self._disks = None

    @property
    def disks(self):
        if self._disks is None:
            if self.cfg.disknames:
                self._disks = [Disk(f'{self.cfg.diskdir}/{diskname}')
                               for diskname in self.cfg.disknames]
            elif self.cfg.diskids and self.cfg.hostids:
                self._disks = [Disk(f'{self.cfg.diskdir}/{hostid}-{diskid}')
                               for diskid in self.cfg.diskids
                               for hostid in self.cfg.hostids]
            else:
                self._disks = []
        return self._disks

    def diskpaths(self):
        return [disk.devpath for disk in self.disks]

    def diskparts(self, prefix, partsizes, ndisk):
        if ndisk == 0:
            ndisk = len(self.disks)
        if ndisk == 1:
            return [Partition(prefix, partsizes, self.disks[0])]
        else:
            return [Partition(prefix + f'-{i}', partsizes, disk)
                    for i, disk in enumerate(self.disks)]


class Volume:
    def __init__(self, cfg, diskgroups):
        self.cfg = ConfigItem(cfg)
        self.diskgroup = diskgroups[self.cfg.diskgroup] if cfg else None

    def create(self, agent):
        pass

    def destroy(self, agent):
        pass


class NullVolume(Volume):
    """
    used for a nil journal volume to unify volume usage.
    """
    def __init__(self):
        super().__init__(None, None)

    @property
    def devpath(self):
        return '/dev/null'

    def create(self, agent):
        pass

    def destroy(self, agent):
        pass


class ZpoolVolume(Volume):
    def __init__(self, cfg, diskgroups):
        super().__init__(cfg, diskgroups)
        self.created = 0

    @property
    def devpath(self):
        return self.cfg.name

    def create(self, agent):
        if self.created:
            return
        agent.execute('zpool_create', self.cfg.name, self.cfg.raid,
                      *self.diskgroup.diskpaths())
        self.created = 1

    def destroy(self, agent):
        agent.execute('zpool_destroy', self.cfg.name)


class RaidVolume(Volume):
    def __init__(self, cfg, diskgroups):
        super().__init__(cfg, diskgroups)
        self._partitions = None

    @property
    def devpath(self):
        return f'/dev/md/{self.cfg.name}'

    @property
    def partitions(self):
        if self._partitions is None:
            ndisk = int(self.cfg.disknum) if self.cfg.disknum else 0
            self._partitions = self.diskgroup.diskparts(self.cfg.name, self.cfg.partsizes, ndisk)
        return self._partitions

    def create(self, agent):
        for part in self.partitions:
            part.create(agent)
        partpaths = [part.devpath for part in self.partitions]
        agent.execute('mdraid_create', self.cfg.name, self.cfg.raid, *partpaths)

    def destroy(self, agent):
        partpaths = [part.devpath for part in self.partitions]
        agent.execute('mdraid_destroy', self.cfg.name, self.cfg.raid, *partpaths)
        for part in self.partitions:
            part.destroy(agent)


class RawVolume(Volume):
    """
    Raw volumes exist to act as trivial wrappers on partition volumes.
    Their names are the same as the ones of patition volumes.
    """
    def __init__(self, cfg, diskgroups):
        super().__init__(cfg, diskgroups)
        self._partitons = None

    @property
    def partitions(self):
        if self._partitions is None:
            self._partitions = self.diskgroup.diskparts(self.cfg.name, self.cfg.partsizes, 1)
        return self._partitions

    @property
    def devpath(self):
        return self.partitions[0].devpath

    def create(self, agent):
        self.partitions[0].create(agent)

    def destroy(self, agent):
        self.partition.destroy(agent)


class LustreTgt:
    def __init__(self, cfg, lfs_cfg, volumes):
        self.cfg = ConfigItem(cfg)
        self.lfsname = lfs_cfg.fsname
        self.osdtype = lfs_cfg.osdtype
        self.mgsnids = ':'.join(lfs_cfg.mgsnids)
        self.svcnids = ':'.join(self.cfg.nids)
        self.ddev = volumes[self.cfg.vols[0]]
        self.jdev = volumes[self.cfg.vols[1]] if len(self.cfg.vols) > 1 else NullVolume()

    def create(self, agent):
        self.jdev.create(agent)
        self.ddev.create(agent)

        tgttype = self.cfg.name[0:3]
        cmd = f'{self.osdtype}_{tgttype}_create'
        agent.execute(cmd, self.lfsname, self.cfg.name, self.svcnids, self.mgsnids,
                      self.ddev.devpath, self.jdev.devpath)

    def destroy(self, agent):
        cmd = f'{self.osdtype}_tgt_destroy'
        agent.execute(cmd, self.lfsname, self.cfg.name, self.ddev.devpath)
        #print('destroy volumes', self.jdev, self.ddev, flush=True)

        self.jdev.destroy(agent)
        self.ddev.destroy(agent)

volume_classes = [
        {
            'raid1':    RaidVolume,
            'raid5':    RaidVolume,
            'raid6':    RaidVolume,
            'raw':      RawVolume,
        },
        {
            'mirror':   ZpoolVolume,
            'raidz1':   ZpoolVolume,
            'raidz2':   ZpoolVolume,
        },
]

class LustreNode:
    def __init__(self, cfg):
        self.cfg = ConfigItem(cfg)
        self.lfs_cfg = ConfigItem(cfg['lustre'])
        self._diskgroups = {}
        self._volumes = {}
        self._targets = []

    def find_volume_class(self, raid):
        global volume_classes
        if self.lfs_cfg.osdtype == 'ldiskfs':
            return volume_classes[0][raid]
        if self.lfs_cfg.osdtype == 'zfs':
            return volume_classes[1][raid]
        raise ValueError(f'unknown raidtype {raid} for osdtype {self.lfs_cfg.osdtype}')

    @property
    def diskgroups(self):
        if len(self._diskgroups) == 0:
            for dgc in self.cfg.diskgroups:
                self._diskgroups[dgc['name']] = DiskGroup(dgc)
        return self._diskgroups

    @property
    def volumes(self):
        if len(self._volumes) == 0:
            for vc in self.cfg.volumes:
                cls = self.find_volume_class(vc['raid'])
                self._volumes[vc['name']] = cls(vc, self.diskgroups)
        return self._volumes

    @property
    def targets(self):
        if len(self._targets) == 0:
            for tc in self.cfg.targets:
                self._targets.append(LustreTgt(tc, self.lfs_cfg, self.volumes))
        return self._targets

    def create(self, agent):
        for tgt in self.targets:
            tgt.create(agent)

    def destroy(self, agent):
        self.targets.reverse()
        for tgt in self.targets:
            tgt.destroy(agent)


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
