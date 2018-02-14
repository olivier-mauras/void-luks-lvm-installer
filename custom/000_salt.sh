#!/bin/bash

# Saltify machine
echo "nameserver 8.8.8.8" > /etc/resolv.conf
xbps-install -yS salt git

cd /srv
git clone https://git.mauras.ch/salt/void-desktop ./salt
cp ./salt/minion /etc/salt/minion

echo "[?] Please enter your user password"
read PASSWORD
salt-call --local state.apply pillar="{\"user_passwd\": \"${PASSWORD}\"}"
