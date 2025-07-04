import os
import subprocess
import sys

debug = False


def run(cmd: str):
    print(f"=> {cmd}", flush=True)
    if debug:
        return
    try:
        subprocess.run(cmd, shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {e.cmd}\nExit code: {e.returncode}")
        sys.exit(e.returncode)


class ConfigData:
    def __init__(self, cfg):
        self.cfg = cfg

    def __getattr__(self, name):
        if self.cfg and name in self.cfg:
            return self.cfg[name]
        raise AttributeError(f'{name} not found')


class ConfigAgent:
    def __init__(self, cfg):
        self.cfgdt = ConfigData(cfg)
        self.client_cmds = []

    def workfile(self, origfile):
        return f'{self.cfgdt.workdir}/' + os.path.basename(origfile)

    def start(self):
        run(f'ssh root@{self.cfgdt.mgmtip} mkdir -p {self.cfgdt.workdir}')
        self.copy(self.cfgdt.script)

    def execute(self, opname, *args):
        mode = self.cfgdt.mode
        opargs = ' '.join(str(arg) for arg in args)
        script = self.workfile(self.cfgdt.script)
        run(f'ssh root@{self.cfgdt.mgmtip} {script} {mode} {opname} {opargs}')

    def copy(self, *files):
        copyfiles = ' '.join(files)
        run(f'scp {copyfiles} root@{self.cfgdt.mgmtip}:{self.cfgdt.workdir}')
        return [self.workfile(file) for file in files]

    @staticmethod
    def from_config(configs):
        agents = [ConfigAgent(cfg) for cfg in configs]
        agents.sort(key=lambda a: a.cfgdt.mode)
        for agent in agents:
            agent.start()
        return agents

class ConfigObject:
    def __init__(self, cfg):
       self.cfgdt = ConfigData(cfg)

    def build(self, *args):
        pass

    def create(self, agent):
        pass

    def destroy(self, agent):
        pass
