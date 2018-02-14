#!/bin/bash

# Download void musl iso
xbps-install -yS wget
wget https://repo.voidlinux.eu/live/current/void-live-x86_64-musl-20171007.iso -P /srv/libvirt/vm/

# Then remove wget
xbps-remove -yR wget
