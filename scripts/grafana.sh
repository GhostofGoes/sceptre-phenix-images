#!/bin/sh
# phenix image build script for the dashboard node of the wind turbine topology
# (sceptre-phenix-topologies renewables/wind/turbine), which replaces that
# topology's phenix-images/grafana.yml: Grafana and a single-node Elasticsearch
# 8, both started at boot, and Loki. The topology injects Elasticsearch's config
# (security off, listening on every address) and Grafana's anonymous access,
# Elasticsearch datasource, dashboard provider and turbine dashboard; the OT-sim
# ground-truth module writes to Elasticsearch on port 9200.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# The turbine dashboard uses canvas panels (Grafana 10 or later) and its
# datasource targets Elasticsearch 8, from the 8.x repository below. The major
# versions are pinned so a weekly rebuild cannot move to an untested one.
GRAFANA_MAJOR=12
LOKI_MAJOR=3
# The repositories' signing keys, as Grafana Labs and Elastic publish them.
GRAFANA_KEY_FINGERPRINT=B53AE77BADB630A683046005963FA27710458545
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
add_key grafana https://apt.grafana.com/gpg.key "$GRAFANA_KEY_FINGERPRINT"
add_key elastic https://artifacts.elastic.co/GPG-KEY-elasticsearch "$ELASTIC_KEY_FINGERPRINT"

cat > /etc/apt/sources.list.d/grafana.sources <<'EOF'
Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/grafana.asc
EOF
cat > /etc/apt/sources.list.d/elastic-8.x.sources <<'EOF'
Types: deb
URIs: https://artifacts.elastic.co/packages/8.x/apt
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/elastic.asc
EOF
cat > /etc/apt/preferences.d/grafana <<EOF
Package: grafana
Pin: version ${GRAFANA_MAJOR}.*
Pin-Priority: 1001

Package: loki
Pin: version ${LOKI_MAJOR}.*
Pin-Priority: 1001
EOF

apt-get update
apt-get install -y grafana loki elasticsearch
test "$(dpkg-query -W -f '${Version}' grafana | cut -d. -f1)" = "$GRAFANA_MAJOR"

# The topology's dashboard provider reads its dashboard from here.
install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards

systemctl enable grafana-server.service elasticsearch.service

## Clean APT install
apt-get -y clean
