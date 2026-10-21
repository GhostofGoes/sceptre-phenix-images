#!/bin/sh
# phenix image build script for the MITRE Caldera server the phenix caldera
# app (sceptre-phenix-apps) boots and the SCORCH caldera component operates:
# Caldera in /opt/caldera, run by caldera.service from the conf/default.yml the
# app injects, and Mozilla's Firefox, which the app's autostart entry opens in
# root's desktop session.

set -ex

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
# Unlike --no-cache-dir, this also reaches the pip runs that build sdists.
export PIP_NO_CACHE_DIR=1

# Caldera 5.3.0 is tested on Python 3.9 to 3.12; noble's python3 is 3.12.
CALDERA_VERSION=5.3.0
CALDERA_COMMIT=b24f6e7a99cab19cbf417009bda9b9c6c81abc31
# The plugins the caldera app enables beyond Caldera's own, at the heads of the
# branches phenix's built-in PHENIX-caldera image config tracks (facts for
# modbus, main for the others).
DNP3_PLUGIN_COMMIT=50c5144aed8f748c61e267297d6ae374dd239e16
MODBUS_PLUGIN_COMMIT=c13c627295ca04df1df5d410ea3520f451905db8
OT_PLUGIN_COMMIT=3bae2b5df0a78773ad663fc5dcdeb840e0362455
PHENIX_PLUGIN_COMMIT=8cac44da2992efe285b36c60ad0bad4716e9876c
# The atomic plugin turns Atomic Red Team's tests into abilities when it has
# none, cloning the repository at that moment. The tests are ingested here, at
# the last commit before Caldera 5.3.0, so the server never needs the network.
ATOMIC_RED_TEAM_COMMIT=ffc50d59333fcb42761037f58d640e6a6c6db0f5
# Node.js only builds the web UI and is removed afterwards. Caldera 5.3.0's
# UI lock file installs with npm 10 (Node 22); npm 11 refuses it.
NODE_VERSION=22.23.3
NODE_SHA256=1084aa36196bba4c3a5e69a1ee388a6e4ff729dad09445fbcd434b28fe3c24af
# Mozilla's APT repository signing key, as Mozilla documents it.
MOZILLA_KEY_FINGERPRINT=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

# ------------------------------------------------------------------------------
# Firefox
# Ubuntu's firefox package only installs the Firefox snap, which it skips in a
# chroot, so it leaves a wrapper for a snap that is not there. Mozilla's own
# build reads the policies the caldera app writes to /etc/firefox/policies. Its
# repository is pinned above Ubuntu's, so it replaces Ubuntu's package, which
# apt counts as a downgrade from that package's 1:1snap1 version.
# ------------------------------------------------------------------------------

install -d -m 0755 /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/packages.mozilla.org.asc https://packages.mozilla.org/apt/repo-signing-key.gpg
install -d -m 0700 /tmp/caldera-gnupg
test "$(gpg --homedir /tmp/caldera-gnupg --show-keys --with-colons /etc/apt/keyrings/packages.mozilla.org.asc | awk -F: '$1 == "pub" { getline; print $10 }')" = "$MOZILLA_KEY_FINGERPRINT"
rm -rf /tmp/caldera-gnupg

cat > /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

apt-get update
apt-get install -y --allow-downgrades -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" firefox
apt-get -y clean

# The caldera app's autostart entry runs `firefox`, which must be Mozilla's
# build, not the snap wrapper.
test "$(readlink -f "$(command -v firefox)")" = /usr/lib/firefox/firefox
install -d -m 0755 /etc/firefox/policies /root/.config/autostart
# Firefox 138 and later open a Terms of Use dialog over the page at first
# launch. SkipTermsOfUse accepts Mozilla's Terms of Use for the image's users,
# so Firefox does not show the dialog over Caldera. The caldera app replaces
# this file with one that also sets SkipTermsOfUse, and adds a bookmark.
cat > /etc/firefox/policies/policies.json <<'EOF'
{"policies": {"SkipTermsOfUse": true}}
EOF

# ------------------------------------------------------------------------------
# Caldera
# ------------------------------------------------------------------------------

git clone --depth 1 --branch "$CALDERA_VERSION" --recurse-submodules --shallow-submodules https://github.com/mitre/caldera.git /opt/caldera
test "$(git -C /opt/caldera rev-parse HEAD)" = "$CALDERA_COMMIT"
cd /opt/caldera

