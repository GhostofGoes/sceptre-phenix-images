#!/bin/sh
# phenix image build script for the wazuh-manager node of the wind plant
# topology's hids, nids and soar experiments (sceptre-phenix-topologies
# renewables/wind/plant). The topology injects nothing into this node, so the
# image holds all of its configuration: a Wazuh manager that takes agent events
# on port 1514 over TCP and UDP and enrolls agents on port 1515, Filebeat
# shipping the manager's alerts to a single-node Elasticsearch 8, and that
# Elasticsearch listening on port 9200 with security off for the topology's
# other clients (the ids node's Filebeat and the test harness).

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# The topology's agents are Wazuh 4.2.5, which a newer 4.x manager accepts. The
# ids node's Filebeat is 8.x (8.19.23 in the zeek recipe; the legacy image's
# 8.1.2 refuses an Elasticsearch older than itself), so the sink is
# Elasticsearch 8, and Filebeat here is the same release. The versions are
# exact, so a weekly rebuild cannot move to an untested one.
WAZUH_VERSION=4.14.9-1
ELASTIC_VERSION=8.19.23
# Wazuh's index template for its alerts, at the manager's release tag.
WAZUH_TEMPLATE_URL=https://raw.githubusercontent.com/wazuh/wazuh/v4.14.9/extensions/elasticsearch/7.x/wazuh-template.json
WAZUH_TEMPLATE_SHA256=b2d182f49cc68957849e77fd2d79528fd2273ebaec1106c9661c9e320577a089
# The repositories' signing keys, as Wazuh and Elastic publish them.
WAZUH_KEY_FINGERPRINT=0DCFCA5547B19D2A6099506096B3EE5F29111145
ELASTIC_KEY_FINGERPRINT=46095ACC8548582C1A2699A9D27D666CD88E42B4
# Elasticsearch shares the guest with the manager, and the topologies' CI
# runner scales this node down to about 3 GB of memory.
ELASTIC_HEAP=768m

# add_key <name> <url> <fingerprint>: install an APT repository key, after
# checking its fingerprint.
add_key() {
    curl -fsSL -o "/etc/apt/keyrings/$1.asc" "$2"
    install -d -m 0700 /tmp/key-gnupg
    test "$(gpg --homedir /tmp/key-gnupg --show-keys --with-colons "/etc/apt/keyrings/$1.asc" | awk -F: '$1 == "pub" { getline; print $10 }')" = "$3"
    rm -rf /tmp/key-gnupg
}

# pin <package> <version>: hold a package at one version. One file per pin:
# phenix drops blank lines from build scripts, which would merge two stanzas of
# one file into a single record.
pin() {
    printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n' "$1" "$2" > "/etc/apt/preferences.d/$1"
}

install -d -m 0755 /etc/apt/keyrings
add_key wazuh https://packages.wazuh.com/key/GPG-KEY-WAZUH "$WAZUH_KEY_FINGERPRINT"
add_key elastic https://artifacts.elastic.co/GPG-KEY-elasticsearch "$ELASTIC_KEY_FINGERPRINT"

cat > /etc/apt/sources.list.d/wazuh.sources <<'EOF'
Types: deb
URIs: https://packages.wazuh.com/4.x/apt/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/wazuh.asc
EOF
cat > /etc/apt/sources.list.d/elastic-8.x.sources <<'EOF'
Types: deb
URIs: https://artifacts.elastic.co/packages/8.x/apt
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/elastic.asc
EOF
# Wazuh's repository also has a filebeat (the 7.10.2 OSS build Wazuh pairs with
# its OpenSearch-based indexer); the pin selects Elastic's.
pin wazuh-manager "$WAZUH_VERSION"
pin elasticsearch "$ELASTIC_VERSION"
pin filebeat "$ELASTIC_VERSION"

apt-get update
# Elasticsearch's package turns on TLS and authentication at install and prints
# the elastic password it generates; keep that line out of the build log.
status=0
apt-get install -y wazuh-manager elasticsearch filebeat > /tmp/apt-install.log 2>&1 || status=$?
sed '/generated password/d' /tmp/apt-install.log
rm -f /tmp/apt-install.log
test "$status" -eq 0
test "$(dpkg-query -W -f '${Version}' wazuh-manager)" = "$WAZUH_VERSION"
test "$(dpkg-query -W -f '${Version}' elasticsearch)" = "$ELASTIC_VERSION"
test "$(dpkg-query -W -f '${Version}' filebeat)" = "$ELASTIC_VERSION"

# ------------------------------------------------------------------------------
# Wazuh manager
# The package generates ossec.conf at install; change only what the topology
# needs and check each change.
# ------------------------------------------------------------------------------

conf=/var/ossec/etc/ossec.conf
# The topology's agent ossec.conf sends events over UDP; the manager listens on
# TCP only by default.
sed -i '/<remote>/,/<\/remote>/s|<protocol>tcp</protocol>|<protocol>tcp,udp</protocol>|' "$conf"
# The indexer client (TLS to https://0.0.0.0:9200) and vulnerability detection
# work only with the Wazuh indexer, which this image replaces with a plain-HTTP
# Elasticsearch; the update check needs the internet, which experiments lack.
sed -i '/<indexer>/,/<\/indexer>/s|<enabled>yes</enabled>|<enabled>no</enabled>|' "$conf"
sed -i '/<vulnerability-detection>/,/<\/vulnerability-detection>/s|<enabled>yes</enabled>|<enabled>no</enabled>|' "$conf"
sed -i 's|<update_check>yes</update_check>|<update_check>no</update_check>|' "$conf"
chown root:wazuh "$conf"
chmod 0660 "$conf"

