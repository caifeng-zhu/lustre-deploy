#!/usr/bin/env python

import yaml
import argparse
from tgtconfig import ConfigAgent

class NvmetPort:
    def __init__(self, cfg):
        self.cfg = cfg

    @property
    def portid(self):
        return self.cfg['portid']

    @property
    def traddr(self):
        return self.cfg['traddr']

    @property
    def trsvcid(self):
        return self.cfg['trsvcid']

    @property
    def transport(self):
        return self.cfg['transport']

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
    def __init__(self, cfg, hostid: str, subsysid: str):
        self.cfg = cfg
        self.nqn = f"{hostid}-{subsysid}"
        self._namespaces = None

    @property
    def offload(self):
        return self.cfg['offload']

    @property
    def namespaces(self):
        if self._namespaces:
            return self._namespaces
        self._namespaces = [NvmetNamespace(self.nqn, nsid)
                            for nsid in self.cfg['nsids']]
        return self._namespaces

    def create(self, agent):
        agent.execute('nvmet_subsys_create', self.nqn, self.offload)
        for ns in self.namespaces:
            ns.create(agent)

    def destroy(self, agent):
        pass
        #agent.execute('nvmet_subsys_destroy', self.nqn)


class NvmetTarget:
    def __init__(self, cfg, hostid, ports):
        self.cfg = cfg
        self.hostid = hostid
        self.ports = ports
        self._subsystes = None

    @property
    def subsyses(self):
        if self._subsystes:
            return self._subsystes
        self._subsystes = [NvmetSubsys(self.cfg, self.hostid, subsysid)
                           for subsysid in self.cfg['subsysids']]
        return self._subsystes

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


class NvmetTopology:
    def __init__(self, cfg):
        self.cfg = cfg
        self._targets = None
        self._ports = None

    @property
    def hostid(self):
        return self.cfg['hostid']

    @property
    def ports(self):
        if self._ports:
            return self._ports
        self._ports = [NvmetPort(port) for port in self.cfg['ports']]
        return self._ports

    @property
    def targets(self):
        if self._targets:
            return self._targets
        self._targets = [NvmetTarget(tgt, self.hostid, self.ports)
                         for tgt in self.cfg['targets']]
        return self._targets

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
