#!/bin/bash

set -euo pipefail

if ! command -v bob > /dev/null; then
	echo "ERROR - bob build tool not in PATH or not installed"
	exit 1
fi

# Search for given prefix in array
# $1 - prefix
# $2 - array to search
# Returns zero exit code on match
search_prefix() {
	local prefix="$1"
	shift
	local array=( "$@" )

	for item in "${array[@]}"; do
		if [[ $item == "$prefix"* ]]; then
			return 0
		fi
	done

	return 1
}

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RECIPES=$(realpath "$SCRIPTDIR/..")
NCI=$SCRIPTDIR/nci/nci

# Default recipes to display with -l.
recipes_r="^(arm64-|x86-)"
# Default emulation only recipes.
recipes_qemu_r="^(arm64|x86)-qemu"
# Default deployment recipes.
recipes_hw_r="^(arm64-xilinx-|x86-.*)"
recipes_hw_exclude_r="^(x86-qemu.*)"

sandbox=""
artifacts_dir=""
bob_args=""
deploy_to_hw=false
nci_defines=()

# explicitly requested recipes/plans
exp_recipes=()
exp_plans=()

while getopts "a:b:dsr:p:glhx" opt; do
	case $opt in
		a) artifacts_dir=$(realpath "$OPTARG") ;;
		b) bob_args="$OPTARG" ;;
		d) deploy_to_hw=true ;;
		s) sandbox="--sandbox" ;;
		r) IFS=',' read -r -a exp_recipes <<< "$OPTARG" ;;
		p) IFS=',' read -r -a exp_plans <<< "$OPTARG" ;;
		g)
			find "${SCRIPTDIR}/nci-config/arm64" -name "*.gen.yaml" -exec rm {} \;
			readarray -t plans < <(find "${SCRIPTDIR}/nci-config/arm64" -name "*.yaml")
			$NCI gen -c "${plans[@]}"
			exit 0
			;;
		l)
			readarray -t recipes < <(cd "$RECIPES" || exit ; bob ls | grep -E "$recipes_r")
			readarray -t plans < <(ls ${SCRIPTDIR}/nci-config/{arm64,x86}/*.yaml | rev | cut -d'/' -f1-2 | rev | tr '/' '-')
			echo "Bob Recipes:"
			for r in "${recipes[@]}"; do
				echo "    ${r}"
			done
			echo "NCI Plans:"
			for p in "${plans[@]}"; do
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
			echo "  -g  Generate pre-rendered nci plan(s) for arm64"
			echo "  -l  List all supported bob recipes and nci plans"
			echo "  -x  Enable print trace"
			exit 1
			;;
	esac
done

pushd "$RECIPES" > /dev/null
trap 'popd > /dev/null' EXIT

trap 'echo; echo CTRL-C pressed by user!; exit 1' SIGINT

if [ -z "$artifacts_dir" ]; then
	artifacts_dir=$(mktemp -d /tmp/nci-XXXXXX)
fi
mkdir -p "$artifacts_dir"

# Check whether we run in a tty, otherwise do not force enable colors for bob.
# Force enable is required since we want colors on the terminal, even though
# output is redirected to file.
bob_color=""
[ -t 1 ] && bob_color="--color=always"

ansi_rgx=$'\033\\[[0-9;]*[a-zA-Z]'
bob ${bob_color} layers update 2>&1 | tee >(sed -E "s/$ansi_rgx//g" > $artifacts_dir/bob.log)

# If called without explicitly requested recipes or plans, all supported
# qemu and, if deploy to hardware enabled, hardware recipes are added to
# the integration test runner. Else the external recipes are checked and
# added, if supported.
declare -A runner

if [ ${#exp_recipes[@]} -eq 0 ] && [ ${#exp_plans[@]} -eq 0 ]; then
	for r in $(bob ls | grep -E "$recipes_qemu_r"); do
		runner["${r}"]=""
	done

	if [ "$deploy_to_hw" = true ]; then
		for r in $(bob ls | grep -E "$recipes_hw_r" | grep -vE "$recipes_hw_exclude_r"); do
			runner["${r}"]=""
		done
	fi
fi

for r in "${exp_recipes[@]}"; do
	if bob ls | grep -w "${r}$" > /dev/null; then
		runner["${r}"]=""
	else
		echo "ERROR - recipe '${r}' not supported by bob"
		exit 1
	fi
done

# For all bob recipes added to the test runner, find the matching nci
# plans. For arm64, this means: log deploy mode for proof, sdcard for qemu and
# tftp for xilinx related recipes.
#
# On x86 we only support debug and proof, others are skipped.
for r in "${!runner[@]}"; do
	arch="${r%%-*}"
	scenario="${r#${arch}-}"

	if [ "${arch}" == "arm64" ]; then
		readarray -t p < <(find "${SCRIPTDIR}/nci-config/${arch}" -name "${scenario}-*.yaml" \
			-not -name "*.gen.yaml")
		found=1
		for d in "${p[@]}"; do
			# Select log file deployment for all proof plans, sdcard deployment
			# for all qemu related plans, tftp deployment for debug and release
			# mode of xilinx related plans and xsct deployment for xilinx unit
			# test related plans as default nci plans.
			if [[ "$d" == *"proof-log"* || "$d" == *"qemu"*"sdcard"* || \
				"$d" == *"xilinx"*"debug-tftp"* || \
				"$d" == *"xilinx"*"release-tftp"* || \
				"$d" == *"xilinx"*"test-xsct"* ]]; then
				runner["${r}"]="${runner[${r}]:-}${d}"
				found=0
			fi
		done

		if [ $found -ne 0 ]; then
			echo "ERROR - no matching (default) plans for recipe '${r}'"
			exit 1
		fi
	else
		plan=$(find "${SCRIPTDIR}/nci-config/${arch}" -name "${scenario}.yaml")
		if [ -z "$plan" ]; then
			echo "INFO - no nci plan for recipe '$r', skipped"
			unset 'runner["${r}"]'
		else
			runner["${r}"]="${plan}"
		fi
	fi
done

# Check the explicitly requested plans and find the corresponding bob
# recipes, if supported. Finally exit, if no bob recipes and nci plans
# could be found.
for p in "${exp_plans[@]}"; do
	arch="${p%%-*}"

	if [ "${arch}" == "arm64" ]; then
		# plan   : arm64-qemu-zcu102-minimal-debug-sdcard
		# recipe : arm64-qemu-zcu102-minimal-debug
		match="^${p%-*}$"
	else
		# 1:1 mapping of plans to recipes on x86.
		match="^${p}$"
	fi

	scenario="${p#${arch}-}"
	if ls "${SCRIPTDIR}/nci-config/${arch}/${scenario}.yaml" >/dev/null 2>&1; then
		readarray -t r < <(bob ls | grep "${match}")
		if [ "${#r[@]}" -ne 1 ]; then
			echo "ERROR - bob recipes count for plan '${p}' not 1: ${#r[@]}"
			exit 1
		fi
		if [[ -n "${r[0]}" ]]; then
			runner["${r[0]}"]="${runner[${r[0]}]:-}${SCRIPTDIR}/nci-config/${arch}/${scenario}.yaml "
		else
			echo "ERROR - no matching recipe for plan '${p}'"
			exit 1
		fi
	else
		echo "ERROR - plan '${p}' not supported by nci-config"
		exit 1
	fi
done

if [ ${#runner[@]} -eq 0 ]; then
	echo "ERROR - no bob recipes or nci plans to be executed"
	exit 1
fi

# Build all requested bob recipes.
# If the the build process fails, abort the entire test run.
if ! bob ${bob_color} dev ${bob_args} ${sandbox} "${!runner[@]}" 2>&1 | tee >(sed -E "s/$ansi_rgx//g" >> $artifacts_dir/bob.log); then
	echo "ERROR - bob build failure"
	exit 1
fi

# Arch specific queries
if search_prefix "arm64-" "${!runner[@]}"; then
	# Add required QEMU tools and devicetrees to path.
	qemu_path=${RECIPES}/$(bob query-path --fail -f '{dist}' ${sandbox} //devel::xilinx::qemu)/usr/bin
	dtb_path=${RECIPES}/$(bob query-path --fail -f '{dist}' ${sandbox} //devel::xilinx::qemu-devicetrees)

	export PATH=$qemu_path:$PATH
	export DTB_PATH=$dtb_path
fi

# The mulog*.py scripts are required to analyze dbgserver logs.
bob ${bob_color} dev \
	${bob_args} \
	${sandbox} \
	/x86-qemu-debug/muen::tools-mulog 2>&1 | tee >(sed -E "s/$ansi_rgx//g" >> $artifacts_dir/bob.log)
mulog_dir=${RECIPES}/$(bob query-path --fail -f '{dist}' ${sandbox} /x86-qemu-debug/muen::tools-mulog)
nci_defines+=( "-DMULOG_DIR=${mulog_dir}" )

# Setup nci plans including environment variables.
nci_plans=()

for r in "${!runner[@]}"; do
	# shellcheck disable=SC2206
	nci_plans+=( ${runner[${r}]} ) # we want shell whitespace expansion here
	arch="${r%%-*}"
	scenario="${r#${arch}-}"
	varname=$(echo ${scenario} | tr '[:lower:]' '[:upper:]' | tr '-' '_')_IMAGE_DIR
	varvalue="${RECIPES}/$(bob query-path --fail -f '{dist}' ${sandbox} //${r})"
	nci_defines+=( "-D${varname}=${varvalue}" )
done

ARGS+="-a $artifacts_dir"

$NCI run $ARGS \
	-c "${nci_plans[@]}" \
	"${nci_defines[@]}" \
	-DCONFIG_DIR="$SCRIPTDIR/nci-config"