# The caldera app's default config also enables the dnp3, modbus, ot and phenix
# plugins, which PHENIX-caldera adds from these repositories: DNP3, Modbus and
# OT abilities, and the phenix planner that the SCORCH caldera component runs
# operations with by default. They go in before the UI build, which bundles
# every plugin's views.
add_plugin() {
  git init -q "plugins/$1"
  git -C "plugins/$1" fetch -q --depth 1 "https://github.com/activeshadow/caldera-$1.git" "$2"
  git -C "plugins/$1" -c advice.detachedHead=false checkout -q FETCH_HEAD
}
add_plugin dnp3 "$DNP3_PLUGIN_COMMIT"
add_plugin modbus "$MODBUS_PLUGIN_COMMIT"
add_plugin ot "$OT_PLUGIN_COMMIT"
add_plugin phenix "$PHENIX_PLUGIN_COMMIT"
# The DNP3 and Modbus plugins also carry the sources of the payloads they ship
# prebuilt in payloads/ (330 MB for DNP3), which Caldera never reads.
rm -rf plugins/dnp3/src plugins/modbus/src

python3 -m venv /opt/caldera/venv
/opt/caldera/venv/bin/pip install -r requirements.txt

# Until the caldera app injects its own, the image runs Caldera's default.yml
# with the app's extra plugins enabled too, so the phenix planner is there.
/opt/caldera/venv/bin/python -c 'import yaml; c = yaml.safe_load(open("conf/default.yml")); c["plugins"] += ["dnp3", "modbus", "ot", "phenix"]; open("conf/default.yml", "w").write(yaml.safe_dump(c))'

# Build the web UI (plugins/magma) as `server.py --build` would, but with the
# exact packages of its lock file, so the server serves it without Node.js.
mkdir -p /tmp/caldera-node /tmp/caldera-ui
curl -fsSL -o /tmp/caldera-node.tar.gz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz"
echo "$NODE_SHA256  /tmp/caldera-node.tar.gz" | sha256sum -c -
tar -xzf /tmp/caldera-node.tar.gz -C /tmp/caldera-node --strip-components=1
(
  cd plugins/magma
  export PATH="/tmp/caldera-node/bin:$PATH" TMPDIR=/tmp/caldera-ui npm_config_cache=/tmp/caldera-npm npm_config_update_notifier=false
  npm ci --no-audit --no-fund
  npm run build
)
test -f plugins/magma/dist/index.html
rm -rf /tmp/caldera-node /tmp/caldera-node.tar.gz /tmp/caldera-npm /tmp/caldera-ui plugins/magma/node_modules

# Ingest the Atomic Red Team tests with the atomic plugin's own service, then
# drop the repository: the plugin keeps the abilities and payloads it copied.
git init -q plugins/atomic/data/atomic-red-team
git -C plugins/atomic/data/atomic-red-team fetch -q --depth 1 https://github.com/redcanaryco/atomic-red-team.git "$ATOMIC_RED_TEAM_COMMIT"
git -C plugins/atomic/data/atomic-red-team -c advice.detachedHead=false checkout -q FETCH_HEAD
/opt/caldera/venv/bin/python -c 'import asyncio; from plugins.atomic.app.atomic_svc import AtomicService; asyncio.run(AtomicService().populate_data_directory())'
test -n "$(ls plugins/atomic/data/abilities)"
rm -rf plugins/atomic/data/atomic-red-team

# Sandcat ships precompiled agents for Linux, Windows and macOS in
# plugins/sandcat/payloads, which the server serves from /file/download when Go
# is not installed to compile them on demand.
test -s plugins/sandcat/payloads/sandcat.go-linux
test -s plugins/sandcat/payloads/sandcat.go-windows

# Caldera needs no git metadata at runtime; its version is in app/version.py.
find /opt/caldera -name .git -prune -exec rm -rf {} +

# The caldera app injects facts and adversaries into these directories.
mkdir -p /opt/caldera/data/sources /opt/caldera/data/adversaries

cd /

# --insecure starts Caldera from conf/default.yml, which the caldera app
# injects with the users, API keys and contacts of the experiment; the image
# keeps Caldera's own default.yml (plus the plugins above) until then. SIGINT,
# which Caldera's container image stops it with too, lets it save its state
# before it exits.
cat > /etc/systemd/system/caldera.service <<'EOF'
[Unit]
Description=MITRE Caldera server
After=network.target phenix.service
[Service]
WorkingDirectory=/opt/caldera
Environment=NO_COLOR=1 PYTHONUNBUFFERED=1
ExecStart=/opt/caldera/venv/bin/python server.py --insecure
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl enable caldera.service
