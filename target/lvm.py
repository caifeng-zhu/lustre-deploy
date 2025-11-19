#!/usr/bin/env python

import argparse
import yaml
from tgtconfig import ConfigAgent, ConfigItem

class DiskGroup:
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.diskpaths = [f'{cfg.diskdir}/{hostid}-{diskid}'
                          for diskid in cfg.diskids
                          for hostid in cfg.hostids]


class RaidVolume:
    def __init__(self, cfgdata, diskgroups):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.type = cfg.type
        self.diskgroup = diskgroups[cfg.diskgroup]

    @property
    def devpath(self):
        return f'/dev/md/{self.name}'

    def create(self, agent):
        agent.execute('mdraid_create', self.name, self.type, *self.diskgroup.diskpaths)

    def destroy(self, agent):
        agent.execute('mdraid_destroy', self.name, self.type, *self.diskgroup.diskpaths)


class LvmVg:
    def __init__(self, cfgdata, volumes):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.volume = volumes[cfg.volume]

    def create(self, agent):
        self.volume.create(agent)
        agent.execute('lvm_vg_create', self.name, self.volume.name)

    def destroy(self, agent):
        agent.execute('lvm_vg_destroy', self.name, self.volume.name)
        self.volume.destroy(agent)


class LvmNode:
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.diskgroups = {dg['name']: DiskGroup(dg)
                           for dg in cfg.diskgroups}
        self.volumes = {dev['name']: RaidVolume(dev, self.diskgroups)
                        for dev in cfg.volumes}
        self.vgs = [LvmVg(vg, self.volumes) for vg in cfg.vgs]

    def create(self, agent):
        for vg in self.vgs:
            vg.create(agent)

    def destroy(self, agent):
        for vg in self.vgs[::-1]:
            vg.destroy(agent)


def build(cfg):
    topology = LvmNode(cfg)
    agents = ConfigAgent.from_config(cfg['agents'])
    return agents, topology


def create(agents, topology):
    for agent in agents:
        topology.create(agent)


def destroy(agents, topology):
    for agent in agents:
        topology.destroy(agent)


def main():
    # Set up argument parser to get the config file
    parser = argparse.ArgumentParser(description="lvm target configuration script")
    parser.add_argument('-c', '--config', type=str, required=True,
                        help="Path to the config file")
    parser.add_argument(dest='operation', choices=['create', 'destroy'],
                        help="create/destroy lvmt deployment")
    args = parser.parse_args()
    config_file = args.config

    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)

    agents, topology = build(config)
    if args.operation == 'create':
        create(agents, topology)
    if args.operation == 'destroy':
        destroy(agents, topology)


if __name__ == "__main__":
    main()
