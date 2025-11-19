#!/usr/bin/env python

import argparse
import yaml
from tgtconfig import ConfigAgent, ConfigItem

class NvmetPort:
    def __init__(self, cfg):
        self.setup(ConfigItem(cfg))

    def setup(self, cfg):
        self.portid = cfg.portid
        self.traddr = cfg.traddr
        self.trsvcid = cfg.trsvcid
        self.transport = cfg.transport

    def create(self, agent):
        agent.execute('nvmet_port_create', self.portid, self.traddr,
                      self.trsvcid, self.transport)

    def destroy(self, agent):
        agent.execute('nvmet_port_destroy', self.portid, self.traddr,
                      self.trsvcid, self.transport)

    def add_subsys(self, agent, nqn):
        agent.execute('nvmet_port_add_subsys', self.portid, nqn)

    def del_subsys(self, agent, nqn):
        agent.execute('nvmet_port_del_subsys', self.portid, nqn)


class NvmetNamespace:
    def __init__(self, nqn, nsid):
        self.nqn = nqn
        self.nsid = nsid

    @property
    def devpath(self):
        _, _, subsysid = self.nqn.partition('-')
        if not subsysid.startswith('nvmevol'):
            return f"/dev/disk/nvme/{self.nqn}-n{self.nsid}"
        if int(self.nsid) == 1:
            return f"/dev/md/{subsysid}"
        raise ValueError(f'invalid nsid: {self.nsid}')

    def create(self, agent):
        agent.execute('nvmet_namespace_create', self.nqn, self.nsid, self.devpath)


class NvmetSubsys:
    def __init__(self, tgt_cfg, hostid: str, subsysid: str):
        self.setup(tgt_cfg, hostid, subsysid)

    def setup(self, tgt_cfg, hostid, subsysid):
        self.nqn = f"{hostid}-{subsysid}"
        self.offload = tgt_cfg.offload
        self.namespaces = [NvmetNamespace(self.nqn, nsid) for nsid in tgt_cfg.nsids]

    def create(self, agent):
        agent.execute('nvmet_subsys_create', self.nqn, self.offload)
        for ns in self.namespaces:
            ns.create(agent)

    def destroy(self, agent):
        agent.execute('nvmet_subsys_destroy', self.nqn)


class NvmetTarget:
    def __init__(self, cfg, hostid, ports):
        self.setup(ConfigItem(cfg), hostid, ports)

    def setup(self, cfg, hostid, ports):
        self.hostid = hostid
        self.ports = ports
        self.subsyses = [NvmetSubsys(cfg, self.hostid, subsysid)
                         for subsysid in cfg.subsysids]

    def create(self, agent):
        for subsys in self.subsyses:
            subsys.create(agent)
            for port in self.ports:
                port.add_subsys(agent, subsys.nqn)

    def destroy(self, agent):
        for subsys in self.subsyses:
            for port in self.ports:
                port.del_subsys(agent, subsys.nqn)
            subsys.destroy(agent)


class NvmetNode:
    def __init__(self, cfg):
        self.setup(ConfigItem(cfg))

    def setup(self, cfg):
        self.hostid = cfg.hostid
        self.ports = [NvmetPort(port) for port in cfg.ports]
        self.targets = [NvmetTarget(tgt, self.hostid, self.ports)
                        for tgt in cfg.targets]

    def create(self, agent):
        for port in self.ports:
            port.create(agent)
        for tgt in self.targets:
            tgt.create(agent)

    def destroy(self, agent):
        for tgt in self.targets[::-1]:
            tgt.destroy(agent)
        for port in self.ports:
            port.destroy(agent)


def build(config):
    topology = NvmetNode(config)
    agents = ConfigAgent.from_config(config['agents'])
    return agents, topology


def create(agents, topology):
    for agent in agents:
        topology.create(agent)
        agent.execute('nvmet_saveconfig')


def destroy(agents, topology):
    for agent in agents[::-1]:
        topology.destroy(agent)


def main():
    # Set up argument parser to get the config file
    parser = argparse.ArgumentParser(description="nvme target configuration script")
    parser.add_argument('-c', '--config', type=str, required=True,
                        help="Path to the config file")
    parser.add_argument(dest='operation', choices=['create', 'destroy'],
                        help="create/destroy nvmet deployment")
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
