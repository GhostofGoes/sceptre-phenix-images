#!/bin/sh
# phenix image build script for the protonuke traffic generator guests of the
# wind plant topologies (sceptre-phenix-topologies renewables/wind/plant: base,
# hids, nids and soar), whose nuke-pns, nuke-pnc1, nuke-pnc2 and wtg-01..05
# nodes boot protonuke.qc2. After the build, the Makefile injects minimega's
# protonuke with 'phenix image inject-miniexe', which installs
# /usr/local/bin/protonuke and an enabled protonuke.service; the phenix
# protonuke app injects the service's /etc/default/protonuke (PROTONUKE_ARGS)
# at pre-start.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# Experiment networks are often unrouted; do not hold the boot waiting for a
# network to come online.
systemctl mask systemd-networkd-wait-online.service

# The unit inject-miniexe installs puts ConditionPathExists under [Service],
# where systemd ignores it, so a guest booted without the app's config would
# leave protonuke.service failed. Check the condition where systemd reads it,
# so such a guest skips the service instead.
install -d -m 0755 /etc/systemd/system/protonuke.service.d
cat > /etc/systemd/system/protonuke.service.d/condition.conf <<'EOF'
[Unit]
ConditionPathExists=/etc/default/protonuke
EOF

## Clean APT install
apt-get -y clean
