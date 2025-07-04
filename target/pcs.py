#!/usr/bin/env python

import subprocess
import sys
import os
import yaml
import argparse
from typing import List, Dict
from tgtconfig import ConfigAgent, ConfigObject


class PcsHost(ConfigObject):
    def __init__(self, cfg, ipmiuser, ipmipasswd):
        super().__init__(cfg)
        self.user = ipmiuser
        self.passwd = ipmipasswd

    def create(self, agent):
        agent.execute('pcs_host_auth', self.cfgdt.name, self.cfgdt.authaddr,
                      self.user, self.passwd)

    def name_addr(self):
        return f"{self.cfgdt.name} addr={self.cfgdt.authaddr}"


class PcsStonith(ConfigObject):
    def __init__(self, cfg, ipmiuser, ipmipasswd):
        super().__init__(cfg)
        self.user = ipmiuser
        self.passwd = ipmipasswd
        self.isprimary = False

    def create(self, agent):
        if self.isprimary:
            # it is the primary node and the backup one
            # is told to delay when carrying on stonith.
            delay = 'pcmk_delay_base=2 pcmk_delay_max=3'
        else:
            delay = ''
        agent.execute('pcs_stonith_create',
                      f"ipmi-{self.cfgdt.name}",
                      "fence_ipmilan lanplus=true",
                      f"ip={self.cfgdt.ipmiaddr}",
                      f"username='{self.user}'",
                      f"password='{self.passwd}'",
                      "privlvl=operator",
                      f'pcmk_host_list={self.cfgdt.name}',
                      delay)

    def set_primary(self):
        self.isprimary = True


class PcsGroupType(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getparams(self):
        return [f'{k}={v}' for k, v in self.cfgdt.params.items()]


class PcsTarget(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.grptype = None

    def build(self, grptypes):
        self.grptype = grptypes[self.cfgdt.grptype]

    def create(self, agent):
        cmd = 'pcs_resgroup_create' + f'_{self.cfgdt.grptype}'
        agent.execute(cmd, self.cfgdt.name,
                      f"{self.cfgdt.locations[0]}=200",
                      f"{self.cfgdt.locations[1]}=100",
                      *self.grptype.getparams())


class PcsCluster(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.hosts = []
        self.stoniths = []
        self.targets = []

    def build(self, targets):
        for hc in self.cfgdt.hosts:
            host = PcsHost(hc, self.cfgdt.authuser, self.cfgdt.authpasswd)
            self.hosts.append(host)

        for hc in self.cfgdt.hosts:
            stonith = PcsStonith(hc, self.cfgdt.ipmiuser, self.cfgdt.ipmipasswd)
            self.stoniths.append(stonith)
        if len(self.stoniths) == 2:
            # for a two node topology, the first node is selected as the
            # primary one. the primary node can delay the other node when
            # doing stonith.
            self.stoniths[0].set_primary()

        self.targets.extend(targets)

    def create(self, agent):
        for host in self.hosts:
            host.create(agent)

        host_nameaddrs = ' '.join(h.name_addr() for h in self.hosts).strip()
        agent.execute('pcs_cluster_setup', self.cfgdt.name, host_nameaddrs)
        if len(self.hosts) == 2:
            agent.execute('pcs_property_set', 'no-quorum-policy=ignore')

        for tgt in self.targets:
            tgt.create(agent)

        for stonith in self.stoniths:
            stonith.create(agent)

    def destroy(self, agent):
        agent.execute('pcs_cluster_destroy')


def build(config):
    cluster = PcsCluster(config['cluster'])

    grptype_map = {}
    for cfg in config['grouptypes']:
        res = PcsGroupType(cfg)
        grptype_map[cfg['name']] = res

    targets = []
    for cfg in config['targets']:
        tgt = PcsTarget(cfg)
        tgt.build(grptype_map)
        targets.append(tgt)

    cluster.build(targets)
    return ConfigAgent.from_config(config['agents']), cluster


def create(agents, cluster):
    for agent in agents:
        cluster.create(agent)


def destroy(agents, cluster):
    for agent in agents:
        cluster.destroy(agent)


def main():
    parser = argparse.ArgumentParser(description="iscsi target configuration script")
    parser.add_argument('-c', '--config', type=str, required=True, help="Path to the config file")
    parser.add_argument(dest='operation', choices=['create', 'destroy'],
                        help="create/destroy nvmet deployment")
    args = parser.parse_args()
    config_file = args.config

    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
        agents, cluster = build(config)
        if args.operation == 'create':
            create(agents, cluster)
        if args.operation == 'destroy':
            destroy(agents, cluster)


if __name__ == "__main__":
    main()
