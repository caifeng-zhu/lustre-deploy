#!/usr/bin/env python

import os
import sys
import subprocess

etc_install_cases = [
        # install for lfs
        (1, 'etc_install_lfs_ok', [
            'etc_install',
            '/tmp/deploy-client/gpu-lustre.conf',
            '/tmp/deploy-client/mnt-test.mount',
            '/tmp/deploy-client/lfsmount.target',
            ]),

        # install for lvm
        (1, 'etc_install_lvm_ok', [
            'etc_install',
            '/tmp/deploy-client/nvme-rdma.ko',
            '/tmp/deploy-client/discovery.conf',
            '/tmp/deploy-client/sanlock',
            '/tmp/deploy-client/lvmlocal.conf',
            '/tmp/deploy-client/lvm.conf',
            ]),

        """
        (0, 'etc_install_lfs_mount_ok', [
            'etc_install',
            '/tmp/deploy-client/mnt-test.mount']),

        (0, 'etc_install_lfs_target_ok', [
            'etc_install',
            '/tmp/deploy-client/lfsmount.target']),

        # install for nvme
        (0, 'etc_install_nvme_rdma_ok', [
            'etc_install',
            '/tmp/deploy-client/nvme-rdma.ko']),

        (0, 'etc_install_nvme_discovery_ok', [
            'etc_install',
            '/tmp/deploy-client/discovery.conf']),

        (0, 'etc_install_nvme_discovery_fail', [
            'etc_install',
            '/tmp/deploy-client/test_fail-discovery.conf']),
        """

]

etc_uninstall_cases = [
        # uninstall for lfs
        (0, 'etc_uninstall_lfs_target_ok', [
            'etc_uninstall',
            '/tmp/deploy-client/lfsmount.target',
            '/tmp/deploy-client/mnt-test.mount',
            '/tmp/deploy-client/gpu-lustre.conf',
            ]),

        (0, 'etc_install_lvm_ok', [
            'etc_uninstall',
            '/tmp/deploy-client/lvm.conf',
            '/tmp/deploy-client/lvmlocal.conf',
            '/tmp/deploy-client/sanlock',
            '/tmp/deploy-client/discovery.conf',
            '/tmp/deploy-client/nvme-rdma.ko',
            ]),

        """
        (0, 'etc_uninstall_lfs_mount_ok', [
            'etc_uninstall',
            '/tmp/deploy-client/mnt-test.mount']),

        (0, 'etc_uninstall_lfs_conf_ok', [
            'etc_uninstall',
            '/tmp/deploy-client/gpu-lustre.conf']),
        """
]


def runcmd(cmd, debug):
    env = os.environ.copy()
    if debug:
        env['CLIENT_DEBUG'] = '1'

    print(f"=> {cmd}", flush=True)
    res = subprocess.run(cmd, shell=True, env=env)
    return res.returncode


def runtests(cases):
    for i, _ in enumerate(cases):
        if isinstance(cases[i], str):
            continue

        debug, name, cmdlist = cases[i]
        cmd = ' '.join(cmdlist)
        res = runcmd(f'./store-agent.sh {cmd}', debug)

        if name.endswith('ok') and res == 0:
            msg = '\033[32m OK: ok vs 0 \033[0m'
        elif name.endswith('ok') and res != 0:
            msg = f'\033[31m FAIL: ok vs {res} \033[0m'
        elif name.endswith('fail') and res == 0:
            msg = '\033[31m FAIL: fail vs 0 \033[0m'
        elif name.endswith('fail') and res != 0:
            msg = f'\033[32m OK: fail vs {res} \033[0m'
        else:
            raise ValueError(f'unexpected {name} vs {res}')
        print(f"DEBUG={debug} test {name} ... {msg}\n")


def main():
    runtests(etc_install_cases)
    runtests(etc_uninstall_cases)


if __name__ == '__main__':
    main()
