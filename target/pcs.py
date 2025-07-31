#!/usr/bin/env python

import subprocess
import sys
import os
import yaml
import argparse
from typing import List, Dict
from tgtconfig import ConfigAgent, ConfigData


class PcsHost:
    def __init__(self, cfg):
        cfgdt = ConfigData(cfg)

        self.name = cfgdt.name
        self.authaddr = cfgdt.authaddr
        self.authuser = cfgdt.authuser
        self.authpasswd = cfgdt.authpasswd
        self.ipmiaddr = cfgdt.ipmiaddr
        self.ipmiuser = cfgdt.ipmiuser
        self.ipmipasswd = cfgdt.ipmipasswd
        self.isprimary = False

    def create_auth(self, agent):
        agent.execute('pcs_host_auth', self.name, self.authaddr,
                      self.authuser, self.authpasswd)

    @property
    def name_addr(self):
        return f"{self.name} addr={self.authaddr}"


    def create_stonith(self, agent):
        if self.isprimary:
            # it is the primary node and the backup one
            # is told to delay when carrying on stonith.
            delay = 'pcmk_delay_base=2 pcmk_delay_max=3'
        else:
            delay = ''
        agent.execute('pcs_stonith_create',
                      f"ipmi-{self.name}",
                      "fence_ipmilan lanplus=true",
                      f"ip={self.ipmiaddr}",
                      f"username='{self.ipmiuser}'",
                      f"password='{self.ipmipasswd}'",
                      "privlvl=operator",
                      f'pcmk_host_list={self.name}',
                      delay)

    def set_primary(self):
        self.isprimary = True


class PcsGroupType:
    def __init__(self, cfg):
        cfgdt = ConfigData(cfg)
        self.name = cfgdt.name
        self.params = [f'{k}={v}' for k, v in cfgdt.params.items()]


class PcsTarget:
    def __init__(self, cfg, grptypes):
        cfgdt = ConfigData(cfg)

        self.name = cfgdt.name
        self.grptype = grptypes[cfgdt.grptype]
        self.locations = cfgdt.locations

    def create(self, agent):
        cmd = f'pcs_resgroup_create_{self.grptype.name}'
        agent.execute(cmd, self.name,
                      f"{self.locations[0]}=200",
                      f"{self.locations[1]}=100",
                      *self.grptype.params)


class PcsCluster:
    def __init__(self, cfg, targets):
        cfgdt = ConfigData(cfg)

        self.name = cfgdt.name
        self.targets = targets
        self.hosts = [PcsHost(cfg) for cfg in cfgdt.hosts]
        if len(self.hosts) == 2:
            # for a two node topology, the first node is selected as the
            # primary one. the primary node can delay the other node when
            # doing stonith.
            self.hosts[0].set_primary()

    def create(self, agent):
        for host in self.hosts:
            host.create_auth(agent)

        name_addrs = ' '.join(h.name_addr for h in self.hosts).strip()
        agent.execute('pcs_cluster_setup', self.name, name_addrs)
        if len(self.hosts) == 2:
            agent.execute('pcs_property_set', 'no-quorum-policy=ignore')

        for tgt in self.targets:
            tgt.create(agent)

        for host in self.hosts:
            host.create_stonith(agent)

    def destroy(self, agent):
        agent.execute('pcs_cluster_destroy')


def build(config):
    grptypes = {
        cfg['name'] : PcsGroupType(cfg)
        for cfg in config['grouptypes']
    }
    targets = [
        PcsTarget(cfg, grptypes)
        for cfg in config['targets']
    ]
    cluster = PcsCluster(config['cluster'], targets)
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
