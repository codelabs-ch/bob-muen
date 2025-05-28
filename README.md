Bob Muen-Recipes
================

This repo contains recipes to build Muen based images with bob.

Prerequisites
=============

Muen uses the Bob Build Tool (https://bobbuildtool.dev/) as its build system.

See Bob's documentation about how to install the tool and its usage:
https://bob-build-tool.readthedocs.io/en/latest/index.html

Build
=====

`bob ls` lists all available top-level targets (i.e. root recipes), `bob layers
update` fetches all configured layers. Execute the following commands to e.g.
build the arm64 minimal demo system in debug mode:

    $ bob layers update
    $ bob dev arm64-qemu-zcu102-minimal-debug

This will (depending on your build-machine) take some time and consume some
(~40GB) of disk space.

Run
===

Start the image in qemu using the runQemu script::

    $ contrib/runQemu_arm64.sh arm64-qemu-zcu102-minimal-debug

GNATStudio
==========

Use the gnatstudio project generator to setup gnatstudio environment:

    $ bob dev arm64-xilinx-zcu104-multicore-debug//*arm64-kernel-debug
    $ bob project -n gnatstudio \
          arm64-xilinx-zcu104-multicore-debug//*arm64-kernel-debug \
          --name muen_arm64_kernel \
          --gpr kernel.gpr

Start `gnatstudio` (needs to be in PATH):

    $ ./projects/muen_arm64_kernel/start_gnatstudio.sh

More examples:

    $ bob dev //muen::tools-libmuxml-dev \
          //muen::tools-libmutools-dev \
          //muen::tools-mugends
    $ bob project -n gnatstudio //muen::tools-mugends \
          --name mugends --gpr mugends \
          -S .*libmuxml.* -S .*libmutools.*
