#!/usr/bin/env python

import argparse
import yaml
from tgtconfig import ConfigAgent, ConfigItem


class PcsHost:
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.authaddr = cfg.authaddr
        self.authuser = cfg.authuser
        self.authpasswd = cfg.authpasswd

    @property
    def name_addr(self):
        return f"{self.name} addr={self.authaddr}"

    def create(self, agent):
        agent.execute('pcs_host_auth', self.name, self.authaddr,
                      self.authuser, self.authpasswd)


class PcsStonith:
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.ipmiaddr = cfg.ipmiaddr
        self.ipmiuser = cfg.ipmiuser
        self.ipmipasswd = cfg.ipmipasswd
        self.isprimary = False

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
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.ra = cfg.ra
        self.params = [f'{k}={v}' for k, v in cfg.params.items()]

    def create(self, agent):
        agent.execute('pcs_resource_create', self.name, self.ra, *self.params)


class PcsGroup:
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.locations = cfg.locations
        self.predecessor = cfg.predecessor
        self.resources = cfg.resources

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
    def __init__(self, cfgdata):
        cfg = ConfigItem(cfgdata)
        self.name = cfg.name
        self.hosts = [PcsHost(host) for host in cfg.hosts] if cfg.hosts else []
        self.stoniths = [PcsStonith(stonith) for stonith in cfg.stoniths] if cfg.stoniths else []
        if len(self.stoniths) == 2:
            # for a two node topology, the first node is selected as the
            # primary one. the primary node can delay the other node when
            # doing stonith.
            self.stoniths[0].set_primary()
        self.resources = [PcsResource(res) for res in cfg.resources]
        self.groups = [PcsGroup(grp) for grp in cfg.groups]
        self.enable_stonith = cfg.stonith_enabled if cfg.stonith_enabled else True

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

        if not self.enable_stonith:
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
