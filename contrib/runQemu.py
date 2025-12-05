#!/usr/bin/env python3

import os
import argparse
import sys
import signal
import subprocess
from pathlib import Path

sys.path.append("ci/nci")

from lib.logger import log
from lib.process import stop_disable
from lib.hosts import Host
from steps.vm_qemu import VmQemu
from steps.vm_qemu_xilinx import VmQemuXilinx

netdev_extra_opts = os.getenv("QEMU_NETDEV_EXTRA_OPTS")

pidfile: Path = Path(f"/tmp/emulate-{os.getenv("USER")}.pid")


def exec(cmd: str) -> str:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
            shell=True,
        )

        output = result.stdout.strip()

        return output

    except subprocess.CalledProcessError as e:
        log.error(f"Command '{cmd}' failed with return code: {e.returncode}")
        log.error(f"{e.stderr.strip()}")
        sys.exit(1)


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


def run_arm64(workdir: Path):
    h = Host(
        name="arm64-qemu", plan="testplan", artifacts_dir=".", config={"steps": None}
    )
    vm = VmQemuXilinx(host_ref=h, id="run")
    vm.start(
        workdir=workdir,
        image="sdcard.img",
        serial1_path="serial1.out",
        serial2_path="serial2.out",
    )
    log.info(f"Artifacts directory is {vm.artifacts_path}")
    log.info("SSH root password is 'muen'")
    with open(pidfile, "w") as pid:
        pid.write(str(vm.process.proc.pid))


def run_x86(image: Path):
    h = Host(
        name="x86-qemu", plan="testplan", artifacts_dir=".", config={"steps": None}
    )
    disk_config = {
            "size_mb": 356,
            "partitions": [{
                "name": "Testing",
                "final_lba": 411647,
                "setup_script": "ci/nci-config/x86/scripts/target/muenblock-ref",
            },
            {
                "name": "ext",
                "final_lba": 729054,
            },
        ],
    }
    vm = VmQemu(host_ref=h, id="run")
    vm.start(
        workdir=".",
        image=image,
        serial_path="serial.out",
        netdev_extra_options=netdev_extra_opts,
        disk_config=disk_config
    )
    log.info(f"Artifacts directory is {vm.artifacts_path}")
    log.info("SSH root password is 'muen'")
    with open(pidfile, "w") as pid:
        pid.write(str(vm.process.proc.pid))
    with open(vm.process.stderr_path, "r") as vnc_info:
        log.info(vnc_info.read().rstrip())


parser = argparse.ArgumentParser()
parser.add_argument("--query", "-q", help="package query")
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

if not args.query:
    sys.exit("Please specify package query with -q")


dist_dir: str = exec(cmd=f"bob query-path --fail -f {{dist}} {args.query}")
lines = dist_dir.splitlines()
if len(lines) != 1:
    log.error("Your query is ambiguous, it returned multiple results:")
    for line in lines:
        log.info(f"{line}")
    sys.exit(1)

log.info(f"Using dist dir '{dist_dir}'")

stop_disable()
if "x86" in args.query:
    log.info("Assuming x86 architecture")
    run_x86(image=Path(dist_dir) / "muen.iso")
elif "arm64" in args.query:
    log.info("Assuming arm64 architecture")

    qemu_path: Path = Path(
        exec(cmd="bob query-path --fail -f {dist} //devel::xilinx::qemu")
    )
    qemu_path = qemu_path / "usr/bin"
    log.info(f"Using QEMU from {qemu_path}")

    dtb_path: Path = Path(
        exec(cmd="bob query-path --fail -f {dist} //devel::xilinx::qemu-devicetrees")
    )
    log.info(f"Using device tree from {dtb_path}")

    os.environ["PATH"] = str(qemu_path.resolve()) + os.pathsep + os.environ["PATH"]
    os.environ["DTB_PATH"] = str(dtb_path.resolve())
    run_arm64(workdir=Path(dist_dir))
else:
    sys.exit("Unable to determine architecture")
