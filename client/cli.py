#!/usr/bin/env python

import sys
import argparse
import yaml
import os
import subprocess

debug = False

def run(cmd):
    global debug

    if debug:
        print(f"=> debug {cmd}", flush=True)
        return

    print(f"=> {cmd}", flush=True)
    try:
        result = subprocess.run(cmd, shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {cmd}\nExit code: {e.returncode}")
        sys.exit(e.returncode)
    if result.returncode != 0:
        print(f"Command failed: {cmd}\nExit code: {result.returncode}")
        sys.exit(result.returncode)

    print("", flush=True)


class ClientDispacher:
    def __init__(self, addrs, workdir, agent):
        self.hosts = addrs
        self.workdir = workdir
        self.agent = agent

    def workfile(self, origfile):
        return f'{self.workdir}/' + os.path.basename(origfile)

    def start(self):
        run(f'clush -qS -w {self.hosts} -b mkdir -p {self.workdir}')
        self.copy(self.agent)

    def check_host(self, machine):
        self.execute('host_check', machine)

    def execute(self, opname, *args):
        #opargs = ' '.join(f"'{arg}'" for arg in args)
        opargs = ' '.join(args)
        agent = self.workfile(self.agent)
        run(f'clush -qS -w {self.hosts} -b {agent} {opname} {opargs}')

    def copy(self, *files):
        copyfiles = ' '.join(files)
        run(f'clush -qS -w {self.hosts} --copy {copyfiles} --dest {self.workdir}')
        return [ self.workfile(file) for file in files ]


def dispacher_create(clicfg, hostaddrs):
    dispacher = ClientDispacher(hostaddrs, clicfg['workdir'], clicfg['agent'])
    dispacher.start()
    if 'machine' in clicfg:
        dispacher.check_host(clicfg['machine'])
    return dispacher


class ClientItem:
    def __init__(self, cfg):
        self.cfg = cfg

    def install(self, dispacher):
        pass

    def uninstall(self, dispacher):
        pass

    def start(self, dispacher):
        pass

    def stop(self, dispacher):
        pass

    def check(self, dispacher):
        pass

    def dump(self, dispacher):
        pass


class ClientPkgs(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def pkgs(self):
        return self.cfg

    def install(self, dispacher):
        def copy(pkg):
            if pkg.endswith('.deb'):
                return dispacher.copy(pkg)[0]
            return pkg
        dispacher.execute('apt_install', *map(copy, self.pkgs))

    def uninstall(self, dispacher):
        def getname(pkg):
            if pkg.endswith('.deb'):
                return os.path.basename(pkg).partition('_')[0]
            return pkg
        dispacher.execute('apt_uninstall', *map(getname, self.pkgs))


class ClientSubsys(ClientItem):
    def __init__(self, cfg, parse_items, dumpcmd=''):
        super().__init__(cfg)
        self.parse_items = parse_items
        self._items = None
        self.dumpcmd = dumpcmd

    @property
    def items(self):
        if self._items is None:
            self._items = self.parse_items(self.cfg)
        return self._items

    def install(self, dispacher):
        for item in self.items:
            item.install(dispacher)

    def uninstall(self, dispacher):
        for item in self.items[::-1]:
            item.uninstall(dispacher)

    def start(self, dispacher):
        for item in self.items:
            item.start(dispacher)
        for item in self.items:
            item.check(dispacher)

    def stop(self, dispacher):
        for item in self.items[::-1]:
            item.stop(dispacher)

    def dump(self, dispacher):
        for item in self.items:
            item.dump(dispacher)
        if self.dumpcmd:
            dispacher.execute(self.dumpcmd)


class LfsNetWorks(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def networks(self):
        return [f"{net['net']} {net['nics']}" for net in self.cfg]

    def install(self, dispacher):
        dispacher.execute('lfs_add_networks', *self.networks)

    def uninstall(self, dispacher):
        dispacher.execute('lfs_del_networks', *self.networks)

    def check(self, dispacher):
        dispacher.execute('lfs_chk_networks', *self.networks)

    def dump(self, dispacher):
        dispacher.execute('lfs_dump_networks')


class LfsRoutes(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def routes(self):
        return [f"{route['net']} {route['nid']}" for route in self.cfg]

    def install(self, dispacher):
        dispacher.execute('lfs_add_routes', *self.routes)

    def uninstall(self, dispacher):
        #dispacher.execute('lfs_del_routes')
        pass

    def check(self, dispacher):
        dispacher.execute(f'lfs_chk_routes', *self.routes)

    def dump(self, dispacher):
        dispacher.execute('lfs_dump_routes')


class LfsMount(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def srcpath(self):
        return self.cfg['srcpath']

    @property
    def dstpath(self):
        return self.cfg['dstpath']

    @property
    def options(self):
        return self.cfg['options']

    def install(self, dispacher):
        dispacher.execute('lfs_add_mount', self.srcpath, self.dstpath, self.options)

    def uninstall(self, dispacher):
        dispacher.execute('lfs_del_mount', self.dstpath)

    def start(self, dispacher):
        dispacher.execute('lfs_start_mount', self.srcpath, self.dstpath)

    def stop(self, dispacher):
        dispacher.execute('lfs_stop_mount', self.srcpath, self.dstpath)

    def dump(self, dispacher):
        # TODO
        #dispacher.execute('lfs_dump_mount', self.srcpath, self.dstpath, self.options)
        pass


class LvmNvmets(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def nvmets(self):
        return [f"{nvmet['traddr']} {nvmet['host-traddr']} {nvmet['transport']} {nvmet['trsvcid']}" for nvmet in self.cfg]

    def install(self, dispacher):
        dispacher.execute("lvm_add_nvmets", *self.nvmets)

    def uninstall(self, dispacher):
        dispacher.execute("lvm_del_nvmets")

    def start(self, dispacher):
        dispacher.execute("lvm_start_nvmets")

    def stop(self, dispacher):
        dispacher.execute("lvm_stop_nvmets")

    def dump(self, dispacher):
        dispacher.execute('lvm_dump_nvmets')


class LvmIscsits(ClientItem):
    pass


class LvmVg(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def vg(self):
        return self.cfg

    def install(self, dispacher):
        dispacher.execute('lvm_add_vg', self.vg)

    def uninstall(self, dispacher):
        dispacher.execute('lvm_del_vg', self.vg)

    def start(self, dispacher):
        dispacher.execute('lvm_start_vg', self.vg)

    def stop(self, dispacher):
        dispacher.execute('lvm_stop_vg', self.vg)


def parse_items_lfs_mounts(cfg):
    return [LfsMount(mnt) for mnt in cfg]


def parse_items_lfs(cfg):
    items = []
    items.append(ClientPkgs(cfg['pkgs']))
    items.append(LfsNetWorks(cfg['networks']))
    if 'routes' in cfg:
        items.append(LfsRoutes(cfg['routes']))
    items.append(ClientSubsys(cfg['mounts'], \
            parse_items_lfs_mounts, 'lfs_dump_mounts'))
    return items


def parse_items_lvm_vgs(cfg):
    return [LvmVg(vg) for vg in cfg]


def parse_items_lvm(cfg):
    items = []
    items.append(ClientPkgs(cfg['pkgs']))
    items.append(LvmNvmets(cfg['nvmets']))
    items.append(ClientSubsys(cfg['vgs'],   \
                              parse_items_lvm_vgs, 'lvm_dump_vgs'))
    return items


def parse_items_host(cfg):
    items = []
    if 'lfs' in cfg:
        items.append(ClientSubsys(cfg['lfs'], parse_items_lfs))
    if 'lvm' in cfg:
        items.append(ClientSubsys(cfg['lvm'], parse_items_lvm))
    return items


def build(cfg, args):
    dispacher = dispacher_create(cfg['client'], args.nodes)
    cli = ClientSubsys(cfg, parse_items_host)
    return dispacher, cli


def main(argv):
    ap = argparse.ArgumentParser('deploy client hosts')
    ap.add_argument('-f', '--file', required=True, action='store')
    ap.add_argument('-n', '--nodes', required=True, action='store')
    ap.add_argument('--debug', required=False, action='store_true')
    ap.add_argument(dest='operation', choices=['install', 'start', 'stop', 'uninstall', 'dump'],
                    help="client deployment operation")
    args = ap.parse_args(args=argv)
    if args.debug:
        debug = True

    with open(args.file, 'r') as f:
        config = yaml.safe_load(f)
    dispatcher, cli = build(config, args)

    if args.operation == 'install':     cli.install(dispatcher)
    if args.operation == 'start':       cli.start(dispatcher)
    if args.operation == 'stop':        cli.stop(dispatcher)
    if args.operation == 'uninstall':   cli.uninstall(dispatcher)
    if args.operation == 'dump':        cli.dump(dispatcher)


if __name__ == '__main__':
    main(sys.argv[1:])
