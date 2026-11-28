#!/usr/bin/env bash
# The cm-*.yml files in configs/cherrymountain are copies. Their source is the
# CherryMountain Brewery topology (the brew repository), at the commit that
# configs/cherrymountain/SOURCE names.
#
#   scripts/cherrymountain-recipes.sh check          fail if a copy differs from its source
#   scripts/cherrymountain-recipes.sh copy COMMIT    copy the files of COMMIT and record COMMIT
#
# The script fetches the commit from the repository that SOURCE names. Set
# CM_TOPOLOGY_DIR to a local clone that has the commit to work without a network.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/configs/cherrymountain"
source_file="$dir/SOURCE"

value() {
    sed -n "s/^$1=//p" "$source_file"
}

usage() {
    sed -n '2,10s/^# \{0,1\}//p' "$0" >&2
    exit 2
}

# Put the topology's image configs of commit $1 into directory $2.
fetch() {
    local commit=$1 out=$2 repo path clone
    repo=$(value repo)
    path=$(value path)
    clone=${CM_TOPOLOGY_DIR:-}
    if [ -z "$clone" ]; then
        clone="$out/clone"
        git init -q "$clone"
        git -C "$clone" remote add origin "$repo"
        # Without the blobs, the fetch is small. `git archive` then gets the
        # blobs of the one directory.
        git -C "$clone" config remote.origin.promisor true
        git -C "$clone" config remote.origin.partialclonefilter blob:none
        git -C "$clone" fetch -q --depth 1 --filter=blob:none origin "$commit"
    fi
    mkdir "$out/files"
    git -C "$clone" archive "$commit" "$path" | tar -x -C "$out/files" --strip-components="$(awk -F/ '{ print NF }' <<< "$path")"
}

names() {
    (cd "$1" && find . -maxdepth 1 -name 'cm-*.yml' -printf '%f\n' | sort)
}

[ $# -ge 1 ] || usage
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$1" in
    check)
        [ $# -eq 1 ] || usage
        commit=$(value commit)
        fetch "$commit" "$work"
        status=0
        while read -r name; do
            if [ ! -f "$work/files/$name" ]; then
                echo "configs/cherrymountain/$name: the topology has no such file at $commit" >&2
                status=1
            elif [ ! -f "$dir/$name" ]; then
                echo "configs/cherrymountain/$name: the topology has this file at $commit, and this directory does not" >&2
                status=1
            elif ! diff -u --label "topology $name" --label "configs/cherrymountain/$name" "$work/files/$name" "$dir/$name" >&2; then
                status=1
            fi
        done < <({ names "$dir"; names "$work/files"; } | sort -u)
        if [ "$status" -ne 0 ]; then
            echo "The copies differ from the topology at $commit. Change the files in the topology, and then run: scripts/cherrymountain-recipes.sh copy <commit>" >&2
        fi
        exit "$status"
        ;;
    copy)
        [ $# -eq 2 ] || usage
        commit=$2
        if ! [[ $commit =~ ^[0-9a-f]{40}$ ]]; then
            echo "COMMIT must be a full commit hash (40 hexadecimal characters)" >&2
            exit 2
        fi
        fetch "$commit" "$work"
        while read -r name; do
            if [ ! -f "$work/files/$name" ]; then
                echo "removed: $name (the topology no longer has it; remove its Makefile target too)"
                rm "$dir/$name"
            fi
        done < <(names "$dir")
        while read -r name; do
            if [ ! -f "$dir/$name" ]; then
                echo "new: $name (add a Makefile target and a workflow entry for it)"
            elif ! cmp -s "$work/files/$name" "$dir/$name"; then
                echo "changed: $name"
            fi
            cp "$work/files/$name" "$dir/$name"
        done < <(names "$work/files")
        sed -i "s/^commit=.*/commit=$commit/" "$source_file"
        ;;
    *)
        usage
        ;;
esac
