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


class ClientItemSet(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)
        self._items = None

    def getitems(self):
        return []

    @property
    def items(self):
        if self._items is None:
            self._items = self.getitems()
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


class LfsNetwork(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def net(self):
        return self.cfg['net']

    @property
    def nics(self):
        return self.cfg['nics']


class LfsNetWorks(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        return [LfsNetwork(cfg) for cfg in self.cfg]

    @property
    def networks(self):
        return [f"{lnet.net} {lnet.nics}" for lnet in self.items]

    def install(self, dispacher):
        dispacher.execute('lfs_add_networks', *self.networks)

    def uninstall(self, dispacher):
        dispacher.execute('lfs_del_networks', *self.networks)

    def check(self, dispacher):
        dispacher.execute('lfs_chk_networks', *self.networks)

    def dump(self, dispacher):
        dispacher.execute('lfs_dump_networks')


class LfsRoute(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def net(self):
        return self.cfg['net']

    @property
    def nid(self):
        return self.cfg['nid']


class LfsRoutes(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitem(self):
        return [LfsRoute(cfg) for cfg in self.cfg[

    @property
    def routes(self):
        return [f"{route.net} {route.nid}" for route in self.items]

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

class LfsMounts(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        return [LfsMount(mnt) for mnt in self.cfg]

    def dump(self, dispacher):
        dispacher.execute('lfs_dump_mount')


class LfsConfig(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        items = []
        items.append(ClientPkgs(self.cfg['pkgs']))
        items.append(LfsNetWorks(self.cfg['networks']))
        if 'routes' in self.cfg:
            items.append(LfsRoutes(self.cfg['routes']))
        items.append(LfsMounts(self.cfg['mounts']))
        return items


class LvmNvmet(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def traddr(self):
        return self.cfg['traddr']

    @property
    def host_traddr(self):
        return self.cfg['host_traddr']

    @property
    def transport(self):
        return self.cfg['transport']

    @property
    def trsvcid(self):
        return self.cfg['trsvcid']


class LvmNvmets(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        return [LvmNvmet(cfg) for cfg in self.cfg]

    @property
    def nvmets(self):
        return [f"{nvmet.traddr} {nvmet.host_traddr} {nvmet.transport} {nvmet.trsvcid}"
                for nvmet in self.items]

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


class LvmIscsit(ClientItem):
    def __init__(self, cfg):
        super().__init__(cfg)

    @property
    def iqn(self):
        return self.cfg['iqn']

    @property
    def addr(self):
        return self.cfg['addr']

    @property
    def port(self):
        return self.cfg['port']

    def install(self, dispacher):
        dispacher.execute("lvm_add_iscsit", self.iqn, self.addr, self.port)

    def uninstall(self, dispacher):
        dispacher.execute("lvm_del_iscsit", self.iqn, self.addr, self.port)

    def start(self, dispacher):
        dispacher.execute("lvm_start_iscsit", self.iqn, self.addr, self.port)

    def stop(self, dispacher):
        dispacher.execute("lvm_stop_iscsit", self.iqn, self.addr, self.port)


class LvmIscsits(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        return [LvmIscsit(cfg) for cfg in self.cfg]

    def dump(self, dispacher):
        dispacher.execute("lvm_dump_iscsits")


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


class LvmVgs(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        return [LvmVg(vg) for vg in self.cfg]

    def dump(self, dispacher):
        dispacher.execute('lvm_dump_vgs')


class LvmConfig(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        items = []
        items.append(ClientPkgs(self.cfg['pkgs']))
        if 'nvmets' in self.cfg:
            items.append(LvmNvmets(self.cfg['nvmets']))
        if 'iscsits' in self.cfg:
            items.append(LvmIscsits(self.cfg['iscsits']))
        items.append(LvmVgs(self.cfg['vgs']))
        return items


class ClientConfig(ClientItemSet):
    def __init__(self, cfg):
        super().__init__(cfg)

    def getitems(self):
        items = []
        if 'lfs' in self.cfg:
            items.append(LfsConfig(self.cfg['lfs']))
        if 'lvm' in self.cfg:
            items.append(LvmConfig(self.cfg['lvm']))
        return items


def build(cfg, args):
    dispacher = dispacher_create(cfg['client'], args.nodes)
    cli = ClientConfig(cfg)
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
