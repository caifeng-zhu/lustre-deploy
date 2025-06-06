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


class Service:
    def __init__(self, name, dispacher):
        self.name = name
        self.dispacher = dispacher
        self.local_pkgs = []
        self.local_etcs = []
        self.startcmds = []
        self.stopcmds = []

    def parse_config(self, config):
        if 'pkgs' in config:
            self.local_pkgs = config['pkgs']
        if 'etcs' in config:
            self.local_etcs = config['etcs']
        if 'startcmds' in config:
            self.startcmds = config['startcmds']
        if 'stopcmds' in config:
            self.stopcmds = config['stopcmds']

    def install_pkgs(self):
        if self.local_pkgs[0].endswith('.deb'):
            remote_pkgs = self.dispacher.copy(*self.local_pkgs)
        else:
            remote_pkgs = self.local_pkgs
        self.dispacher.execute('apt_install', *remote_pkgs)

    def uninstall_pkgs(self):
        if self.local_pkgs[0].endswith('.deb'):
            remote_pkgs = [os.path.basename(pkg).partition('_')[0]
                           for pkg in self.local_pkgs]
        else:
            remote_pkgs = self.local_pkgs
        remote_pkgs.reverse()
        self.dispacher.execute('apt_remove', *remote_pkgs)

    def install_etcs(self):
        remote_etcs = self.dispacher.copy(*self.local_etcs)
        self.dispacher.execute(f'etc_install', *remote_etcs)

    def uninstall_etcs(self):
        remote_etcs = self.dispacher.copy(*self.local_etcs)
        remote_etcs.reverse()
        self.dispacher.execute(f'etc_uninstall', *remote_etcs)

    def start(self):
        for cmd in self.startcmds:
            self.dispacher.execute('cmd_run', cmd)

    def stop(self):
        for cmd in self.stopcmds:
            self.dispacher.execute('cmd_run', cmd)

    def install(self):
        if self.local_pkgs:
            self.install_pkgs()
        if self.local_etcs:
            self.install_etcs()
        if self.startcmds:
            self.start()

    def uninstall(self):
        if self.stopcmds:
            self.stop()
        if self.local_etcs:
            self.uninstall_etcs()
        # reduce extra operations
        #if self.local_pkgs:
        #    self.uninstall_pkgs()


def main(argv):
    global debug

    ap = argparse.ArgumentParser('deploy client hosts')
    ap.add_argument('-f', '--file', required=True, action='store')
    ap.add_argument('-n', '--nodes', required=True, action='store')
    ap.add_argument('-u', '--uninstall', required=False, action='store_true')
    ap.add_argument('--debug', required=False, action='store_true')
    args = ap.parse_args(args=argv)

    if args.debug:
        debug = True

    services = []
    with open(args.file, 'r') as f:
        config = yaml.safe_load(f)
        dispacher = dispacher_create(config['client'], args.nodes)
        for svccfg in config['services']:
            svc = Service(svccfg['name'], dispacher)
            svc.parse_config(svccfg)
            services.append(svc)

    if args.uninstall:
        for svc in services:
            svc.uninstall()
    else:
        for svc in services:
            svc.install()


if __name__ == '__main__':
    main(sys.argv[1:])
