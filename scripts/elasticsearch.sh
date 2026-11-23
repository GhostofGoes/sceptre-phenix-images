#!/bin/sh
# phenix image build script for the Elastic server of the packet capture of
# phenix's state-of-health app (soh): packetCapture.elasticImage in the
# soap-legacy topology's soh scenario. It replaces phenix's built-in
# PHENIX-elasticsearch image config: Elasticsearch and Kibana 8.19, started at
# boot; the query-flows.sh soh runs over C2; Packetbeat's Kibana dashboards;
# and Firefox on Kibana in root's desktop session, for the VM's VNC console.
# soh injects an elasticsearch.yml and a kibana.yml written for Elastic 7,
# which Elastic 8 refuses; the systemd drop-ins below make both work, and keep
# working with templates that turn security off and drop the removed settings.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# The latest 8.x release. Kibana refuses an older Elasticsearch, and
# Packetbeat's dashboards are made for its own Kibana, so all three packages,
# and the soh monitors' Packetbeat (packetbeat.qc2), are pinned to this one
# release.
ELASTIC_VERSION=8.19.23
# The repositories' signing keys, as Elastic and Mozilla publish them.
ELASTIC_KEY_FINGERPRINT=46095ACC8548582C1A2699A9D27D666CD88E42B4
MOZILLA_KEY_FINGERPRINT=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

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
add_key packages.mozilla.org https://packages.mozilla.org/apt/repo-signing-key.gpg "$MOZILLA_KEY_FINGERPRINT"

cat > /etc/apt/sources.list.d/elastic-8.x.sources <<'EOF'
Types: deb
URIs: https://artifacts.elastic.co/packages/8.x/apt
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/elastic.asc
EOF
cat > /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
# One file per pin: phenix drops blank lines from build scripts, which would
# merge two stanzas of one file into a single record.
for package in elasticsearch kibana packetbeat; do
    cat > "/etc/apt/preferences.d/$package" <<EOF
Package: $package
Pin: version $ELASTIC_VERSION
Pin-Priority: 1001
EOF
done
# Ubuntu's firefox package only installs the Firefox snap, which it skips in a
# chroot. Mozilla's repository is pinned above Ubuntu's, so its build replaces
# Ubuntu's package, which apt counts as a downgrade from 1:1snap1.
cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

apt-get update
# Elasticsearch's package turns on TLS and authentication at install and prints
# the elastic password it generates; keep that line out of the build log.
# Packetbeat is installed for its Kibana dashboards only.
status=0
apt-get install -y elasticsearch kibana packetbeat > /tmp/apt-install.log 2>&1 || status=$?
sed '/generated password/d' /tmp/apt-install.log
rm -f /tmp/apt-install.log
test "$status" -eq 0
for package in elasticsearch kibana packetbeat; do
    test "$(dpkg-query -W -f '${Version}' "$package")" = "$ELASTIC_VERSION"
done
apt-get install -y --allow-downgrades -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" firefox
# The autostart entry below runs `firefox`, which must be Mozilla's build, not
# the snap wrapper.
test "$(readlink -f "$(command -v firefox)")" = /usr/lib/firefox/firefox

# Experiment networks are often unrouted; do not hold the boot waiting for a
# network to come online, which Elasticsearch and Kibana are ordered after.
systemctl mask systemd-networkd-wait-online.service

# ------------------------------------------------------------------------------
# Elasticsearch
# ------------------------------------------------------------------------------

# Undo the install's security auto-configuration. soh and Packetbeat use plain
# HTTP without credentials, and Elasticsearch refuses to start while its
# keystore holds the passwords of TLS keystores that elasticsearch.yml does not
# configure, which is the case with the file soh injects. A new keystore holds
# only its seed.
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore
ES_PATH_CONF=/etc/elasticsearch /usr/share/elasticsearch/bin/elasticsearch-keystore create
chown root:elasticsearch /etc/elasticsearch/elasticsearch.keystore
chmod 0660 /etc/elasticsearch/elasticsearch.keystore
test "$(ES_PATH_CONF=/etc/elasticsearch /usr/share/elasticsearch/bin/elasticsearch-keystore list)" = keystore.seed

