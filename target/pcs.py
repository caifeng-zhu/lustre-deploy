#!/usr/bin/env python

import subprocess
import sys
import os
import yaml
import argparse
from typing import List, Dict
from tgtconfig import ConfigAgent


class PcsHost:
    def __init__(self, cfg):
        self.cfg = cfg

    @property
    def name(self):
        return self.cfg['name']

    @property
    def authaddr(self):
        return self.cfg['authaddr']

    @property
    def authuser(self):
        return self.cfg['authuser']

    @property
    def authpasswd(self):
        return self.cfg['authpasswd']

    @property
    def name_addr(self):
        return f"{self.name} addr={self.authaddr}"

    def create(self, agent):
        agent.execute('pcs_host_auth', self.name, self.authaddr,
                      self.authuser, self.authpasswd)


class PcsStonith:
    def __init__(self, cfg):
        self.cfg = cfg
        self.isprimary = False

    @property
    def name(self):
        return self.cfg['name']

    @property
    def ipmiaddr(self):
        return self.cfg['ipmiaddr']

    @property
    def ipmiuser(self):
        return self.cfg['ipmiuser']

    @property
    def ipmipasswd(self):
        return self.cfg['ipmipasswd']

    def set_primary(self):
        self.isprimary = True

    def create(self, agent):
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


class PcsResource:
    def __init__(self, cfg):
        self.cfg = cfg

    @property
    def name(self):
        return self.cfg['name']

    @property
    def ra(self):
        return self.cfg['ra']

    @property
    def params(self):
        return [f'{k}={v}' for k, v in self.cfg['params'].items()]

    def create(self, agent):
        agent.execute('pcs_resource_create', self.name, self.ra, *self.params)


class PcsGroup:
    def __init__(self, cfg):
        self.cfg = cfg

    @property
    def name(self):
        return self.cfg['name']

    @property
    def locations(self):
        if 'locations' not in self.cfg:
            return None
        return self.cfg['locations']

    @property
    def predecessor(self):
        if 'predecessor' not in self.cfg:
            return None
        return self.cfg['predecessor']

    @property
    def resources(self):
        return self.cfg['resources']

    def create(self, agent):
        if self.locations:
            agent.execute('pcs_resgroup_create', self.name,
                          f"{self.locations[0]}=200",
                          f"{self.locations[1]}=100",
                          *self.resources)
        if self.predecessor:
            agent.execute('pcs_resgroup_create_ordered', self.name,
                          self.predecessor, *self.resources)


class PcsCluster:
    def __init__(self, cfg):
        self.cfg = cfg
        self._hosts = None
        self._stoniths = None
        self._resources = None
        self._groups = None

    @property
    def name(self):
        return self.cfg['name']

    @property
    def stonith_enabled(self):
        if 'stonith_enabled' not in self.cfg:
            return True     # default is enabled
        return self.cfg['stonith_enabled']

    @property
    def stoniths(self):
        if self._stoniths is None:
            self._stoniths = [PcsStonith(stonith) for stonith in self.cfg['stoniths']] \
                    if 'stoniths' in self.cfg else []
            if len(self._stoniths) == 2:
                # for a two node topology, the first node is selected as the
                # primary one. the primary node can delay the other node when
                # doing stonith.
                self._stoniths[0].set_primary()
        return self._stoniths

    @property
    def hosts(self):
        if self._hosts is None:
            self._hosts = [PcsHost(host) for host in self.cfg['hosts']] \
                    if 'hosts' in self.cfg else []
        return self._hosts

    @property
    def resources(self):
        if self._resources is None:
            self._resources = [PcsResource(res) for res in self.cfg['resources']]
        return self._resources

    @property
    def groups(self):
        if self._groups is None:
            self._groups = [PcsGroup(grp) for grp in self.cfg['groups']]
        return self._groups

    def create(self, agent):
        for host in self.hosts:
            host.create(agent)

        if self.hosts:
            name_addrs = ' '.join(h.name_addr for h in self.hosts).strip()
            agent.execute('pcs_cluster_setup', self.name, name_addrs)
            if len(self.hosts) == 2:
                agent.execute('pcs_property_set', 'no-quorum-policy=ignore')

        for res in self.resources:
            res.create(agent)

        for grp in self.groups:
            grp.create(agent)

        if not self.stonith_enabled:
            agent.execute('pcs_property_set', 'stonith-enabled=false')
            return
        for stonith in self.stoniths:
            stonith.create(agent)

    def destroy(self, agent):
        agent.execute('pcs_cluster_destroy')


def build(config):
    cluster = PcsCluster(config)
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
