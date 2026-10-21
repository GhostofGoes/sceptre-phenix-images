#!/bin/sh
# phenix image build script for the monitors of the packet capture of phenix's
# state-of-health app (soh): packetCapture.packetBeatImage in the soap-legacy
# topology's soh scenario. It replaces phenix's built-in PHENIX-packetbeat
# image config: Packetbeat 8.19, started at boot with the packetbeat.yml soh
# injects. soh mirrors each captured interface to the monitor's second NIC,
# eth1 (phenix keeps vmdb2's net.ifnames=0 kernel parameter), and Packetbeat
# ships the flows it sees there to soh's Elastic server (elasticsearch.qc2).

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# The release soh's Elastic server (elasticsearch.qc2) runs.
ELASTIC_VERSION=8.19.23
# The repository's signing key, as Elastic publishes it.
ELASTIC_KEY_FINGERPRINT=46095ACC8548582C1A2699A9D27D666CD88E42B4

# add_key <name> <url> <fingerprint>: install an APT repository key, after
# checking its fingerprint.
add_key() {
    curl -fsSL -o "/etc/apt/keyrings/$1.asc" "$2"
    install -d -m 0700 /tmp/key-gnupg
    test "$(gpg --homedir /tmp/key-gnupg --show-keys --with-colons "/etc/apt/keyrings/$1.asc" | awk -F: '$1 == "pub" { getline; print $10 }')" = "$3"
    rm -rf /tmp/key-gnupg
}

install -d -m 0755 /etc/apt/keyrings
add_key elastic https://artifacts.elastic.co/GPG-KEY-elasticsearch "$ELASTIC_KEY_FINGERPRINT"

cat > /etc/apt/sources.list.d/elastic-8.x.sources <<'EOF'
Types: deb
URIs: https://artifacts.elastic.co/packages/8.x/apt
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/elastic.asc
EOF
cat > /etc/apt/preferences.d/packetbeat <<EOF
Package: packetbeat
Pin: version $ELASTIC_VERSION
Pin-Priority: 1001
EOF

apt-get update
# Packetbeat links libpcap statically and its service runs as root, so it
# needs no other package and no capabilities. soh's injected packetbeat.yml
# replaces the package's.
apt-get install -y packetbeat
test "$(dpkg-query -W -f '${Version}' packetbeat)" = "$ELASTIC_VERSION"

# Experiment networks are often unrouted, and the capture NIC has no address;
# do not hold the boot waiting for a network to come online.
systemctl mask systemd-networkd-wait-online.service

# Start once phenix's startup scripts have set the NICs up: the interfaces
# script takes eth1 down and up again, which ends a capture already running.
# Keep restarting: systemd's default limit stops a service for good after five
# failed starts in ten seconds. soh's packetbeat.yml also has Packetbeat load
# its Kibana dashboards before it captures, and Packetbeat exits while Kibana
# does not answer; the -E override skips that step, so capture starts at boot,
# and elasticsearch.qc2 loads the dashboards itself once Kibana answers.
install -d -m 0755 /etc/systemd/system/packetbeat.service.d
cat > /etc/systemd/system/packetbeat.service.d/phenix-soh.conf <<'EOF'
[Unit]
After=phenix.service
StartLimitIntervalSec=0
[Service]
Environment="BEAT_CONFIG_OPTS=-c /etc/packetbeat/packetbeat.yml -E setup.dashboards.enabled=false"
RestartSec=10
EOF

# Never start Packetbeat here; it starts at boot.
systemctl enable packetbeat.service

## Clean APT install
apt-get -y clean