# soh replaces this file. Booted without soh, the image runs a single node with
# security off. minimega's disk inject writes over the file and keeps its owner
# and mode, which must let Elasticsearch read it: a file the inject created
# would be root's alone.
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF
chown root:elasticsearch /etc/elasticsearch/elasticsearch.yml
chmod 0660 /etc/elasticsearch/elasticsearch.yml

# soh's server VM has 4096 MB by default for Elasticsearch, Kibana and the
# desktop; Elasticsearch would size its heap to half of it. soh does not inject
# this directory.
cat > /etc/elasticsearch/jvm.options.d/phenix-heap.options <<'EOF'
-Xms1g
-Xmx1g
EOF
chown root:elasticsearch /etc/elasticsearch/jvm.options.d/phenix-heap.options
chmod 0660 /etc/elasticsearch/jvm.options.d/phenix-heap.options

# Settings on the command line override elasticsearch.yml, so these hold over
# the file soh injects: security off, and no GeoIP database downloads, which
# need the internet. soh's file sets cluster.initial_master_nodes, which must
# not be combined with discovery.type single-node, so that stays out of here.
# Without --quiet, start-up errors also reach the journal. Starting after
# phenix's startup scripts gives Elasticsearch the experiment's addresses. When
# memory runs out, the kernel stops Kibana or Firefox before Elasticsearch,
# which soh reads its flows from.
install -d -m 0755 /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/phenix-soh.conf <<'EOF'
[Unit]
After=phenix.service
[Service]
OOMScoreAdjust=-500
ExecStart=
ExecStart=/usr/share/elasticsearch/bin/systemd-entrypoint -p ${PID_DIR}/elasticsearch.pid \
    -E xpack.security.enabled=false \
    -E xpack.security.http.ssl.enabled=false \
    -E xpack.security.transport.ssl.enabled=false \
    -E ingest.geoip.downloader.enabled=false
EOF

# Elasticsearch must start for the first time in the experiment, with the
# cluster and node names of the file soh injects.
test -z "$(ls -A /var/lib/elasticsearch)"

# soh's getFlows runs this over C2, with no shell and no arguments, and parses
# its stdout as one Elasticsearch search response. minimega puts a command's
# stderr ahead of its stdout in the response, so nothing may go to stderr. The
# request is the one phenix's built-in PHENIX-elasticsearch image sends. curl
# waits up to three minutes for Elasticsearch to start, within the five soh
# waits for the answer; --fail keeps the bodies of the error responses it
# retries out of stdout.
cat > /usr/local/bin/query-flows.sh <<'EOF'
#!/bin/sh
exec curl -fs --max-time 20 --retry 36 --retry-delay 5 --retry-max-time 180 --retry-connrefused \
    -H 'Content-Type: application/json' -X POST 'http://localhost:9200/packetbeat-*/_search' \
    -d '{"_source":["source.ip","source.bytes","destination.ip","destination.bytes"],"query":{"query_string":{"query":"type:flow AND network.type:ipv4"}},"size":10000}' \
    2>/dev/null
EOF
chmod 0755 /usr/local/bin/query-flows.sh

# ------------------------------------------------------------------------------
# Kibana
# ------------------------------------------------------------------------------

# soh replaces this file too, keeping its owner and mode in the same way.
cat > /etc/kibana/kibana.yml <<'EOF'
server.host: 0.0.0.0
server.port: 5601
elasticsearch.hosts: ["http://localhost:9200"]
EOF
chown root:kibana /etc/kibana/kibana.yml
chmod 0660 /etc/kibana/kibana.yml
# Cap Kibana's heap so Elasticsearch, Kibana and the desktop fit in soh's
# default 4096 MB.
echo '--max-old-space-size=1024' >> /etc/kibana/node.options

# Kibana 8 exits on settings that 8.0 removed, and the kibana.yml soh injects
# still sets three. This runs as root before every start and deletes them.
cat > /usr/local/sbin/phenix-kibana-config <<'EOF'
#!/bin/sh
set -e
conf=${1:-/etc/kibana/kibana.yml}
for key in kibana.index kibana.defaultAppId elasticsearch.startupTimeout; do
    pattern="^$(echo "$key" | sed 's/\./\\./g')[[:space:]]*:"
    if grep -q "$pattern" "$conf"; then
        sed -i "/$pattern/d" "$conf"
        echo "removed $key from $conf: Kibana 8 no longer accepts it"
    fi
