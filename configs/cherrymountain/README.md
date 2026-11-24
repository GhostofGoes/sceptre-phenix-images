# CherryMountain Brewery range images

This directory holds the stored `Image` configurations of the CherryMountain
Brewery range. The range is the `cherrymountain-brewery` topology of
[sceptre-phenix-topologies](https://github.com/GhostofGoes/sceptre-phenix-topologies/tree/feat-secret-topo/cherrymountain-brewery).
A topology is the phenix description of machines and networks.
Each file is a copy of the `phenix-images/<name>.yml` file of the topology at
commit `fb43c7f4ee7f8813aeffd600544b5ed38aa1cb08`.

The copy in the topology is the source. The lint hooks of the topology test the
configurations. The
[phenix-images/README.md](https://github.com/GhostofGoes/sceptre-phenix-topologies/blob/feat-secret-topo/cherrymountain-brewery/phenix-images/README.md)
of the topology says what each image holds and which versions it pins. Do not
edit a configuration here. Change it in the topology. Then copy it again and
update the commit above.

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
