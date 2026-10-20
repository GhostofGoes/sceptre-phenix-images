#!/bin/sh
# phenix image build script for the headless guest the phenix end-to-end
# tests boot: the built-in apps, the user apps and the SCORCH components run
# their guest-side tools on it.

set -ex

# The SCORCH iperf component passes --idle-timeout, which iperf 3.10 added.
iperf3 --help | grep -q -- --idle-timeout

# Tests start these tools themselves.
systemctl disable snort.service iperf3.service || true

# Experiment networks are often unrouted; do not hold the boot waiting for a
# network to come online.
systemctl mask systemd-networkd-wait-online.service

# noble's ntp package is ntpsec, which reads /etc/ntpsec/ntp.conf, while the
# phenix ntp app injects /etc/ntp.conf. Keep the packaged configuration as the
# default and point ntpsec at /etc/ntp.conf.
if [ -f /etc/ntpsec/ntp.conf ] && [ ! -L /etc/ntpsec/ntp.conf ]; then
  mv /etc/ntpsec/ntp.conf /etc/ntp.conf
  ln -s /etc/ntp.conf /etc/ntpsec/ntp.conf
fi