done
chown root:kibana "$conf"
chmod 0660 "$conf"
EOF
chmod 0755 /usr/local/sbin/phenix-kibana-config
# Check it on those settings as soh writes them, next to ones Kibana 8 keeps.
printf '%s\n' 'server.port: 5601' 'kibana.index: ".kibana"' 'kibana.defaultAppId: home' \
    'elasticsearch.pingTimeout: 5000' 'elasticsearch.startupTimeout: 5000' > /tmp/kibana-check.yml
/usr/local/sbin/phenix-kibana-config /tmp/kibana-check.yml
test "$(cat /tmp/kibana-check.yml)" = "$(printf '%s\n' 'server.port: 5601' 'elasticsearch.pingTimeout: 5000')"
rm -f /tmp/kibana-check.yml

# Start after Elasticsearch answers, clean the injected kibana.yml first (as
# root: the + prefix), and keep restarting: the package's unit stops after
# three failures in a minute.
install -d -m 0755 /etc/systemd/system/kibana.service.d
cat > /etc/systemd/system/kibana.service.d/phenix-soh.conf <<'EOF'
[Unit]
After=elasticsearch.service
StartLimitIntervalSec=0
[Service]
ExecStartPre=+/usr/local/sbin/phenix-kibana-config
RestartSec=10
EOF

# The soh monitors (packetbeat.qc2) do not load Packetbeat's dashboards, so
# they capture without waiting for Kibana; this loads the dashboards and the
# packetbeat-* data view once Kibana answers. Packetbeat exits while Kibana
# does not answer, so it tries again every 15 seconds, for up to an hour.
cat > /usr/local/sbin/phenix-packetbeat-dashboards <<'EOF'
#!/bin/sh
tries=0
until /usr/bin/packetbeat setup --dashboards; do
    tries=$((tries + 1))
    if [ "$tries" -ge 240 ]; then
        echo "Kibana did not take Packetbeat's dashboards within an hour" >&2
        exit 1
    fi
    sleep 15
done
EOF
chmod 0755 /usr/local/sbin/phenix-packetbeat-dashboards
cat > /etc/systemd/system/phenix-packetbeat-dashboards.service <<'EOF'
[Unit]
Description=Load Packetbeat's Kibana dashboards for the soh packet capture
Wants=kibana.service
After=kibana.service
[Service]
Type=simple
ExecStart=/usr/local/sbin/phenix-packetbeat-dashboards
[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------------------------
# Firefox
# ------------------------------------------------------------------------------

# Firefox 138 and later open a Terms of Use dialog over the page at first
# launch. SkipTermsOfUse accepts Mozilla's Terms of Use for the image's users,
# so Firefox does not show the dialog over Kibana.
install -d -m 0755 /etc/firefox/policies /root/.config/autostart
cat > /etc/firefox/policies/policies.json <<'EOF'
{"policies": {"DisableAppUpdate": true, "DisableTelemetry": true, "DontCheckDefaultBrowser": true, "OverrideFirstRunPage": "", "OverridePostUpdatePage": "", "SkipTermsOfUse": true}}
EOF
cat > /usr/local/bin/phenix-kibana-browser <<'EOF'
#!/bin/sh
until curl -fs -o /dev/null --max-time 5 http://localhost:5601/api/status; do
    sleep 5
done
exec firefox http://localhost:5601/app/home
EOF
chmod 0755 /usr/local/bin/phenix-kibana-browser
cat > /root/.config/autostart/kibana.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Kibana
Exec=/usr/local/bin/phenix-kibana-browser
Terminal=false
EOF

# Never start a service here: Elasticsearch must find its data directory empty
# at the experiment's first boot. The server runs no Packetbeat of its own.
systemctl enable elasticsearch.service kibana.service phenix-packetbeat-dashboards.service

## Clean APT install
apt-get -y clean
