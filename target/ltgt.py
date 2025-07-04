#!/usr/bin/env python

import sys
import os
import yaml
import argparse
from typing import List, Dict
import pyinotify

from tgtconfig import ConfigAgent, ConfigObject


class DiskGroup(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.disks = []

    def build(self):
        if 'disknames' in self.cfgdt.cfg:
            disknames = self.cfgdt.disknames
        else:
            disknames = [f'{hostid}-{diskid}'
                         for diskid in self.cfgdt.diskids
                         for hostid in self.cfgdt.hostids]
        for diskname in disknames:
            diskpath = f'{self.cfgdt.diskdir}/{diskname}'
            disk = DiskDevice(diskpath)
            self.disks.append(disk)
            disk.build()

    def getdisks(self):
        return self.disks.values()


class Device(ConfigObject):
    """
    A block device.
    """
    def __init__(self, cfg, devpath):
        super().__init__(cfg)
        self.name = os.path.basename(devpath)
        self.devpath = devpath
        self.consumers = []         # up level devices
        self.providers = []         # lo level devices

    def consume(self, provider):
        self.providers.append(provider)
        provider.consumers.append(self)

    def unconsume(self, provider):
        provider.consumers.remove(self)
        self.providers.remove(provider)

    def watch(self, dwm):
        pass

    def handle_add(self):
        pass

    def handle_del(self):
        pass


class DiskDevice(Device):
    def __init__(self, devpath):
        super().__init__(None, devpath)
        self.gpted = False

    def destroy(self, agent):
        if len(self.consumers) == 0:
            agent.execute('disk_wipe', self.devpath)

    def watch(self, dwm):
        dwm.watch_device(self)

    def getpart(self, partname, partsizes):
        part = PartDevice(partname, partsizes)
        part.consume(self)
        return part

    def mkpart(self, partname, partsizes, agent):
        if not self.gpted:
            agent.execute('parted_label', self.devpath)
            self.gpted = True
        agent.execute('parted_mkpart', self.devpath, partname,
                      partsizes[0], partsizes[1])

    def rmpart(self, partname, agent):
        agent.execute('parted_rm', self.devpath, partname)


class PartDevice(Device):
    def __init__(self, name, partsizes):
        super().__init__(None, f'/dev/disk/by-partlabel/{name}')
        self.partsizes = partsizes

    def create(self, agent):
        disk = self.providers[0]
        disk.create(agent)
        disk.mkpart(self.name, self.partsizes, agent)

    def destroy(self, agent):
        disk = self.providers[0]
        disk.rmpart(self.name, agent)
        disk.destroy(agent)

    def handle_add(self):
        print(f'{self.devpath} handle add')

    def handle_del(self):
        print(f'{self.devpath} handle del')


class NullDevice(Device):
    """
    used for a nil journal volume to unify volume usage.
    """
    def __init__(self):
        super().__init__(None, '/dev/null')


class ZpoolDevice(Device):
    def __init__(self, cfg):
        super().__init__(cfg, cfg['name'])
        self.created = 0

    def build(self, diskgroups):
        dg = diskgroups[self.cfgdt.diskgroup]
        for disk in dg.disks:
            self.consume(disk)

    def create(self, agent):
        if not self.created:
            diskpaths = [provider.devpath for provider in self.providers]
            agent.execute('zpool_create', self.name, self.cfgdt.type, *diskpaths)
            self.created = 1

    def destroy(self, agent):
        agent.execute('zpool_destroy', self.name)

    def handle_add(self):
        pass

    def handle_del(self):
        pass


class RaidDevice(Device):
    def __init__(self, cfg):
        super().__init__(cfg, f"/dev/md/{cfg['name']}")

    def build(self, diskgroups):
        dg = diskgroups[self.cfgdt.diskgroup]
        if 'disknum' in self.cfgdt.cfg:
            ndisk = self.cfgdt.disknum
            disks = dg.disks[0:ndisk]
        else:
            disks = dg.disks
        assert len(disks) > 1
        for i, disk in enumerate(disks):
            partname = f'{self.cfgdt.name}-{i}'
            part = disk.getpart(partname, self.cfgdt.partsizes)
            self.consume(part)

    def create(self, agent):
        for provider in self.providers:
            provider.create(agent)
        partpaths = [provider.devpath for provider in self.providers]
        agent.execute('mdraid_create', self.cfgdt.name, self.cfgdt.type,
                      *partpaths)

    def destroy(self, agent):
        partpaths = [provider.devpath for provider in self.providers]
        agent.execute('mdraid_destroy', self.cfgdt.name, self.cfgdt.type,
                      *partpaths)
        for provider in self.providers:
            self.unconsume(provider)
            provider.destroy(agent)

    def handle_add(self):
        print(f'{self.name} handle add')

    def handle_del(self):
        print(f'{self.name} handle del')


class RawDevice(Device):
    """
    Raw devices exist to act as trivial wrappers on partition devices.
    Their names are the same as the ones of patition devices.
    """
    def __init__(self, cfg):
        super().__init__(cfg, f"/dev/disk/by-partlabel/{cfg['name']}")

    def build(self, diskgroups):
        dg = diskgroups[self.cfgdt.diskgroup]
        disk = dg.disks[0]
        part = disk.getpart(self.name, self.cfgdt.partsizes)
        self.consume(part)

    def create(self, agent):
        provider = self.providers[0]
        provider.create(agent)

    def destroy(self, agent):
        provider = self.providers[0]
        self.unconsume(provider)
        provider.destroy(agent)

    def handle_add(self):
        print(f'{self.name} handle add')

    def handle_del(self):
        print(f'{self.name} handle del')


class LustreTgt(ConfigObject):
    def __init__(self, cfg, fs: str, mgsnids: str, osdtype: str):
        super().__init__(cfg)
        self.fs = fs
        self.osdtype = osdtype
        self.mgsnids = ':'.join(mgsnids)
        self.svcnids = ':'.join(self.cfgdt.nids)

    def build(self, devices):
        mydevs = [devices[name] for name in self.cfgdt.devs]
        mydevs.append(NullDevice())
        self.ddev = mydevs[0]
        self.jdev = mydevs[1]

    def create(self, agent):
        self.jdev.create(agent)
        self.ddev.create(agent)
        tgttype = self.cfgdt.name[0:3]
        cmd = f'{self.osdtype}_{tgttype}_create'
        agent.execute(cmd, self.fs, self.cfgdt.name, self.svcnids, self.mgsnids,
                      self.ddev.devpath, self.jdev.devpath)

    def destroy(self, agent):
        cmd = f'{self.osdtype}_tgt_destroy'
        agent.execute(cmd, self.fs, self.cfgdt.name, self.ddev.devpath)
        #print('destroy volumes', self.jdev, self.ddev, flush=True)
        self.jdev.destroy(agent)
        self.ddev.destroy(agent)
    
    def watch_volumes(self, wacher):
        """
        wds = self.jdev.register_watch(watcher)
        for wd in wds:
        self.ddev.monitor()
        sleep(1)
        """
        pass

class LustreNode(ConfigObject):
    def __init__(self, cfg):
        super().__init__(cfg)
        self.diskgroups = {}
        self.devices = {}
        self.targets = []

    def build(self):
        lfscfg = self.cfgdt.lustre

        for cfg in self.cfgdt.diskgroups:
            dg = DiskGroup(cfg)
            self.diskgroups[cfg['name']] = dg
            dg.build()

        for cfg in self.cfgdt.devices:
            cls = find_device_class(lfscfg['osdtype'], cfg['type'])
            dev = cls(cfg)
            self.devices[cfg['name']] = dev
            dev.build(self.diskgroups)

        for cfg in self.cfgdt.targets:
            tgt = LustreTgt(cfg, lfscfg['fsname'], lfscfg['mgsnids'], lfscfg['osdtype'])
            self.targets.append(tgt)
            tgt.build(self.devices)

    def create(self, agent):
        for tgt in self.targets:
            tgt.create(agent)

    def destroy(self, agent):
        self.targets.reverse()
        for tgt in self.targets:
            tgt.destroy(agent)

device_classes = {
    'ldiskfs': {
        'raid1':    RaidDevice,
        'raid5':    RaidDevice,
        'raid6':    RaidDevice,
        'raw':      RawDevice, 
    },
    'zfs': {
        'mirror':   ZpoolDevice,
        'raidz1':   ZpoolDevice,
        'raidz2':   ZpoolDevice, 
    },
}
def find_device_class(osdtype, raid):
    global device_classes
    if osdtype in device_classes and raid in device_classes[osdtype]:
        return device_classes[osdtype][raid]
    raise ValueError(f'unknown raidtype {raid} for osdtype {osdtype}')


def build(config):
    lnode = LustreNode(config)
    lnode.build()
    agents = ConfigAgent.from_config(config['agents'])
    return agents, lnode


def create(agents, lnode):
    for agent in agents:
        lnode.create(agent)

def destroy(agents, lnode):
    for agent in agents:
        lnode.destroy(agent)


def lustre_parse_config_devices(config):
    agentcfg = config['agent']
    lfscfg = config['lustre']

    diskgroups = {}
    for cfg in config['diskgroups']:
        dg = DiskGroup.from_config(cfg)
        diskgroups[dg.name] = dg

    devices = []
    for cfg in config['devices']:
        cls = find_device_class(lfscfg['osdtype'], cfg['type'])
        dev = cls.from_config(cfg, diskgroups)
        devices.append(dev)

    return devices


class DeviceWatcher(pyinotify.ProcessEvent):
    def __init__(self, path):
        self.devdir = path
        self.devpaths = {}

    def add_device(self, device):
        devpath = device.devpath
        if os.path.dirname(devpath) == self.devdir:
            self.devpaths[devpath] = device
            return True
        return False

    def del_device(self, device):
        devpath = device.devpath
        if devpath in self.devpaths:
            del self.devpaths[devpath]

    def register(self, wm):
        mask = (pyinotify.IN_CREATE |
                pyinotify.IN_MOVED_TO |
                pyinotify.IN_DELETE | 
                pyinotify.IN_DELETE_SELF |
                pyinotify.IN_MOVED_FROM)
        wm.add_watch(self.devdir, mask, proc_fun=self)

    def process_event(self, action, devpath):
        if devpath not in self.devpaths:
            return
        handler = self.devpaths[devpath]
        method = getattr(handler, f'handle_{action}')
        method(devpath)

    def process_IN_CREATE(self, event):
       device = self.devpaths.get(event.pathname, default=None)
       if device:
           device.handle_add()

    def process_IN_MOVED_TO(self, event):
       device = self.devpaths.get(event.pathname, default=None)
       if device:
           device.handle_add()

    def process_IN_DELETE(self, event):
       device = self.devpaths.get(event.pathname, default=None)
       if device:
           device.handle_del()

    def process_IN_MOVED_FROM(self, event):
       device = self.devpaths.get(event.pathname, default=None)
       if device:
           device.handle_del()

    def process_IN_DELETE_SELF(self, event):
        for _, device in self.devpaths.items():
            device.handle_del()


class DeviceWatchManager(pyinotify.WatchManager):
    def __init__(self):
        super().__init__()
        self.watchers = []

    def watch_device(self, device):
        for watcher in self.watchers:
            if watcher.add_device(device):
                return
        devdir = os.path.dirname(device.devpath)
        watcher = DeviceWatcher(devdir)
        watcher.add_device(device)
        self.watchers.append(watcher)
        print(f'add watch for {devdir}')

    def unwatch_device(self, devpath):
        pass


def monitor_volumes(config):
    devices = parse_config_devices(config)

    dwm = DeviceWatchManager()

    for device in devices:
        device.grow_tree()
        print(f'watch for {device.name}')
        device.watch_tree(dwm)

    notifier = pyinotify.Notifier(dwm);
    notifier.loop()


def main():
    parser = argparse.ArgumentParser(description="target script")
    parser.add_argument(dest='operation', choices=['create', 'destroy', 'monitor'], 
                        help="create/destroy/monitor lustre deployment")
    parser.add_argument('-c', '--config', type=str, default='./ltgt.yaml',
                        help="Path to the config file")
    args = parser.parse_args()

    with open(args.config, 'r') as f:
        config = yaml.safe_load(f)
        agents, lnode = build(config)
        if args.operation == 'create':
            create(agents, lnode)
        elif args.operation == 'destroy':
            destroy(agents, lnode)
        else:
            monitor_volumes(config)


if __name__ == "__main__":
    main()
