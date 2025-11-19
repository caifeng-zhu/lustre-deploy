#!/usr/bin/env python

import argparse
import yaml
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
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        diskpaths = []
        if cfg.disknames:
            diskpaths = [f'{cfg.diskdir}/{diskname}' for diskname in cfg.disknames]
        if cfg.diskids and cfg.hostids:
            diskpaths = [f'{cfg.diskdir}/{hostid}-{diskid}'
                         for diskid in cfg.diskids
                         for hostid in cfg.hostids]
        self.disks = [Disk(path) for path in diskpaths]

    def diskpaths(self):
        return [disk.devpath for disk in self.disks]

    def diskparts(self, prefix, partsizes, ndisk):
        if ndisk == 0:
            ndisk = len(self.disks)

        if ndisk == 1:
            return [Partition(prefix, partsizes, self.disks[0])]
        return [Partition(prefix + f'-{i}', partsizes, disk)
                for i, disk in enumerate(self.disks)]


class Volume:
    def __init__(self, cfgdata, diskgroups):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.raid = cfg.raid
        self.partsizes = cfg.partsizes
        self.ndisk = int(cfg.disknum) if cfg.disknum else 0
        self.diskgroup = diskgroups[cfg.diskgroup] if diskgroups else None

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
        return self.name

    def create(self, agent):
        if self.created:
            return
        agent.execute('zpool_create', self.name, self.raid,
                      *self.diskgroup.diskpaths())
        self.created = 1

    def destroy(self, agent):
        agent.execute('zpool_destroy', self.name)


class RaidVolume(Volume):
    def __init__(self, cfg, diskgroups):
        super().__init__(cfg, diskgroups)
        self.partitions = self.diskgroup.diskparts(self.name, self.partsizes, self.ndisk)

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


class RawVolume(Volume):
    """
    Raw volumes exist to act as trivial wrappers on partition volumes.
    Their names are the same as the ones of patition volumes.
    """
    def __init__(self, cfg, diskgroups):
        super().__init__(cfg, diskgroups)
        self.partitions = self.diskgroup.diskparts(self.name, self.partsizes, 1)

    @property
    def devpath(self):
        return self.partitions[0].devpath

    def create(self, agent):
        self.partitions[0].create(agent)

    def destroy(self, agent):
        self.partitions[0].destroy(agent)


class LustreTgt:
    def __init__(self, cfgdata, lfs_cfg, volumes):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.svcnids = ':'.join(cfg.nids)
        self.dvol = volumes[cfg.vols[0]]
        self.jvol = volumes[cfg.vols[1]] if len(cfg.vols) > 1 else NullVolume()
        self.lfsname = lfs_cfg.fsname
        self.osdtype = lfs_cfg.osdtype
        self.mgsnids = ':'.join(lfs_cfg.mgsnids)

    def create(self, agent):
        self.jvol.create(agent)
        self.dvol.create(agent)

        tgttype = self.name[0:3]
        cmd = f'{self.osdtype}_{tgttype}_create'
        agent.execute(cmd, self.lfsname, self.name, self.svcnids, self.mgsnids,
                      self.dvol.devpath, self.jvol.devpath)

    def destroy(self, agent):
        cmd = f'{self.osdtype}_tgt_destroy'
        agent.execute(cmd, self.lfsname, self.name, self.dvol.devpath)

        self.jvol.destroy(agent)
        self.dvol.destroy(agent)

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
def volume_class(osdtype, raid):
    global volume_classes
    if osdtype == 'ldiskfs':
        return volume_classes[0][raid]
    if osdtype == 'zfs':
        return volume_classes[1][raid]
    raise ValueError(f'unknown raidtype {raid} for osdtype {osdtype}')


class LustreNode:
    def __init__(self, cfgdata):
        cfg, lfs_cfg = ConfigItem(cfgdata), ConfigItem(cfgdata['lustre'])
        self.diskgroups = {dgc['name']: DiskGroup(dgc)
                           for dgc in cfg.diskgroups}
        self.volumes = {vc['name']: volume_class(lfs_cfg.osdtype, vc['raid'])(vc)
                        for vc in cfg.volumes}
        self.targets = [LustreTgt(tc, lfs_cfg, self.volumes) for tc in cfg.targets]

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
