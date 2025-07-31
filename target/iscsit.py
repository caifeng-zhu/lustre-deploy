#!/usr/bin/env python

import yaml
import sys
import argparse
from tgtconfig import ConfigAgent, ConfigData


class IscsitTopology:
    def __init__(self, cfg):
        cfgdt = ConfigData(cfg)
        hostid = cfgdt.hostid
        self.targets = [IscsitTarget(cfg, hostid) for cfg in cfgdt.targets]

    def create(self, agent):
        for tgt in self.targets:
            tgt.create(agent)
        for tgt in self.targets:
            tgt.connect(agent)
        agent.execute('iscsit_saveconfig')

    def destroy(self, agent):
        for tgt in self.targets:
            tgt.disconnect(agent)
        for tgt in self.targets:
            tgt.destroy(agent)
        agent.execute('iscsit_clear')


class IscsitTarget:
    def __init__(self, cfg, hostid):
        cfgdt = ConfigData(cfg)

        self.iqn = f'iqn.2024-04.com.ebtech.{hostid}.{cfgdt.name}'
        self.portals = [IscsitPortal(cfg, self.iqn) for cfg in cfgdt.portals]
        self.acls = [IscsitAcl(acl, self.iqn) for acl in cfgdt.acls]
        self.luns = [IscsitLun(cfg, hostid, self.iqn) for cfg in cfgdt.luns]

    def create(self, agent):
        agent.execute('iscsit_iqn_create', self.iqn)

        for portal in self.portals:
            portal.create(agent)

        for acl in self.acls:
            acl.create(agent)

        for lun in self.luns:
            lun.create(agent)

    def connect(self, agent):
        for portal in self.portals:
            portal.connect(agent)

    def disconnect(self, agent):
        for portal in self.portals:
            portal.disconnect(agent)

    def destroy(self, agent):
        for portal in self.portals:
            portal.destroy(agent)

        for acl in self.acls:
            acl.destroy(agent)

        for lun in self.luns:
            lun.destroy(agent)

        agent.execute('iscsit_iqn_destroy', self.iqn)


class IscsitPortal:
    def __init__(self, cfg, iqn):
        cfgdt = ConfigData(cfg)

        self.iqn = iqn
        self.addr = cfgdt.addr
        self.port = cfgdt.port

    def create(self, agent):
        agent.execute('iscsit_portal_create', self.iqn, self.addr, self.port)

    def connect(self, agent):
        agent.execute('iscsit_portal_connect', self.iqn, self.addr, self.port)

    def disconnect(self, agent):
        agent.execute('iscsit_portal_disconnect', self.iqn, self.addr, self.port)

    def destroy(self, agent):
        agent.execute('iscsit_portal_destroy', self.iqn, self.addr, self.port)


class IscsitAcl:
    def __init__(self, acl, iqn):
        self.acl = acl
        self.iqn = iqn

    def create(self, agent):
        agent.execute('iscsit_acl_create', self.iqn, self.acl)

    def destroy(self, agent):
        pass


class IscsitLun:
    def __init__(self, cfg, hostid, iqn):
        cfgdt = ConfigData(cfg)

        self.iqn = iqn
        self.hostid = hostid
        self.lunid = cfgdt.lunid
        self.lunpath = cfgdt.lunpath

    def create(self, agent):
        if len(self.lunid) > 16:
            print("legth of lunid is greater than 16")
            sys.exit(1)
        agent.execute('iscsit_lun_create', self.iqn,
                      f'{self.hostid}-{self.lunid}', self.lunpath)

    def destroy(self, agent):
        pass


def build(config):
    topology = IscsitTopology(config)
    agents = ConfigAgent.from_config(config['agents'])
    return agents, topology


def create(agents, topology):
    for agent in agents:
        topology.create(agent)


def destroy(agents, topology):
    agents.reverse()
    for agent in agents:
        topology.destroy(agent)


def main():
    parser = argparse.ArgumentParser(description="iscsi target configuration script")
    parser.add_argument('-c', '--config', type=str, default='./iscsit.yaml',
        help="Path to the config file")
    parser.add_argument(dest='operation', choices=['create', 'destroy'],
                        help="create/destroy iscsit deployment")
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
