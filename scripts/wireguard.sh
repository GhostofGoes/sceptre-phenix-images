#!/bin/sh
# phenix image build script for the WireGuard nodes of the wind plant
# topologies (sceptre-phenix-topologies renewables/wind/plant base, hids, nids
# and soar: guard-cli and guard-jh), which replaces that topology's
# phenix-images/wireguard.yml. The phenix wireguard app injects wg0.conf into
# both nodes and, on guard-jh, a startup script that enables wg-quick@wg0;
# guard-jh routes the VPN clients to the plant networks. hids and soar also
# inject a Wazuh agent ossec.conf into guard-jh, so the agent is installed, but
# left disabled because no topology starts it.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# guard-jh forwards the 10.222.222.0/24 VPN subnet to the plant networks.
cat > /etc/sysctl.d/99-ip-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

# An agent must not be newer than the Wazuh manager it reports to (the
# wazuh-manager node of hids and soar), so the agent is pinned to the exact
# version the wazuh-manager recipe pins; change the two together. A weekly
# rebuild then cannot move the agent past the manager.
WAZUH_VERSION=4.14.9-1
# Wazuh's repository signing key, as Wazuh publishes it.
WAZUH_KEY_FINGERPRINT=0DCFCA5547B19D2A6099506096B3EE5F29111145

# add_key <name> <url> <fingerprint>: install an APT repository key, after
# checking its fingerprint.
add_key() {
    curl -fsSL -o "/etc/apt/keyrings/$1.asc" "$2"
    install -d -m 0700 /tmp/key-gnupg
    test "$(gpg --homedir /tmp/key-gnupg --show-keys --with-colons "/etc/apt/keyrings/$1.asc" | awk -F: '$1 == "pub" { getline; print $10 }')" = "$3"
    rm -rf /tmp/key-gnupg
}

install -d -m 0755 /etc/apt/keyrings
add_key wazuh https://packages.wazuh.com/key/GPG-KEY-WAZUH "$WAZUH_KEY_FINGERPRINT"

cat > /etc/apt/sources.list.d/wazuh.sources <<'EOF'
Types: deb
URIs: https://packages.wazuh.com/4.x/apt/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/wazuh.asc
EOF
# One pin per preferences file: phenix drops blank lines from build scripts, so
# a second stanza here would merge into this record.
cat > /etc/apt/preferences.d/wazuh-agent <<EOF
Package: wazuh-agent
Pin: version ${WAZUH_VERSION}
Pin-Priority: 1001
EOF

apt-get update
apt-get install -y wazuh-agent
test "$(dpkg-query -W -f '${Version}' wazuh-agent)" = "$WAZUH_VERSION"

# The package does not enable its service. Without a manager address (the
# packaged ossec.conf holds a MANAGER_IP placeholder) the agent cannot start,
# so a topology that wants it injects its ossec.conf and starts the service.
test "$(systemctl is-enabled wazuh-agent.service)" = disabled

# Experiment networks are often unrouted; do not hold the boot waiting for a
# network to come online.
systemctl mask systemd-networkd-wait-online.service

## Clean APT install
apt-get -y clean
