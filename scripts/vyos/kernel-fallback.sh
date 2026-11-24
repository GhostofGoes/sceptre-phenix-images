#!/usr/bin/env bash
# Sourced by build-vyos.sh; tested by test-kernel-fallback.sh.

# vyos_toml_value <key> <defaults.toml>: the value of a top-level key, quoted or not.
vyos_toml_value() {
    sed -n "s/^$1 *= *[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\} *\$/\1/p" "$2"
}

# vyos_pin_kernel <defaults.toml> <Packages list>
#
# vyos-build installs linux-image-<kernel_version>-<kernel_revision>-vyos
# (older vyos-build without kernel_revision: linux-image-<kernel_version>-vyos).
# If that package is not in the VyOS mirror's Packages list, point
# defaults.toml at the newest kernel the mirror does have, splitting its
# version and revision. vyos-build appends the revision, so a mirror kernel
# without one cannot stand in for a config that has one. An empty list (mirror
# unreachable) changes nothing.
vyos_pin_kernel() {
    local toml=$1 list=$2 version revision want available pattern
    [ -n "$list" ] || return 0

    version=$(vyos_toml_value kernel_version "$toml")
    revision=$(vyos_toml_value kernel_revision "$toml")
    want=$version${revision:+-$revision}
    grep -Fxq "Package: linux-image-${want}-vyos" <<< "$list" && return 0

    pattern='^linux-image-[0-9].*-vyos$'
    [ -z "$revision" ] || pattern='^linux-image-[0-9][^-]*-[0-9]+-vyos$'
    available=$(awk -F': ' -v pattern="$pattern" '$1=="Package" && $2 ~ pattern { sub(/^linux-image-/, "", $2); sub(/-vyos$/, "", $2); print $2 }' <<< "$list" | sort -V | tail -n1)
    [ -n "$available" ] || return 0

    echo "WARNING: Kernel ${want} not found in VyOS repository; using available ${available}"
    if [ -n "$revision" ]; then
        sed -i -e "s/^kernel_version *=.*/kernel_version = \"${available%-*}\"/" \
            -e "s/^kernel_revision *=.*/kernel_revision = \"${available##*-}\"/" "$toml"
    else
        sed -i "s/^kernel_version *=.*/kernel_version = \"${available}\"/" "$toml"
    fi
}
