#!/usr/bin/env python3
"""Run the opt-in composition/transport checks against a private loopback sshd."""
import argparse
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
RECEIPT_PROXY = r'''import json,os,subprocess,sys,time
from pathlib import Path
root=Path(__file__).parent
args=['/usr/bin/ssh','-F',str(root/'client_config'),*sys.argv[1:]]
control=root/'receipt-control.json'
if not control.exists() or not sys.argv[-1].startswith('python3 -c '):
 os.execv(args[0],args)
request=sys.stdin.buffer.read()
value=json.loads(request)
settings=json.loads(control.read_text())
process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
out,err=process.communicate(request)
if process.returncode==0 and value.get('action')==settings['action'] and value.get('root')==settings['root']:
 with (root/'receipt-calls').open('a') as log:log.write(value['action']+'\n')
 (root/'receipt-ready').write_bytes(out)
 while control.exists():time.sleep(0.02)
sys.stdout.buffer.write(out);sys.stderr.buffer.write(err)
sys.exit(process.returncode)
'''


def write(path, content, mode=0o600):
    path.write_text(content)
    path.chmod(mode)


def configure(directory):
    (directory / "home/.ssh").mkdir(parents=True, mode=0o700)
    (directory / "files/report[2026]").mkdir(parents=True)
    (directory / "files/star*dir").mkdir()
    write(directory / "files/plain.md", "# relaybar-live-ok\n")
    write(directory / "files/draft?.md", "# literal filename\n")
    (directory / "http").mkdir()
    write(directory / "http/index.html", "relaybar-live-ok\n")
    client = directory / "home/.ssh/id_ed25519"
    host = directory / "host_key"
    for key in (client, host):
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                       check=True, stdout=subprocess.DEVNULL)
    kind, public, *_ = host.with_suffix(".pub").read_text().split()
    write(directory / "known_hosts", f"[127.0.0.1]:2222 {kind} {public}\n")
    user = pwd.getpwuid(os.getuid()).pw_name
    # StrictModes only concerns this disposable daemon's generated authorized-key
    # file below a mode-0700 directory in /private/tmp. System sshd is untouched.
    write(directory / "sshd_config", f"""Port 2222
ListenAddress 127.0.0.1
HostKey {host}
PidFile {directory}/sshd.pid
AuthorizedKeysFile {client}.pub
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers {user}
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
PermitTunnel no
X11Forwarding no
Subsystem sftp internal-sftp
LogLevel VERBOSE
""")
    write(directory / "client_config", f"""Host 127.0.0.1
  User {user}
  Port 2222
  IdentityFile {client}
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile {directory}/known_hosts
  GlobalKnownHostsFile /dev/null
  ConnectTimeout 5
""")
    config = shlex.quote(str(directory / "client_config"))
    for name, binary, options in [("ssh-fixture", "ssh", ""), ("sftp-fixture", "sftp", ""),
                                  ("sftp-slow-fixture", "sftp", "-l 1024 ")]:
        write(directory / name, f'#!/bin/sh\nexec /usr/bin/{binary} -F {config} {options}"$@"\n', 0o700)
    write(directory / "ssh-receipt-fixture", "#!/usr/bin/env python3\n" + RECEIPT_PROXY, 0o700)
    subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(directory / "sshd_config")], check=True)


def stop(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New directory for test and server logs")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.error("Run as an ordinary macOS user with Xcode installed.")
    for port in (2222, 8765, 9876):
        with socket.socket() as candidate:
            candidate.bind(("127.0.0.1", port))
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        (ROOT / ".build").mkdir(exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="live-loopback-", dir=ROOT / ".build"))
    directory = Path(tempfile.mkdtemp(prefix="rb058-", dir="/private/tmp"))
    processes, logs = [], []
    report = {"fixture": str(directory), "output": str(output), "listener": "127.0.0.1",
              "system_ssh_configuration_changed": False, "test_exit_code": None}
    try:
        configure(directory)
        commands = [("sshd.log", ["/usr/sbin/sshd", "-D", "-e", "-f", str(directory / "sshd_config")]),
                    ("http.log", [sys.executable, "-m", "http.server", "8765", "--bind", "127.0.0.1",
                                  "--directory", str(directory / "http")])]
        for name, command in commands:
            log = (output / name).open("w")
            logs.append(log)
            processes.append(subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log,
                                              stderr=subprocess.STDOUT, start_new_session=True))
        deadline = time.monotonic() + 10
        while "Server listening on 127.0.0.1 port 2222" not in (output / "sshd.log").read_text():
            if processes[0].poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"The fixture sshd did not start; inspect {output / 'sshd.log'}")
            time.sleep(0.05)
        probe = subprocess.run([str(directory / "ssh-fixture"), "127.0.0.1", "printf relaybar-live-ok"],
                               check=True, capture_output=True, text=True)
        assert probe.stdout == "relaybar-live-ok"
        with (output / "sftp-capabilities.log").open("w") as log:
            subprocess.run([str(directory / "sftp-fixture"), "-vv", "-b", "/dev/null", "127.0.0.1"],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        environment = dict(os.environ, RELAYBAR_LOOPBACK_SSH_DIR=str(directory))
        command = ["swift", "test", "--package-path", str(ROOT / "Apps/RelayBar"),
                   "-Xswiftc", "-warnings-as-errors", "--filter", "LiveLoopbackTests"]
        print(f"Running real OpenSSH checks; logs: {output}", flush=True)
        with (output / "tests.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        report["test_exit_code"] = result.returncode
    finally:
        for process in reversed(processes):
            stop(process)
        for log in logs:
            log.close()
        shutil.rmtree(directory)
        report["fixture_removed"] = not directory.exists()
        report["servers_stopped"] = all(process.poll() is not None for process in processes)
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return report["test_exit_code"]


if __name__ == "__main__":
    sys.exit(main())
