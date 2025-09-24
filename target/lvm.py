#!/usr/bin/env python

import yaml
import argparse
from tgtconfig import ConfigAgent

class DiskGroup:
    def __init__(self, cfg):
        self.cfg = cfg

    @property
    def disks(self):
        diskdir = self.cfg['diskdir']
        return [f'{diskdir}/{hostid}-{diskid}'
                for diskid in self.cfg['diskids']
                for hostid in self.cfg['hostids']]


class RaidDevice:
    def __init__(self, cfg, diskgroups):
        self.cfg = cfg
        self.diskgroups = diskgroups

    @property
    def name(self):
        return self.cfg['name']

    @property
    def type(self):
        return self.cfg['type']

    @property
    def diskgroup(self):
        return self.diskgroups[self.cfg['diskgroup']]

    @property
    def devpath(self):
        return f'/dev/md/{self.name}'

    def create(self, agent):
        agent.execute('mdraid_create', self.name, self.type, *self.diskgroup.disks)

    def destroy(self, agent):
        agent.execute('mdraid_destroy', self.name, self.type, *self.diskgroup.disks)


class LvmVg:
    def __init__(self, cfg, devices):
        self.cfg = cfg
        self.devices = devices

    @property
    def name(self):
        return self.cfg['name']

    @property
    def device(self):
        return self.devices[self.cfg['device']]

    def create(self, agent):
        self.device.create(agent)

        cmd = 'lvm_vg_create'
        agent.execute(cmd, self.name, self.device.name)

    def destroy(self, agent):
        cmd = 'lvm_vg_destroy'
        agent.execute(cmd, self.name, self.device.name)

        self.device.destroy(agent)

class LvmTopology:
    def __init__(self, cfg):
        self.cfg = cfg
        self._vgs = None
        self._diskgroups = None
        self._devices = None

    @property
    def diskgroups(self):
        if not self._diskgroups:
            self._diskgroups = {
                    dg['name']: DiskGroup(dg)
                    for dg in self.cfg['diskgroups']}
        return self._diskgroups

    @property
    def devices(self):
        if not self._devices:
            self._devices = {
                    dev['name']: RaidDevice(dev, self.diskgroups)
                    for dev in self.cfg['devices']}
        return self._devices

    @property
    def vgs(self):
        if not self._vgs:
            self._vgs = [LvmVg(vg, self.devices) for vg in self.cfg['vgs']]
        return self._vgs

    def create(self, agent):
        for vg in self.vgs:
            vg.create(agent)

    def destroy(self, agent):
        for vg in self.vgs[::-1]:
            vg.destroy(agent)


def build(cfg):
    topology = LvmTopology(cfg)
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
