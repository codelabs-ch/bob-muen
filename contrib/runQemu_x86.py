#!/usr/bin/env python3

import os
import argparse
import sys
import signal
from pathlib import Path

sys.path.append("ci/nci")

from lib.logger import log
from lib.process import stop_disable
from lib.hosts import Host
from steps.vm_qemu import VmQemu

serial_name = "serial.out"
netdev_extra_opts = os.getenv("QEMU_NETDEV_EXTRA_OPTS")

pidfile: Path = Path("emulate.pid")


def terminate_existing(pidfile) -> None:
    pid: int

    with open(pidfile, "r") as f:
        pid = int(f.read())
    pidfile.unlink()

    log.info(f"Terminating existing QEMU process with PID {pid}")
    try:
        os.kill(pid, 0)  # check if process exists
    except OSError:
        log.info(f"Process with PID {pid} does not exist")
        return

    try:
        os.killpg(pid, signal.SIGTERM)
        log.info(f"Process {pid} terminated")
    except Exception as e:
        log.error(f"Could not terminate {pid}: {e}")


def run(image: Path):
    h = Host(
        name="x86-qemu", plan="testplan", artifacts_dir=".", config={"steps": None}
    )
    vm = VmQemu(host_ref=h, id="run")
    vm.start(workdir=".", image=image, serial_path=serial_name, netdev_extra_options=netdev_extra_opts)
    log.info(f"Artifacts directory is {vm.artifacts_path}")
    log.info("SSH root password is 'muen'")
    with open(pidfile, "w") as pid:
        pid.write(str(vm.process.proc.pid))
    with open(vm.process.stderr_path, "r") as vnc_info:
        log.info(vnc_info.read().rstrip())


parser = argparse.ArgumentParser()
parser.add_argument("--dist-dir", "-i", help="path to dist file")
parser.add_argument(
    "--terminate-only",
    "-t",
    action="store_true",
    help="terminate existing QEMU if running and exit",
)
args = parser.parse_args()

if pidfile.exists():
    terminate_existing(pidfile)
if args.terminate_only:
    sys.exit()

if not args.dist_dir:
    sys.exit("Please specify dist dir with -i")

stop_disable()
run(image=Path(args.dist_dir) / "muen.iso")
