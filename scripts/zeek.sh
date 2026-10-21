#!/bin/sh
# phenix image build script for the ids node of the wind plant nids and soar
# topologies (sceptre-phenix-topologies renewables/wind/plant), which replaces
# that topology's phenix-images/zeek.yml: Zeek LTS sniffing gre_sys under
# zeek.service, Filebeat 8 with its Zeek module, and Open vSwitch (tcpdump is
# one of the packages phenix adds to every image). The mirror app's setupOVS
# injects a startup script that adds an OVS bridge with a flow-based GRE port,
# whose gre_sys device receives the host's mirror of the ot VLAN. The topology
# injects Filebeat's filebeat.yml (output to Elasticsearch on wazuh-manager),
# Zeek's networks.cfg and a startup script that runs filebeat setup.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# Ubuntu noble has no Zeek package, so Zeek LTS comes from the OBS
# security:zeek repository. OBS keeps only the latest build of each package, so
# Zeek is pinned to its LTS line: a new line fails the build instead of being
# installed untested. Filebeat is the release the other Elastic recipes pin;
# its Zeek module is not in the Apache-licensed filebeat-oss package.
ZEEK_LTS=8.0
FILEBEAT_VERSION=8.19.23
# The repositories' signing keys, as OBS and Elastic publish them. The OBS key
# expires on 2026-12-02: after that date apt rejects the repository and the
# build fails until OBS publishes the key with a new expiry date (the
# fingerprint stays the same) or a new key whose fingerprint replaces this one.
ZEEK_KEY_FINGERPRINT=F9FA0223B56B116C363737EF5DA57BDD6DD785CA
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
add_key zeek https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/Release.key "$ZEEK_KEY_FINGERPRINT"
add_key elastic https://artifacts.elastic.co/GPG-KEY-elasticsearch "$ELASTIC_KEY_FINGERPRINT"

# The OBS repository is flat: an exact path as its suite, and no components.
cat > /etc/apt/sources.list.d/zeek.sources <<'EOF'
Types: deb
URIs: https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/
Suites: /
Signed-By: /etc/apt/keyrings/zeek.asc
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
cat > /etc/apt/preferences.d/zeek-lts-core <<EOF
Package: zeek-lts-core
Pin: version ${ZEEK_LTS}.*
Pin-Priority: 1001
EOF
cat > /etc/apt/preferences.d/zeekctl-lts <<EOF
Package: zeekctl-lts
Pin: version ${ZEEK_LTS}.*
Pin-Priority: 1001
EOF
cat > /etc/apt/preferences.d/filebeat <<EOF
Package: filebeat
Pin: version ${FILEBEAT_VERSION}
Pin-Priority: 1001
EOF

apt-get update
# Zeek and zeekctl only: the zeek-lts metapackage adds the development, Spicy
# and zkg packages (over 250 MB installed) that a sensor does not use, and
# zeekctl's recommended mail transport agent is not needed either. Filebeat's
# package prints no generated password (its postinst only reloads systemd), so
# unlike the Elasticsearch recipes its install output needs no filtering.
apt-get install -y --no-install-recommends zeek-lts-core zeekctl-lts filebeat
test "$(dpkg-query -W -f '${Version}' zeek-lts-core | cut -d. -f1,2)" = "$ZEEK_LTS"
test "$(dpkg-query -W -f '${Version}' zeekctl-lts | cut -d. -f1,2)" = "$ZEEK_LTS"
test "$(dpkg-query -W -f '${Version}' filebeat)" = "$FILEBEAT_VERSION"

# zeekctl deploy checks and installs the site policy and starts Zeek. Until the
# mirror app's OVS port creates gre_sys, Zeek cannot open the interface and the
# deploy fails, so the unit retries every 15 s.
cat > /etc/systemd/system/zeek.service <<'EOF'
[Unit]
Description=Zeek Network Security Monitoring
Wants=network-online.target
After=network-online.target
[Service]
Type=forking
ExecStart=/opt/zeek/bin/zeekctl deploy
ExecStop=/opt/zeek/bin/zeekctl stop
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
EOF

# Zeek runs standalone on the mirror's GRE device.
cat > /opt/zeek/etc/node.cfg <<'EOF'
# ZeekControl node configuration.
#
# This is a complete standalone configuration.
[zeek]
type=standalone
host=localhost
interface=gre_sys
EOF

