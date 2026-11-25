# CherryMountain Brewery range images

This directory holds the stored `Image` configurations of the CherryMountain
Brewery range. The range is the `cherrymountain-brewery` topology of
[sceptre-phenix-topologies](https://github.com/GhostofGoes/sceptre-phenix-topologies/tree/feat-secret-topo/cherrymountain-brewery).
A topology is the phenix description of machines and networks.
Each `cm-*.yml` file is a copy of the `phenix-images/<name>.yml` file of the
topology. The file [SOURCE](SOURCE) names the repository, the directory, and
the commit of the copies.

The copy in the topology is the source. The lint hooks of the topology test the
configurations. The
[phenix-images/README.md](https://github.com/GhostofGoes/sceptre-phenix-topologies/blob/feat-secret-topo/cherrymountain-brewery/phenix-images/README.md)
of the topology says what each image holds and which versions it pins.

Do not edit a configuration here. To change one:

1. Change the file in the topology, and push the commit to GitHub.
2. Run `scripts/cherrymountain-recipes.sh copy <commit>` in this repository,
   with the full hash of that commit. The script copies the files and writes
   the commit into `SOURCE`.
3. If the script reports a new file, add a Makefile target and a workflow
   entry for it.

The `cherrymountain-recipes` job of the
[lint workflow](../../.github/workflows/lint.yml) runs
`scripts/cherrymountain-recipes.sh check`. The job fails when a copy differs
from the topology at the commit in `SOURCE`. To run the check without a
network, set `CM_TOPOLOGY_DIR` to a local clone of the topology that has the
commit.

## Build

The Makefile has one target for each configuration. A target puts the
configuration into the phenix store (`phenix config create`), builds the image,
and injects `miniccc`:

```bash
make cm-sim
```

| Target | Disk | Notes |
| ------ | ---- | ----- |
| cm-sim | 16G | The build installs the simulation from the topology repository at the commit that `CM_REF` names in the configuration. That commit must be on GitHub |
| cm-otsim | 10G | |
| cm-openplc | 12G | |
| cm-fuxa | 12G | |
| cm-svc | 8G | |
| cm-svc-protonuke | 8G | This image is a copy of `cm-svc.qc2` with `protonuke` injected. If that file is missing, the target builds `cm-svc.qc2` first |
| cm-historian | 12G | |
| cm-desktop | 24G | The image has a GUI. The target also injects `protonuke` |
| cm-ews | 28G | The image has a GUI |
| cm-guacamole | 16G | |
| cm-wireguard | 8G | |
| cm-wazuh | 32G | |
| cm-malcolm | 64G | The build downloads 7.4 GB of container images |
| cm-sensor | 32G | The build downloads 2.6 GB of container images. The recipe is `cm-malcolm` with the images of Malcolm's `hedgehog` profile only |

`cm-desktop` and `cm-svc-protonuke` need a static `protonuke` binary at
`/phenix/protonuke` or next to the Makefile, as the `protonuke` recipe does.

The range also uses two recipes that are not specific to it. The first is
`vyos`. The second is `kali-purple`, which you build with the offline bundle of
parseus (`make kali-purple-bundle && make kali-purple PARSEUS_OFFLINE=1`). The range has
no internet access. Without the bundle, parseus never finishes its install.
The [image build workflow](../../.github/workflows/image-build.yml) builds
`kali-purple` that way.

## Limits

- Until now, no image from this directory booted in the range.
- A stored configuration names its own mirror. `UBUNTU_MIRROR=--mirror=<url>`
  works for these targets too. The Makefile writes the URL into a copy of the
  configuration.
- `phenix config create` replaces `${NAME}` and `${NAME:default}` in a
  configuration with a value from the environment of the phenix process. For
  that reason, the scripts in these configurations write a shell variable as
  `$NAME`.
