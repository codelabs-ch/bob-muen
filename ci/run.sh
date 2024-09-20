#!/bin/bash

set -euxo pipefail

command -v bob

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RECIPES=$(realpath $SCRIPTDIR/..)
NCI=$SCRIPTDIR/nci

sandbox=""
artifacts_dir=""
bob_args=""
deploy_to_hw=false
hw_mode="tftp"

while getopts "a:b:dsx" opt; do
	case $opt in
		a) artifacts_dir="$OPTARG" ;;
		b) bob_args="$OPTARG" ;;
		d) deploy_to_hw=true ;;
		s) sandbox="--sandbox" ;;
		x) hw_mode="xsct" ;;
		*)
			echo "Usage: $0 [-a artifacts_dir] [-b bob_args] [-d] [-s]"
			echo "  -d  Also deploy to hardware"
			echo "  -s  Assume sandbox build"
			echo "  -x  Deploy to hw via xsct (default: tftp)"
			exit 1
			;;
	esac
done

pushd $RECIPES

recipes=("demo-qemu-*" "testkernel-qemu-*")
plans=("$SCRIPTDIR/nci-config/arm64/qemu-*.yaml")

if [ "$deploy_to_hw" = true ]; then
	recipes+=("demo-xilinx-*" "testkernel-xilinx-*")
	plans+=("$SCRIPTDIR/nci-config/arm64/testkernel-*-${hw_mode}.yaml" "$SCRIPTDIR/nci-config/arm64/xilinx-*-${hw_mode}.yaml")
fi

# also save our output to artifacts_dir/
if [ -z "$artifacts_dir" ]; then
	artifacts_dir=$(mktemp -d /tmp/nci-XXXXXX)
else
	artifacts_dir=$(realpath $artifacts_dir)
fi
mkdir -p $artifacts_dir

bob dev \
	${bob_args} \
	${sandbox} \
	-DMUEN_BUILD_MODE=debug \
	-DMUEN_GDB_SUPPORT=enabled \
	-j$(nproc) \
	${recipes[@]} | tee -a $artifacts_dir/bob.log

QEMU_PATH=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //devel::xilinx::qemu)/usr/bin
DTB_PATH=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //devel::xilinx::qemu-devicetrees)

export PATH=$QEMU_PATH:$PATH
export DTB_PATH=$DTB_PATH

QEMU_MINIMAL_IMAGE_DIR=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //demo-qemu-zcu102-minimal)
QEMU_MULTICORE_IMAGE_DIR=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //demo-qemu-zcu102-multicore)
TSTKNL_QEMU_MINIMAL_IMAGE_DIR=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //testkernel-qemu-zcu102-minimal)
nci_defines=("-DQEMU_MINIMAL_IMAGE_DIR=$QEMU_MINIMAL_IMAGE_DIR" \
	"-DQEMU_MULTICORE_IMAGE_DIR=$QEMU_MULTICORE_IMAGE_DIR" \
	"-DTSTKNL_QEMU_MINIMAL_IMAGE_DIR=$TSTKNL_QEMU_MINIMAL_IMAGE_DIR")

if [ "$deploy_to_hw" = true ]; then
	XILINX_MINIMAL_IMAGE_DIR=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //demo-xilinx-zcu104-minimal)
	XILINX_MULTICORE_IMAGE_DIR=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //demo-xilinx-zcu104-multicore)
	TSTKNL_XILINX_MINIMAL_IMAGE_DIR=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //testkernel-xilinx-zcu104-minimal)

	bob dev \
		-n \
		${bob_args} \
		${sandbox} \
		--checkout-only \
		//demo-xilinx-zcu104-minimal/muen::muenonarm-subjects-example | tee -a $artifacts_dir/bob.log

	# TODO: move the target_scripts to nci-config?
	muen_path=$(bob query-path --fail -f {src} ${sandbox} //demo-xilinx-zcu104-minimal/muen::muenonarm-subjects-example)
	[ -z "$muen_path" ] && echo "Error: Unable to get Muen src path" && exit 1
	MUEN_DIR=${RECIPES}/${muen_path}
	# TODO: move the target_scripts to nci-config?
	muen_path=$(bob query-path --fail -f {src} ${sandbox} //demo-xilinx-zcu104-minimal/muen::muenonarm-subjects-example)
	[ -z "$muen_path" ] && echo "Error: Unable to get Muen src path" && exit 1
	MUEN_DIR=${RECIPES}/${muen_path}

	nci_defines+=("-DXILINX_MINIMAL_IMAGE_DIR=$XILINX_MINIMAL_IMAGE_DIR" \
		"-DXILINX_MULTICORE_IMAGE_DIR=$XILINX_MULTICORE_IMAGE_DIR" \
		"-DTSTKNL_XILINX_MINIMAL_IMAGE_DIR=$TSTKNL_XILINX_MINIMAL_IMAGE_DIR" \
		"-DMUEN_DIR=$MUEN_DIR")
fi

popd

pushd $NCI

ARGS+="-a $artifacts_dir"

./nci run $ARGS \
	-c ${plans[@]} \
	${nci_defines[@]} \
	-DCONFIG_DIR=$SCRIPTDIR/nci-config

popd
