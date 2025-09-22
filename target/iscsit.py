#!/usr/bin/env python

import yaml
import sys
import argparse
from tgtconfig import ConfigAgent


class IscsitPortal:
    def __init__(self, cfg, iqn):
        self.cfg = cfg
        self.iqn = iqn

    @property
    def addr(self):
        return self.cfg['addr']

    @property
    def port(self):
        return self.cfg['port']

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
        self.cfg = cfg
        self.iqn = iqn
        self.hostid = hostid

    @property
    def lunid(self):
        return self.cfg['lunid']

    @property
    def devid(self):
        return self.cfg['devid']

    @property
    def devpath(self):
        return self.cfg['devpath']

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
    def __init__(self, cfg, hostid):
        self.cfg = cfg
        self.hostid = hostid
        self._portals = None
        self._acls = None
        self._luns = None

    @property
    def iqn(self):
        name = self.cfg['name']
        return f'iqn.2024-04.com.ebtech.{self.hostid}.{name}'

    @property
    def portals(self):
        if not self._portals:
            self._portals = [IscsitPortal(portal, self.iqn) for portal in self.cfg['portals']]
        return self._portals

    @property
    def acls(self):
        if not self._acls:
            self._acls = [IscsitAcl(acl, self.iqn) for acl in self.cfg['acls']]
        return self._acls

    @property
    def luns(self):
        if not self._luns:
            self._luns = [IscsitLun(lun, self.hostid, self.iqn) for lun in self.cfg['luns']]
        return self._luns

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


class IscsitTopology:
    def __init__(self, cfg):
        self.cfg = cfg
        self._targets = None

    @property
    def targets(self):
        if not self._targets:
            hostid = self.cfg['hostid']
            self._targets = [IscsitTarget(tgt, hostid) for tgt in self.cfg['targets']]
        return self._targets

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
