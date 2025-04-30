#!/bin/bash

set -euo pipefail

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
ext_recipes=()
ext_plans=()

while getopts "a:b:dsr:p:glhx" opt; do
	case $opt in
		a) artifacts_dir="$OPTARG" ;;
		b) bob_args="$OPTARG" ;;
		d) deploy_to_hw=true ;;
		s) sandbox="--sandbox" ;;
		r) IFS=',' read -r -a ext_recipes <<< "$OPTARG" ;;
		p) IFS=',' read -r -a ext_plans <<< "$OPTARG" ;;
		g)
			pushd "$NCI" || \
			{ echo "ERROR - path to nci does not exist or is not a directory" ; \
			  exit 1; }
			find "${SCRIPTDIR}/nci-config/arm64" -name "*.gen.yaml" -exec rm {} \;
			ext_plans=($(find "${SCRIPTDIR}/nci-config/arm64" -name "*.yaml"))
			./nci gen -c "${ext_plans[@]}"
			popd
			exit 0
			;;
		l)
			ext_recipes=($(cd "$RECIPES" || exit ; bob ls | grep "demo-"))
			ext_plans=($(ls "${SCRIPTDIR}/nci-config/arm64" | grep ".yaml"))
			echo "Bob Recipes:"
			for r in "${ext_recipes[@]}"; do
				echo "    ${r}"
			done
			echo "NCI Plans:"
			for p in "${ext_plans[@]}"; do
				echo "    ${p%.yaml}"
			done
			exit 0
			;;
	  x) set -x ;;
		*)
			echo "Usage: $0 [-a artifacts_dir] [-b bob_args] [-d] [-s] [-r recipe[,recipe]] [-p plan[,plans]] | -g | -l"
			echo "  -a  Path to artifacts directory incl. bob log"
			echo "  -b  Additional arguments for bob (e.g. \"-DMUEN_GDB_SUPPORT=enabled\")"
			echo "  -d  Also deploy to hardware"
			echo "  -s  Assume sandbox build"
			echo "  -r  Run specific bob recipes with default plans (comma separated)"
			echo "  -p  Run specific nci plans (comma separated)"
			echo "  -g  Generate pre-rendered nci plan(s)"
			echo "  -l  List all supported bob recipes and nci plans"
			echo "  -x  Enable print trace"
			exit 1
			;;
	esac
done

pushd "$RECIPES" > /dev/null || \
  { echo "ERROR - path to recipes does not exist or is not a directory" ; \
    exit 1; }

# Create artifacts_dir to save our output and update bob layers.
if [ -z "$artifacts_dir" ]; then
	artifacts_dir=$(mktemp -d /tmp/nci-XXXXXX)
else
	artifacts_dir=$(realpath "$artifacts_dir")
fi

mkdir -p "$artifacts_dir"
bob layers update

# If called without explicitly requested recipes or plans, all supported
# qemu and, if deploy to hardware enabled, xilinx recipes are added to
# the integration test runner. Else the external recipes are checked and
# added, if supported.
declare -A runner

if [ ${#ext_recipes[@]} -eq 0 ] && [ ${#ext_plans[@]} -eq 0 ]; then
  for r in $(bob ls | grep "demo-qemu-"); do
    runner["${r}"]=""
  done

  if [ "$deploy_to_hw" = true ]; then
    for r in $(bob ls | grep "demo-xilinx-"); do
      runner["${r}"]=""
    done
  fi
fi

for r in "${ext_recipes[@]}"; do
  if bob ls | grep -w "${r}$" > /dev/null; then
    runner["${r}"]=""
  else
    echo "WARNING - recipe '${r}' not supported by bob"
  fi
done

# For all bob recipes added to the test runner, find the default nci
# plans with log deploy mode for prove, sdcard for qemu and tftp for
# xilinx related recipes.
for r in "${!runner[@]}"; do
  p=($(find "${SCRIPTDIR}/nci-config/arm64" -name "*${r}*.yaml" \
       -not -name "*.gen.yaml"))
  found=1

  for d in "${p[@]}"; do
    if [[ "$d" == *"prove-log"* || "$d" == *"qemu"*"sdcard"* || \
          "$d" == *"xilinx"*"tftp"* ]]; then
      runner["${r}"]="${runner[${r}]:-}${d} "
      found=0
    fi
  done

  if [ $found -ne 0 ]; then
    echo "WARNING - no matching (default) plans for recipe '${r}'"
    unset "runner[${r}]"
  fi
done

# Check the explicitly requested plans and find the corresponding bob
# recipes, if supported. Finally exit, if no bob recipes and nci plans
# could be found.
for p in "${ext_plans[@]}"; do
  if ls "${SCRIPTDIR}/nci-config/arm64" | grep -w "${p}.yaml" > /dev/null; then
    r=($(bob ls | grep "${p%-*}"))
    if [[ -n "${r[0]}" ]]; then
      runner["${r[0]}"]="${runner[${r[0]}]:-}${SCRIPTDIR}/nci-config/arm64/${p}.yaml "
    else
      echo "WARNING - no matching recipe for plan '${p}'"
    fi
  else
    echo "WARNING - plan '${p}' not supported by nci-config"
  fi
done

if [ ${#runner[@]} -eq 0 ]; then
  echo "ERROR - no bob recipes or nci plans to be executed"
  exit 1
fi

# Build all requested bob recipes sequentially in bob develop mode.
# If the the build process fails, abort the entire test run.
for r in "${!runner[@]}"; do
  if ! bob dev ${bob_args} ${sandbox} "${r}" | tee -a "$artifacts_dir/bob.log"; then
     echo "ERROR - build failure for bob recipe '${r}' with nci plans '${runner[$r]}'"
     exit 1
  fi
done

# Add required QEMU tools and devicetrees to path.
QEMU_PATH=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //devel::xilinx::qemu)/usr/bin
DTB_PATH=${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //devel::xilinx::qemu-devicetrees)

export PATH=$QEMU_PATH:$PATH
export DTB_PATH=$DTB_PATH

# Setup nci plans including environment variables.
nci_plans=()
nci_defines=()

for r in "${!runner[@]}"; do
	nci_plans+=( ${runner[${r}]} )
	varname=$(echo "${r}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_IMAGE_DIR
	varvalue="${RECIPES}/$(bob query-path --fail -f {dist} ${sandbox} //${r})"
	nci_defines+=("-D${varname}=${varvalue}")
done

popd > /dev/null

# Call nci application with generated plans and defines.
pushd "$NCI" > /dev/null || \
  { echo "ERROR - path to nci does not exist or is not a directory" ; \
    exit 1; }

ARGS+="-a $artifacts_dir"

./nci run $ARGS \
	-c "${nci_plans[@]}" \
	"${nci_defines[@]}" \
	-DCONFIG_DIR="$SCRIPTDIR/nci-config"

popd > /dev/null
