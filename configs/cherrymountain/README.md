# CherryMountain Brewery range images

The stored `Image` configs of the CherryMountain Brewery range, the
`cherrymountain-brewery` topology of
[sceptre-phenix-topologies](https://github.com/GhostofGoes/sceptre-phenix-topologies/tree/feat-secret-topo/cherrymountain-brewery).
Each file is a copy of the topology's `phenix-images/<name>.yml` at commit
`fb43c7f4ee7f8813aeffd600544b5ed38aa1cb08`. The topology's copy is the source:
its lint hooks check the configs, and its
[phenix-images/README.md](https://github.com/GhostofGoes/sceptre-phenix-topologies/blob/feat-secret-topo/cherrymountain-brewery/phenix-images/README.md)
says what each image holds and which versions it pins. Do not edit a config
here. Change it in the topology, then copy it again and update the commit above.

## Build

The Makefile has one target per config. A target puts the config into the
phenix store (`phenix config create`), builds the image, and injects `miniccc`:

```bash
make cm-sim
```

| Target | Disk | Notes |
| ------ | ---- | ----- |
| cm-sim | 16G | Installs the simulation from the topology repository at the commit named by `CM_REF` in the config, so that commit must be on GitHub |
| cm-otsim | 10G | |
| cm-openplc | 12G | |
| cm-fuxa | 12G | |
| cm-svc | 8G | |
| cm-svc-protonuke | 8G | A copy of `cm-svc.qc2` with `protonuke` injected. The target builds `cm-svc.qc2` first when it is missing |
| cm-historian | 12G | |
| cm-desktop | 24G | GUI. The target also injects `protonuke` |
| cm-ews | 28G | GUI |
| cm-guacamole | 16G | |
| cm-wireguard | 8G | |
| cm-wazuh | 32G | |
| cm-malcolm | 64G | The build downloads 7.4 GB of container images |

`cm-desktop` and `cm-svc-protonuke` need a static `protonuke` binary at
`/phenix/protonuke` or next to the Makefile, as the `protonuke` recipe does.

The range also uses two recipes that are not specific to it: `vyos`, and
`kali-purple` built with parseus's offline bundle
(`make kali-purple-bundle && make kali-purple PARSEUS_OFFLINE=1`). The range has
no internet access, and without the bundle parseus never finishes its install.
The [image build workflow](../../.github/workflows/image-build.yml) builds
`kali-purple` that way.

## Limits

- No image here has booted in the range yet.
- A stored config names its own mirror. `UBUNTU_MIRROR=--mirror=<url>` works for
  these targets too: the Makefile writes the URL into a copy of the config.
- `phenix config create` replaces `${NAME}` and `${NAME:default}` in a config
  with a value from the environment of the phenix process. The scripts in these
  configs write a shell variable as `$NAME` for that reason.
