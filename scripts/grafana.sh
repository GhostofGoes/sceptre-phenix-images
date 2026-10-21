#!/bin/sh
# phenix image build script for the dashboard node of the wind turbine topology
# (sceptre-phenix-topologies renewables/wind/turbine), which replaces that
# topology's phenix-images/grafana.yml: Grafana and a single-node Elasticsearch
# 8, both started at boot, and Loki. Elasticsearch runs as the topology
# configures it (security off, listening on every address); the topology also
# injects Grafana's anonymous access,
# Elasticsearch datasource, dashboard provider and turbine dashboard; the OT-sim
# ground-truth module writes to Elasticsearch on port 9200.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# The turbine dashboard uses canvas panels (Grafana 10 or later) and its
# datasource targets Elasticsearch 8, from the 8.x repository below. Grafana's
# and Loki's major versions are pinned, and Elasticsearch to the release the
# other Elastic recipes use, so a weekly rebuild cannot move to an untested one.
GRAFANA_MAJOR=12
LOKI_MAJOR=3
ELASTIC_VERSION=8.19.23
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
# One file per pin: phenix drops blank lines from build scripts, which would
# merge two stanzas of one file into a single record.
cat > /etc/apt/preferences.d/grafana <<EOF
Package: grafana
Pin: version ${GRAFANA_MAJOR}.*
Pin-Priority: 1001
EOF
cat > /etc/apt/preferences.d/loki <<EOF
Package: loki
Pin: version ${LOKI_MAJOR}.*
Pin-Priority: 1001
EOF
cat > /etc/apt/preferences.d/elasticsearch <<EOF
Package: elasticsearch
Pin: version ${ELASTIC_VERSION}
Pin-Priority: 1001
EOF

apt-get update
# Elasticsearch's package turns on TLS and authentication at install and prints
# the elastic password it generates; keep that line out of the build log.
status=0
apt-get install -y grafana loki elasticsearch > /tmp/apt-install.log 2>&1 || status=$?
sed '/generated password/d' /tmp/apt-install.log
rm -f /tmp/apt-install.log
test "$status" -eq 0
test "$(dpkg-query -W -f '${Version}' grafana | cut -d. -f1)" = "$GRAFANA_MAJOR"
test "$(dpkg-query -W -f '${Version}' loki | cut -d. -f1)" = "$LOKI_MAJOR"
test "$(dpkg-query -W -f '${Version}' elasticsearch)" = "$ELASTIC_VERSION"

# Run Elasticsearch as the topology does, which injects this same config: a
# single node with security off, over the TLS settings the package generated.
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl:
  enabled: false
  keystore.path: certs/http.p12
xpack.security.transport.ssl:
  enabled: false
  verification_mode: certificate
  keystore.path: certs/transport.p12
  truststore.path: certs/transport.p12
network.host: 0.0.0.0
EOF

# The topology's dashboard provider reads its dashboard from here.
install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards

systemctl enable grafana-server.service elasticsearch.service

## Clean APT install
apt-get -y clean
