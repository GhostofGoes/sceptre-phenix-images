#!/bin/sh
# phenix image build script for the Kali image (kali-tools-top10, mingui
# variant): it makes Firefox accept Mozilla's Terms of Use.

set -ex

export DEBIAN_FRONTEND=noninteractive

# The mingui variant and kali-tools-top10 do not install jq. phenix cleans the
# apt cache before this script runs, so clean the jq downloads here.
if ! command -v jq >/dev/null 2>&1; then
    apt-get update
    apt-get install -y jq
    apt-get clean
fi

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