# The old image's site policy, less its @load of tuning/defaults: Zeek 7.1
# removed that policy, whose settings are Zeek's defaults since 7.0.
cat > /opt/zeek/share/zeek/site/local.zeek <<'EOF'
##! Local site policy.
# Installation-wide salt value that is used in some digest hashes, e.g., for
# the creation of file IDs. Please change this to a hard to guess value.
redef digest_salt = "Please change this value.";
@load misc/loaded-scripts
@load misc/capture-loss
@load misc/stats
@load frameworks/software/vulnerable
@load frameworks/software/version-changes
@load-sigs frameworks/signatures/detect-windows-shells
@load protocols/ftp/software
@load protocols/smtp/software
@load protocols/ssh/software
@load protocols/http/software
@load protocols/dns/detect-external-names
@load protocols/ftp/detect
@load protocols/conn/known-hosts
@load protocols/conn/known-services
@load protocols/ssl/known-certs
@load protocols/ssl/validate-certs
@load protocols/ssl/log-hostcerts-only
@load protocols/ssh/geo-data
@load protocols/ssh/detect-bruteforcing
@load protocols/ssh/interesting-hostnames
@load protocols/http/detect-sqli
#### Network File Handling ####
@load frameworks/files/hash-all-files
@load frameworks/files/detect-MHR
@load policy/frameworks/notice/extend-email/hostnames
# Configure JSON logging output
@load policy/tuning/json-logs.zeek
EOF
# Fail the build if the site policy loads a script this Zeek does not ship.
(cd /tmp && /opt/zeek/bin/zeek -a /opt/zeek/share/zeek/site/local.zeek)

# Enable Filebeat's Zeek module as `filebeat modules enable zeek` does, by
# renaming its file, without running Filebeat here: that would store a beat
# UUID in /var/lib/filebeat that every guest would share. Every fileset reads
# the JSON log Zeek writes for it; signature is off, as in the old image.
test -f /usr/share/filebeat/module/zeek/module.yml
rm -f /etc/filebeat/modules.d/zeek.yml.disabled
cat > /etc/filebeat/modules.d/zeek.yml <<'EOF'
# All base logs for Zeek are enabled below to include Modbus and DNP3.
# Module: zeek
# Docs: https://www.elastic.co/docs/reference/beats/filebeat/filebeat-module-zeek
- module: zeek
  capture_loss:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/capture_loss.log"]
  connection:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/conn.log"]
  dce_rpc:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/dce_rpc.log"]
  dhcp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/dhcp.log"]
  dnp3:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/dnp3.log"]
  dns:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/dns.log"]
  dpd:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/dpd.log"]
  files:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/files.log"]
  ftp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/ftp.log"]
  http:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/http.log"]
  intel:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/intel.log"]
  irc:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/irc.log"]
  kerberos:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/kerberos.log"]
  modbus:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/modbus.log"]
  mysql:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/mysql.log"]
  notice:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/notice.log"]
  ntlm:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/ntlm.log"]
  ntp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/ntp.log"]
  ocsp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/ocsp.log"]
  pe:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/pe.log"]
  radius:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/radius.log"]
  rdp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/rdp.log"]
  rfb:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/rfb.log"]
  signature:
    enabled: false
    var.paths: ["/opt/zeek/logs/current/signature.log"]
  sip:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/sip.log"]
  smb_cmd:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/smb_cmd.log"]
  smb_files:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/smb_files.log"]
  smb_mapping:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/smb_mapping.log"]
  smtp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/smtp.log"]
  snmp:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/snmp.log"]
  socks:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/socks.log"]
  ssh:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/ssh.log"]
  ssl:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/ssl.log"]
  stats:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/stats.log"]
  syslog:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/syslog.log"]
  traceroute:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/traceroute.log"]
  tunnel:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/tunnel.log"]
  weird:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/weird.log"]
  x509:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/x509.log"]
EOF

# The packaged unit restarts Filebeat 100 ms after it exits, so five quick
# failures reach systemd's default start limit and stop the restarts; retry
# every 15 s instead, as the old image's unit did.
install -d -m 0755 /etc/systemd/system/filebeat.service.d
cat > /etc/systemd/system/filebeat.service.d/restart.conf <<'EOF'
[Service]
RestartSec=15
EOF

# Root's interactive shells find the Zeek tools; the Filebeat package already
# puts its filebeat wrapper on the PATH.
cat >> /root/.bashrc <<'EOF'
export PATH="$PATH:/opt/zeek/bin"
EOF

systemctl enable openvswitch-switch.service zeek.service filebeat.service

# Experiment networks are often unrouted, and zeek.service and filebeat.service
# wait for network-online.target; do not hold the boot waiting for a network to
# come online.
systemctl mask systemd-networkd-wait-online.service

## Clean APT install
apt-get -y clean
