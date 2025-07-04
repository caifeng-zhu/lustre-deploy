#!/usr/bin/env python

import yaml
import argparse
from tgtconfig import ConfigAgent, ConfigObject

class NvmetTopology(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.ports = []
        self.targets = []

    def build(self):
        for cfg in self.cfgdt.ports:
            port = NvmetPort(cfg)
            self.ports.append(port)
            port.build()

        for cfg in self.cfgdt.targets:
            tgt = NvmetTarget(cfg)
            self.targets.append(tgt)
            tgt.build(self.cfgdt.hostid, self.ports)

    def create(self, agent):
        for port in self.ports:
            port.create(agent)
        for tgt in self.targets:
            tgt.create(agent)

    def destroy(self, agent):
        self.targets.reverse()
        for tgt in self.targets:
            tgt.destroy(agent)
        for port in self.ports:
            port.destroy(agent)


class NvmetTarget(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.ports = []
        self.subsyses = []

    def build(self, hostid, allports):
        for i in self.cfgdt.portids:
            self.ports.append(allports[i])
        for subsysid in self.cfgdt.subsysids:
            subsys = NvmetSubsys(self.cfgdt.cfg, hostid, subsysid)
            self.subsyses.append(subsys)
            subsys.build()

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
        agent.execute('nvmet_clear')


class NvmetPort(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)

    def create(self, agent):
        agent.execute('nvmet_port_create', self.cfgdt.portid,
                      self.cfgdt.traddr, self.cfgdt.trsvcid,
                      self.cfgdt.transport)

    def destroy(self, agent):
        agent.execute('nvmet_port_destroy', self.cfgdt.portid,
                      self.cfgdt.traddr, self.cfgdt.trsvcid,
                      self.cfgdt.transport)

    def add_subsys(self, agent, nqn):
        agent.execute('nvmet_port_add_subsys', self.cfgdt.portid,
                      self.cfgdt.traddr, self.cfgdt.trsvcid,
                      self.cfgdt.transport, nqn)

    def del_subsys(self, agent, nqn):
        agent.execute('nvmet_port_del_subsys', self.cfgdt.portid,
                      self.cfgdt.traddr, self.cfgdt.trsvcid,
                      self.cfgdt.transport, nqn)


class NvmetSubsys(ConfigObject):
    def __init__(self, cfg, hostid: str, subsysid: str):
        super().__init__(cfg)
        self.nqn = f"{hostid}-{subsysid}"
        self.namespaces = []

    def build(self):
        for nsid in self.cfgdt.nsids:
            ns = NvmetNamespace(self.nqn, nsid)
            ns.build()
            self.namespaces.append(ns)

    def create(self, agent):
        agent.execute('nvmet_subsys_create', self.nqn, self.cfgdt.offload)
        for ns in self.namespaces:
            ns.create(agent)

    def destroy(self, agent):
        agent.execute('nvmet_subsys_destroy', self.nqn)


class NvmetNamespace(ConfigObject):
    def __init__(self, nqn, nsid):
        super().__init__(None)
        self.nqn = nqn
        self.nsid = nsid

    def create(self, agent):
        devpath = f"/dev/disk/nvme/{self.nqn}-n{self.nsid}"
        agent.execute('nvmet_namespace_create', self.nqn, self.nsid, devpath)


def build(config):
    topology = NvmetTopology(config)
    topology.build()
    agents = ConfigAgent.from_config(config['agents'])
    return agents, topology


def create(agents, topology):
    for agent in agents:
        topology.create(agent)
        agent.execute('nvmet_saveconfig')


def destroy(agents, topology):
    agents.reverse()
    for agent in agents:
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
