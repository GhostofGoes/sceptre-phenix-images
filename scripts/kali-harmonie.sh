#!/bin/sh
# phenix image build script for a customized Kali Linux image for the HARMONIE-SPS LDRD

set -x

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y scapy python3-pip python3-all python3-dev python3-doc python3-venv python3-crcmod python3-wheel python3-setuptools pybind11-dev python3-pybind11 cmake gcc
# Kali's python3 is externally managed (PEP 668), so pip needs explicit
# permission to install into it. pyopendnp3 is not installed: its last release
# (0.1.0) vendors a pybind11 that does not compile against Python 3.11 or newer.
pip3 install --break-system-packages helics python-dateutil elasticsearch~=7.17

apt-get install -y firefox-esr kali-desktop-xfce kali-linux-default tcpdump nmap wireshark jq kali-grant-root dos2unix zip unzip tree nano arping

# Firefox 138 and later can open a Terms of Use dialog over the page at first
# launch. The SkipTermsOfUse policy (Firefox ESR 140 and later) accepts
# Mozilla's Terms of Use for the image's users, so Firefox does not show the
# dialog. When /etc/firefox/policies/policies.json exists, Firefox ignores the
# policies.json in its distribution directory, so the file starts from the one
# that Kali's kali-defaults-desktop package installs there.
mkdir -p /etc/firefox/policies
if [ -f /usr/share/firefox-esr/distribution/policies.json ]; then
    jq '.policies.SkipTermsOfUse = true' /usr/share/firefox-esr/distribution/policies.json > /etc/firefox/policies/policies.json
else
    echo '{"policies": {"SkipTermsOfUse": true}}' > /etc/firefox/policies/policies.json
fi
test "$(jq '.policies.SkipTermsOfUse' /etc/firefox/policies/policies.json)" = true || exit 1

# Kali Linux uses ntpsec (a hardened fork of NTP) instead of ntp, and comes installed with it by default.
# This is problematic from a SCEPTRE perspective, since the ntp app just assumes everything uses NTP, and
# injects /etc/ntp.conf on all Linux systems. To work around this, make ntpsec's configuration a symlink
# to /etc/ntp.conf, so it uses the NTP configuration injected by SCEPTRE.
mv /etc/ntpsec/ntp.conf /etc/ntpsec/ntp.conf.bak
ln -s /etc/ntp.conf /etc/ntpsec/ntp.conf
systemctl enable ntpsec

dpkg-reconfigure kali-grant-root

echo "root:toor" | chpasswd
