#!/bin/bash

# Install additional packages
echo "nameserver 8.8.8.8" > /etc/resolv.conf
xbps-install -y -S vim
