#!/usr/bin/env python

import yaml
import sys
import argparse
from tgtconfig import ConfigAgent, ConfigObject


class IscsitTopology(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.targets = []

    def build(self):
        hostid = self.cfgdt.hostid
        for cfg in self.cfgdt.targets:
            tgt = IscsitTarget(cfg)
            self.targets.append(tgt)
            tgt.build(hostid)

    def create(self, agent):
        for tgt in self.targets:
            tgt.create(agent)
        agent.execute('iscsit_saveconfig')

    def destroy(self, agent):
        for tgt in self.targets:
            tgt.destroy(agent)
        agent.execute('iscsit_clear')


class IscsitTarget(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.iqn = ''
        self.portals = []
        self.acls = []
        self.luns = []

    def build(self, hostid):
        self.iqn = f'iqn.2024-04.com.ebtech.{hostid}.{self.cfgdt.name}'

        for cfg in self.cfgdt.portals:
             portal = IscsitPortal(cfg, self.iqn)
             self.portals.append(portal)
             portal.build()

        for acl_str in self.cfgdt.acls:
            acl = IscsitAcl(acl_str, self.iqn)
            self.acls.append(acl)
            acl.build()

        for cfg in self.cfgdt.luns:
            lun = IscsitLun(cfg, hostid, self.iqn)
            self.luns.append(lun)
            lun.build()

    def create(self, agent):
        agent.execute('iscsit_iqn_create', self.iqn)

        for portal in self.portals:
            portal.create(agent)

        for acl in self.acls:
            acl.create(agent)

        for lun in self.luns:
            lun.create(agent)

    def destroy(self, agent):
        for portal in self.portals:
            portal.destroy(agent)

        for acl in self.acls:
            acl.destroy(agent)

        for lun in self.luns:
            lun.destroy(agent)

        agent.execute('iscsit_iqn_destroy', self.iqn)


class IscsitPortal(ConfigObject):
    def __init__(self, cfg, iqn):
        super().__init__(cfg)
        self.iqn = iqn

    def create(self, agent):
        agent.execute('iscsit_portal_create', self.iqn, self.cfgdt.addr, self.cfgdt.port)

    def destroy(self, agent):
        agent.execute('iscsit_portal_destroy', self.iqn, self.cfgdt.addr, self.cfgdt.port)


class IscsitAcl(ConfigObject):
    def __init__(self, acl, iqn):
        super().__init__(None)
        self.acl = acl
        self.iqn = iqn

    def create(self, agent):
        agent.execute('iscsit_acl_create', self.iqn, self.acl)


class IscsitLun(ConfigObject):
    def __init__(self, cfg, hostid, iqn):
        super().__init__(cfg)
        self.hostid = hostid
        self.iqn = iqn

    def create(self, agent):
        if len(self.cfgdt.lunid) > 16:
            print("legth of lunid is greater than 16")
            sys.exit(1)
        agent.execute('iscsit_lun_create', self.iqn,
                      f'{self.hostid}-{self.cfgdt.lunid}', self.cfgdt.lunpath)

def build(config):
    topology = IscsitTopology(config)
    topology.build()
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
