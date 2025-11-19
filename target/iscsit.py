#!/usr/bin/env python

import argparse
import yaml
import sys
from tgtconfig import ConfigAgent, ConfigItem


class IscsitPortal:
    def __init__(self, cfgdata, iqn):
        cfg = ConfigItem(cfgdata)
        self.iqn = iqn
        self.addr = cfg.addr
        self.port = cfg.port

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
    def __init__(self, cfgdata, hostid, iqn):
        cfg = ConfigItem(cfgdata)
        self.iqn = iqn
        self.hostid = hostid
        self.lunid = cfg.lunid
        self.devid = cfg.devid
        self.devpath = cfg.devpath

    def create(self, agent):
        if len(self.devid) > 16:
            print("length of devid is greater than 16")
            sys.exit(1)
        agent.execute('iscsit_lun_create', self.iqn,
                      f'{self.hostid}-{self.devid}', self.devpath, self.lunid)

    def destroy(self, agent):
        agent.execute('iscsit_lun_destroy', self.iqn,
                      f'{self.hostid}-{self.devid}', self.devpath, self.lunid)


class IscsitTarget:
    def __init__(self, cfgdata, hostid):
        cfg = ConfigItem(cfgdata)
        self.hostid = hostid
        self.iqn = f'iqn.2024-04.com.hanrun.{hostid}.{cfg.name}'
        self.portals = [IscsitPortal(portal, self.iqn) for portal in cfg.portals]
        self.acls = [IscsitAcl(acl, self.iqn) for acl in cfg.acls]
        self.luns = [IscsitLun(lun, self.hostid, self.iqn) for lun in cfg.luns]

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


class IscsitNode:
    def __init__(self, cfg):
        cfg = ConfigItem(cfg)
        self.targets = [IscsitTarget(tgt, cfg.hostid) for tgt in cfg.targets]

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


def build(config):
    topology = IscsitNode(config)
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
