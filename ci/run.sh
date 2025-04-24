#!/bin/bash

set -euxo pipefail

if ! command -v bob > /dev/null; then
  echo "ERROR - bob build tool not in PATH or not installed"
  exit 1
fi

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RECIPES=$(realpath "$SCRIPTDIR/..")
NCI=$SCRIPTDIR/nci

sandbox=""
artifacts_dir=""
bob_args=""
deploy_to_hw=false
recipes=()

while getopts "a:b:dsr:" opt; do
	case $opt in
		a) artifacts_dir="$OPTARG" ;;
		b) bob_args="$OPTARG" ;;
		d) deploy_to_hw=true ;;
		s) sandbox="--sandbox" ;;
		r) IFS=',' read -r -a recipes <<< "$OPTARG" ;;
		*)
			echo "Usage: $0 [-a artifacts_dir] [-b bob_args] [-d] [-s]"
			echo "  -d  Also deploy to hardware"
			echo "  -s  Assume sandbox build"
			echo "  -r  Run specific root recipes (comma separated)"
			exit 1
			;;
	esac
done

pushd "$RECIPES" > /dev/null || \
  { echo "ERROR - path to recipes does not exist or is not a directory" ; \
    exit 1; }

# (1) Create artifacts_dir to save our output and update bob layers.
if [ -z "$artifacts_dir" ]; then
	artifacts_dir=$(mktemp -d /tmp/nci-XXXXXX)
else
	artifacts_dir=$(realpath "$artifacts_dir")
fi

mkdir -p "$artifacts_dir"
bob layers update

# (2) Filter bob recipes for supported demo projects with qemu always
# and hardware optional as well as find corresponding nci plans.
bob layers update

plans=()

if [ ${#recipes[@]} -eq 0 ]; then
	recipes=($(bob ls | grep "demo-qemu-"))

	if [ "$deploy_to_hw" = true ]; then
		recipes+=($(bob ls | grep "demo-xilinx-"))
	fi
fi

for r in "${recipes[@]}"; do
	p=($(find "${SCRIPTDIR}/nci-config/arm64" -name "*${r}.yaml"))
	if [[ -n "${p[0]}" ]]; then
		plans+=("${p[0]}")
	else
		echo "WARNING - no matching plan for recipe '${r}'"
		recipes=("${recipes[@]/$r}")
	fi
done

# (3) Build recipes with bob dev and gdb support enabled.
bob dev \
	${bob_args} \
	${sandbox} \
	${recipes[@]} | tee -a "$artifacts_dir/bob.log"

# (4) Add required QEMU tools and devicetrees to path.
QEMU_PATH=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //devel::xilinx::qemu)/usr/bin
DTB_PATH=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //devel::xilinx::qemu-devicetrees)

export PATH=$QEMU_PATH:$PATH
export DTB_PATH=$DTB_PATH

# (5) Setup environment for all nci plans.
nci_defines=()

for r in "${recipes[@]}"; do
	varname=$(echo "${r}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_IMAGE_DIR
	varvalue="${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //${r})"
	nci_defines+=("-D${varname}=${varvalue}")
done

popd > /dev/null

# (6) Call nci application with generated plans and defines.
pushd "$NCI" > /dev/null || \
  { echo "ERROR - path to nci does not exist or is not a directory" ; \
    exit 1; }

ARGS+="-a $artifacts_dir"

./nci run $ARGS \
	-c "${plans[@]}" \
	"${nci_defines[@]}" \
	-DCONFIG_DIR="$SCRIPTDIR/nci-config"

popd > /dev/null
