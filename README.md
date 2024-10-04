Bob Muen-Recipes
================

This repo contains recipes to build muen based images with bob.

Prerequisites
=============

Bob: ATM a development version of bob is needed. See:
https://bob-build-tool.readthedocs.io/en/latest/installation.html#install-latest-development-version
for installation. (Maybe use a venv.)

Build
=====

`bob ls` lists all available to-level targets. Choose one of them and build it.
E.g: `bob dev demo-qemu-zcu102-multicore`

This will (depending on your build-machine) take some time and consume some
(~40GB) of disk space.

Run
===

Start the image in qemu using the runQemu script::

    contrib/runQemu.sh demo-qemu-zcu102-multicore

GNATStudio
==========

Use the gnatstudio project generator to setup gnatstudio environment:

 $ bob project -n gnatstudio demo-xilinx-zcu104-multicore//*arm64-kernel \
       --name muen_arm64_kernel --gpr kernel.gpr

Start gnatstudio (needs to be in PATH):
 $ ./projects/muen_arm64_kernel/start_gnatstudio.sh

More examples:

 $ bob project -n gnatstudio //muen::tools-mugends \
       --name mugends --gpr mugends \
       -S .*libmuxml.* -S .*libmutools.*
