#!/bin/bash

set -euo pipefail

# run qemu-image in qemu
if [[ $# -lt 1 ]]; then
	echo "Usage: ${0} <packageQuery> <sandbox>"
	exit 1
fi

if [[ ${2:-false} ]]; then
	SANDBOX="--sandbox"
else
	SANDBOX=""
fi

DIST_DIR=$(bob query-path --fail -f '{dist}' ${SANDBOX} ${1})

echo "Starting qemu for $1 (${DIST_DIR})"

QEMU_PATH=$(bob query-path --fail -f '{dist}' ${SANDBOX} ${1}//devel::xilinx::qemu)
QEMU_DEVICETREES=$(bob query-path --fail -f '{dist}' ${SANDBOX} ${1}//devel::xilinx::qemu-devicetrees)

SSH_PORT=$((1025 + RANDOM % 64511))
echo "SSH: ssh -p ${SSH_PORT} root@localhost"

exec ${QEMU_PATH}/usr/bin/qemu-system-aarch64  \
	-machine arm-generic-fdt \
	-chardev stdio,id=char0 -mon chardev=char0 \
	-chardev pty,id=char1,logfile=serial1.out -serial chardev:char1  \
	-chardev pty,id=char2,logfile=serial2.out -serial chardev:char2  \
	-display none \
	-device loader,file=${DIST_DIR}/debug_fsbl.elf,cpu-num=0 \
	-device loader,addr=0xfd1a0104,data=0x8000000e,data-len=4 \
	-drive file=${DIST_DIR}/sdcard.img,if=sd,format=raw,index=1 \
	-hw-dtb ${QEMU_DEVICETREES}/SINGLE_ARCH/zcu102-arm.dtb \
	-m 4G -global xlnx,zynqmp-boot.cpu-num=0 -boot mode=5 \
	-net nic -net nic -net nic -net nic,netdev=eth0 -netdev user,id=eth0,hostfwd=tcp::${SSH_PORT}-:22
