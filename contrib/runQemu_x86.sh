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

QUERY=$1
DIST_DIR=$(bob query-path --fail -f '{dist}' ${SANDBOX} ${QUERY})
ISOFILE=$DIST_DIR/muen.iso
QEMU_SERIAL_WAIT=8

QEMU=qemu-system-x86_64
QEMU_SSH_PORT=$((1025 + RANDOM % 64511))
QEMU_NETDEV_OPTS="user,id=net0,net=192.168.254.0/24,"
QEMU_NETDEV_OPTS="${QEMU_NETDEV_OPTS}dhcpstart=192.168.254.100,"
QEMU_NETDEV_OPTS="${QEMU_NETDEV_OPTS}hostfwd=tcp::${QEMU_SSH_PORT}-:22"

efi=$(bob show $SANDBOX -f buildVars //${QUERY}/bsp::grub2 | grep GRUB2_PLATFORM)
efi=${efi#*: }

QEMU_CMD="${QEMU} \
	-drive file=${ISOFILE},index=0,media=disk,format=raw \
	-chardev pty,id=char0,logfile=serial.out -serial chardev:char0 \
	-machine pc-q35-7.2,accel=kvm,kernel-irqchip=split \
	-cpu IvyBridge-IBRS,+invtsc,+vmx \
	-m 5120 \
	-smp cores=2,threads=2,sockets=1 \
	-device intel-iommu,intremap=on,device-iotlb=on \
	-device virtio-net-pci,bus=pcie.0,addr=2.0,netdev=net0,disable-legacy=on,disable-modern=off,iommu_platform=on,ats=on \
	-netdev ${QEMU_NETDEV_OPTS} \
	-device qemu-xhci,id=xhci,bus=pcie.0,addr=3.0 \
	-device usb-tablet,bus=xhci.0 \
	-device rtl8139,bus=pcie.0,addr=4.0,netdev=net1 \
	-netdev user,id=net1,net=192.168.253.0/24,dhcpstart=192.168.253.100 \
	-display curses"

if [[ ${efi} == "efi" ]]; then
	QEMU_CMD="$QEMU_CMD -bios OVMF.fd"
fi

qpid=$(cat emulate.pid 2>/dev/null || true)
if [[ -n "$qpid" ]] && ps -p $qpid > /dev/null; then
	echo "* $QEMU with PID $qpid still running, killing it"
	kill $qpid
fi
rm -f emulate.*
rm -f serial.out

echo "Using command '$QEMU_CMD'" > emulate.cmd
screen -L -Logfile emulate.out -dmS kvm-muen ${QEMU_CMD} -pidfile emulate.pid
echo -n "* $QEMU started for '$ISOFILE', waiting for boot: "
for _ in $(seq 1 $QEMU_SERIAL_WAIT); do
	sleep 1
	echo -n .
	boot=$(grep 'DBG-LOG' serial.out 2>/dev/null || true)
	if [ -n "$boot" ]; then
		echo " OK"; echo
		echo "    SSH: ssh -p $QEMU_SSH_PORT root@localhost"
		echo "         (password: muen)"
		echo "    PTY: $(grep -o "/dev/pts/[0-9]*" emulate.out)"
		echo "    PID: $(cat emulate.pid)"
		echo "Console: screen -r kvm-muen"
		echo "         (C-A k to quit, C-A d to detach)"
		break
	fi
done
if [ -z "$boot" ]; then
	echo
	echo "ERROR executing '$QEMU_CMD', see emulate.out for details"
	exit 1;
fi
exit 0
