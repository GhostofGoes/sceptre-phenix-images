#!/bin/sh
# phenix image build script for the plain headless Ubuntu images. ubuntu.qc2
# (with scripts/atomic/ubuntu-user.sh) is the general-purpose guest of the
# helloworld topology (sceptre-phenix-topologies helloworld). miniccc.qc2 only
# runs miniccc, for the placeholder soar node of the wind plant soar topology
# (renewables/wind/plant/phenix-configs/soar). Both images get the release's
# -updates and -security pockets and are upgraded from them at build, so they
# ship with Ubuntu's security updates.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# debootstrap wrote one line, for the release pocket only, with the mirror and
# components the image was created with. Take the -updates and -security
# pockets from the same mirror, so a build with UBUNTU_MIRROR set uses only
# that mirror.
read -r kind mirror suite components < /etc/apt/sources.list
test "$kind" = deb
test "$suite" = "$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
test -n "$components"
cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $mirror
Suites: $suite $suite-updates $suite-security
Components: $components
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
echo '# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources' > /etc/apt/sources.list

apt-get update
# Keep the files the phenix base scripts changed: sshd_config, which permits
# root's SSH login, is a ucf file, not a dpkg conffile.
UCF_FORCE_CONFFOLD=1 apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
grep -qx 'PermitRootLogin yes' /etc/ssh/sshd_config
# The upgrade installs the -updates kernel next to the release kernel, and APT
# protects the newest two kernels from autoremove. Remove the release kernel,
# so the image keeps only the kernel grub boots.
apt-get -y -o APT::Protect-Kernels=false autoremove --purge
test "$(find /boot -maxdepth 1 -name 'vmlinuz-*' | wc -l)" -eq 1

# SSH listens from boot: noble's ssh.socket starts sshd on the first connection.
systemctl enable ssh.socket

# Experiment networks are often unrouted; do not hold the boot waiting for a
# network to come online.
systemctl mask systemd-networkd-wait-online.service

## Clean APT install
apt-get -y clean