# section <name>: print the <name> sections of the manager's configuration.
section() {
    sed -n "/<$1>/,/<\/$1>/p" "$conf"
}
for name in remote auth indexer vulnerability-detection; do
    test "$(grep -c "<$name>" "$conf")" -eq 1
done
test "$(section remote | grep -c -e '<connection>secure</connection>' -e '<port>1514</port>' -e '<protocol>tcp,udp</protocol>')" -eq 3
test "$(section auth | grep -c -e '<disabled>no</disabled>' -e '<port>1515</port>' -e '<use_password>no</use_password>')" -eq 3
test "$(section indexer | grep -c '<enabled>no</enabled>')" -eq 1
test "$(section vulnerability-detection | grep -c '<enabled>no</enabled>')" -eq 1
grep -q '<update_check>no</update_check>' "$conf"

# Start after phenix has set the topology's host name, which the manager writes
# into every alert, and allow its daemons longer than the unit's 45 s to start
# while Elasticsearch starts beside them.
install -d -m 0755 /etc/systemd/system/wazuh-manager.service.d
cat > /etc/systemd/system/wazuh-manager.service.d/phenix.conf <<'EOF'
[Unit]
After=phenix.service
[Service]
TimeoutStartSec=300
EOF

# ------------------------------------------------------------------------------
# Elasticsearch
# A single node with security off, over the TLS settings the package generated,
# as the wind turbine topology runs it (scripts/grafana.sh). Experiments have no
# internet, so it does not try to download GeoIP databases either.
# ------------------------------------------------------------------------------

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
ingest.geoip.downloader.enabled: false
EOF
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms${ELASTIC_HEAP}
-Xmx${ELASTIC_HEAP}
EOF
chown root:elasticsearch /etc/elasticsearch/jvm.options.d/heap.options
chmod 0660 /etc/elasticsearch/jvm.options.d/heap.options

# ------------------------------------------------------------------------------
# Filebeat
# Wazuh's Filebeat module and configuration target the filebeat-oss 7.10.2 it
# pairs with the Wazuh indexer. Filebeat 8 reads alerts.json with its own
# filestream input instead, into Wazuh's 4.x alert indices.
# ------------------------------------------------------------------------------

# Wazuh's template is in Elasticsearch's legacy format, and Filebeat 8 loads a
# JSON template through the composable index template API, so it is converted.
curl -fsSL -o /tmp/wazuh-template.json "$WAZUH_TEMPLATE_URL"
echo "$WAZUH_TEMPLATE_SHA256  /tmp/wazuh-template.json" | sha256sum -c -
jq '{index_patterns, version, template: {settings, mappings}}' /tmp/wazuh-template.json > /etc/filebeat/wazuh-template.json
rm -f /tmp/wazuh-template.json
test "$(jq -r '.index_patterns[0]' /etc/filebeat/wazuh-template.json)" = 'wazuh-alerts-4.x-*'
test "$(jq -r '.template.settings["index.mapping.total_fields.limit"]' /etc/filebeat/wazuh-template.json)" = 10000

# Wazuh's template maps host as a keyword, while Filebeat adds a host object to
# every event, which Elasticsearch would reject; Wazuh's own ingest pipeline
# removes host, ecs and log, and so does this configuration.
cat > /etc/filebeat/filebeat.yml <<'EOF'
filebeat.inputs:
  - type: filestream
    id: wazuh-alerts
    paths:
      - /var/ossec/logs/alerts/alerts.json
    parsers:
      - ndjson:
          target: ""
          add_error_key: true
processors:
  - drop_fields:
      fields: ["host", "ecs", "log"]
      ignore_missing: true
output.elasticsearch:
  hosts: ["http://127.0.0.1:9200"]
  index: "wazuh-alerts-4.x-%{+yyyy.MM.dd}"
setup.ilm.enabled: false
setup.template.name: wazuh
setup.template.pattern: "wazuh-alerts-4.x-*"
setup.template.json.enabled: true
setup.template.json.path: /etc/filebeat/wazuh-template.json
setup.template.json.name: wazuh
setup.template.overwrite: true
logging.metrics.enabled: false
EOF
chown root:root /etc/filebeat/filebeat.yml
chmod 0600 /etc/filebeat/filebeat.yml
# Check the configuration without leaving Filebeat state (its instance ID) in
# the image.
filebeat test config -e --path.data /tmp/filebeat-test
rm -rf /tmp/filebeat-test

# ------------------------------------------------------------------------------
# Services
# ------------------------------------------------------------------------------

systemctl enable wazuh-manager.service elasticsearch.service filebeat.service

# Experiment networks are often unrouted; do not hold the boot waiting for a
# network to come online.
systemctl mask systemd-networkd-wait-online.service

## Clean APT install
apt-get -y clean
