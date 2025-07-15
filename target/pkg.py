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


class PkgAgent:
    def __init__(self, cfg, hosts):
        self.hosts = hosts
        self.workdir = cfg['workdir']
        self.script = cfg['script']

    def workfile(self, origfile):
        return f'{self.workdir}/' + os.path.basename(origfile)

    def start(self):
        run(f'clush -qS -l root -w {self.hosts} -b mkdir -p {self.workdir}')
        self.copy(self.script)

    def execute(self, opname, *args):
        #opargs = ' '.join(f"'{arg}'" for arg in args)
        opargs = ' '.join(args)
        script = self.workfile(self.script)
        run(f'clush -qS -l root -w {self.hosts} -b {script} active {opname} {opargs}')

    def copy(self, *files):
        copyfiles = ' '.join(files)
        run(f'clush -qS -l root -w {self.hosts} --copy {copyfiles} --dest {self.workdir}')
        return [ self.workfile(file) for file in files ]


class PkgGroup:
    def __init__(self, pkgs):
        self.copy_pkgs = [pkg for pkg in pkgs if pkg.endswith('.deb')]
        self.noncopy_pkgs = [pkg for pkg in pkgs if not pkg.endswith('.deb')]

    def install(self, agent):
        remote_pkgs = []
        remote_pkgs.extend(self.noncopy_pkgs)
        remote_pkgs.extend(agent.copy(*self.copy_pkgs))
        agent.execute('apt_install', *remote_pkgs)

    def uninstall(self, agent):
        remote_pkgs = []
        remote_pkgs.extend(self.noncopy_pkgs)
        remote_pkgs.extend(agent.copy(*self.copy_pkgs))
        remote_pkgs.reverse()
        agent.execute('apt_remove', *remote_pkgs)


def main(argv):
    global debug

    ap = argparse.ArgumentParser('deploy client hosts')
    ap.add_argument('-c', '--config', required=True, action='store')
    ap.add_argument('-n', '--nodes', required=True, action='store')
    ap.add_argument('-u', '--uninstall', required=False, action='store_true')
    ap.add_argument('--debug', required=False, action='store_true')
    args = ap.parse_args(args=argv)

    if args.debug:
        debug = True

    with open(args.config, 'r') as f:
        config = yaml.safe_load(f)

    agent = PkgAgent(config['agent'], args.nodes)
    agent.start()
    pkggrp = PkgGroup(config['pkgs'])
    if args.uninstall:
        pkggrp.uninstall(agent)
    else:
        pkggrp.install(agent)


if __name__ == '__main__':
    main(sys.argv[1:])
