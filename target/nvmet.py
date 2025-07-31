#!/usr/bin/env python

import yaml
import argparse
from tgtconfig import ConfigAgent, ConfigData

class NvmetTopology:
    def __init__(self, cfg):
        cfgdt = ConfigData(cfg)
        hostid = cfgdt.hostid

        self.ports = [NvmetPort(cfg) for cfg in cfgdt.ports]
        self.targets = [NvmetTarget(cfg, hostid, self.ports)
                        for cfg in cfgdt.targets]

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


class NvmetTarget:
    def __init__(self, cfg, hostid, ports):
        cfgdt = ConfigData(cfg)

        self.ports = ports
        self.subsyses = [NvmetSubsys(cfgdt, hostid, subsysid)
                         for subsysid in cfgdt.subsysids]

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


class NvmetPort:
    def __init__(self, cfg):
        cfgdt = ConfigData(cfg)

        self.portid = cfgdt.portid
        self.traddr = cfgdt.traddr
        self.trsvcid = cfgdt.trsvcid
        self.transport = cfgdt.transport

    def create(self, agent):
        agent.execute('nvmet_port_create', self.portid, self.traddr,
                      self.trsvcid, self.transport)

    def destroy(self, agent):
        agent.execute('nvmet_port_destroy', self.portid, self.traddr,
                      self.trsvcid, self.transport)

    def add_subsys(self, agent, nqn):
        agent.execute('nvmet_port_add_subsys', self.portid, self.traddr,
                      self.trsvcid, self.transport, nqn)

    def del_subsys(self, agent, nqn):
        agent.execute('nvmet_port_del_subsys', self.portid, self.traddr,
                      self.trsvcid, self.transport, nqn)


class NvmetSubsys:
    def __init__(self, cfgdt, hostid: str, subsysid: str):
        self.offload = cfgdt.offload
        self.nqn = f"{hostid}-{subsysid}"
        self.namespaces = [NvmetNamespace(self.nqn, nsid) 
                           for nsid in cfgdt.nsids]

    def create(self, agent):
        agent.execute('nvmet_subsys_create', self.nqn, self.offload)
        for ns in self.namespaces:
            ns.create(agent)

    def destroy(self, agent):
        pass
        #agent.execute('nvmet_subsys_destroy', self.nqn)


class NvmetNamespace:
    def __init__(self, nqn, nsid):
        self.nqn = nqn
        self.nsid = nsid

    @property
    def devpath(self):
        return f"/dev/disk/nvme/{self.nqn}-n{self.nsid}"

    def create(self, agent):
        agent.execute('nvmet_namespace_create', self.nqn, self.nsid, self.devpath)


def build(config):
    topology = NvmetTopology(config)
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
