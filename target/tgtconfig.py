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


class ConfigAgent:
    def __init__(self, cfg):
        self.cfg = cfg
        self.client_cmds = []

    @property
    def mgmtip(self):
        return self.cfg['mgmtip']

    @property
    def mode(self):
        return self.cfg['mode']

    @property
    def workdir(self):
        return self.cfg['workdir']

    @property
    def script(self):
        return self.cfg['script']

    def workfile(self, origfile):
        return f'{self.workdir}/' + os.path.basename(origfile)

    def start(self):
        run(f'ssh root@{self.mgmtip} mkdir -p {self.workdir}')
        self.copy(self.script)

    def execute(self, opname, *args):
        mode = self.mode
        opargs = ' '.join(str(arg) for arg in args)
        script = self.workfile(self.script)
        run(f'ssh root@{self.mgmtip} {script} {mode} {opname} {opargs}')

    def copy(self, *files):
        copyfiles = ' '.join(files)
        run(f'scp {copyfiles} root@{self.mgmtip}:{self.workdir}')
        return [self.workfile(file) for file in files]

    @staticmethod
    def from_config(configs):
        agents = [ConfigAgent(cfg) for cfg in configs]
        agents.sort(key=lambda a: a.mode)
        for agent in agents:
            agent.start()
        return agents
