.PHONY: help check_clean bookworm kali kali-harmonie kali-purple kali-purple-bundle jammy noble ubuntu miniccc _miniccc_img bennu minirouter _minirouter_img protonuke _protonuke_img docker-hello-world ntp e2e vyos ubuntu-soaptools clean ot-sim grafana wireguard zeek wazuh-manager elasticsearch packetbeat caldera cm-sim cm-otsim cm-openplc cm-fuxa cm-svc cm-historian cm-desktop cm-ews cm-guacamole cm-wireguard cm-wazuh cm-malcolm cm-sensor cm-svc-protonuke lint install-dev update-actions

.ONESHELL: # for heredoc and exit
# With .ONESHELL a recipe is one shell script, so make only sees its last
# command's status: stop at the first failing command, or a failed build or
# miniccc injection followed by an echo would report success.
.SHELLFLAGS := -ec

# this addresses case of /phenix differing between host and container
WORKDIR ?= $(CURDIR)

PHENIX=docker exec -t phenix phenix
PHENIX_IMAGE_BUILD=$(PHENIX) image build -o $(WORKDIR) -c -x $(@) || exit 1
CHECK_IMAGE=if $(PHENIX) cfg list | grep Image | awk '{print $$6}' | grep "^$(@)$$" >/dev/null; then echo "\n\tphenix image already exists: '$(@)' -- run 'phenix image delete $(@)' first\n"; exit 1; fi
CHECK_TAR=if [ -f $(@).tar ]; then echo -n "Image rootfs tar archive already exists: '$(@).tar'. Are you sure you want to use it (no updates to release or packages)? [y/N] " && read ans && if [ $${ans:-N} != y ]; then exit 1; fi; fi
MINICCC=`if [ -f /phenix/miniccc ]; then echo /phenix/miniccc; else echo $(WORKDIR)/miniccc; fi`
INJECT_MINICCC=if test -f $(WORKDIR)/$(@).qc2; then $(PHENIX) image inject-miniexe $(MINICCC) $(WORKDIR)/$(@).qc2; echo "----- Injected miniccc into $(@).qc2 -----"; fi
# To disable compression, change below to 'COMPRESS='
COMPRESS=--compress
# Use different Ubuntu mirror, for example 'UBUNTU_MIRROR=--mirror="https://mirror.example.com/ubuntu/ubuntu"'
UBUNTU_MIRROR=
# tmp dir with plenty of space to use for vyos miniccc injection
# override with env var if needed
VYOSTMP?=$(WORKDIR)/vyostmp/
# Default directory for bennu source code to be located.
BENNU_DIR=

# Show this help
help:
	@cat $(MAKEFILE_LIST) | docker run --rm -i xanders/make-help

check_clean:
	@echo -n "Are you sure you want to delete [*.log *.qc2 *.tar *.vmdb]? [y/N] " && read ans && [ $${ans:-N} = y ]

##
## --------------------------------------- Vanilla image builds ---------------------------------------
##

# Build bookworm.qc2	-- Debian Bookworm, GUI
bookworm:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r bookworm -v mingui $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build kali.qc2		-- Kali, GUI
kali:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -P kali-tools-top10 -r kali-rolling -v mingui -s 80G -T $(WORKDIR)/scripts/kali.sh $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build kali-harmonie.qc2	-- Kali for HARMONIE-SPS LDRD, GUI
kali-harmonie:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -l main,non-free,contrib -r kali-rolling -v minbase -s 50G -T $(WORKDIR)/scripts/kali-harmonie.sh $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build kali-purple.qc2	-- Kali Purple + parseus + PEAT, GUI
# PARSEUS_OFFLINE=1 bakes parseus's offline bundle (container images included) into the image so first
# boot needs no network; stage it first with 'make kali-purple-bundle' on a docker host. Default: network install on first boot.
# PARSEUS_REPO / PARSEUS_REF / PARSEUS_INTEGRATIONS (make vars or env) are baked, shell-quoted, into a
# generated copy of the script, since docker exec does not carry them into the chroot build.
export PARSEUS_REPO PARSEUS_REF PARSEUS_INTEGRATIONS
KALI_PURPLE_SCRIPT=$(WORKDIR)/scripts/kali-purple.configured.sh
kali-purple:
	@if [ -n "$(PARSEUS_OFFLINE)" ] && [ ! -d "$(CURDIR)/overlays/parseus-bundle/opt/parseus-bundle" ]; then echo "\n\tPARSEUS_OFFLINE set but no bundle: run 'make kali-purple-bundle' first\n"; exit 1; fi
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@python3 -I -c 'import os,shlex,sys; sys.stdout.write("#!/bin/sh\n" + "".join("%s=%s\n" % (k, shlex.quote(os.environ.get(k, ""))) for k in ("PARSEUS_REPO","PARSEUS_REF","PARSEUS_INTEGRATIONS")) + open(sys.argv[1]).read().split("\n", 1)[1])' $(WORKDIR)/scripts/kali-purple.sh > $(KALI_PURPLE_SCRIPT)
	@$(PHENIX) image create -P kali-linux-headless $(if $(PARSEUS_OFFLINE),-O $(WORKDIR)/overlays/parseus-bundle) -T $(KALI_PURPLE_SCRIPT) -r kali-rolling -v mingui -s 80G $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Stage the parseus offline bundle (~2 GB of container images, amd64 unless DOCKER_PLATFORM=linux/arm64) into overlays/parseus-bundle; needs docker, git, make, python3 >= 3.11
kali-purple-bundle:
	@$(CURDIR)/scripts/parseus-bundle.sh $(CURDIR)/overlays/parseus-bundle

# Build jammy.qc2		-- Ubuntu Jammy, GUI
jammy:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r jammy -v mingui $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build noble.qc2		-- Ubuntu Noble, GUI
noble:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -v mingui $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build ubuntu.qc2		-- Ubuntu Noble, headless, ubuntu user, security updates (helloworld topology)
ubuntu:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -P ca-certificates,iputils-ping,less,nano,sudo -T $(WORKDIR)/scripts/atomic/ubuntu-user.sh,$(WORKDIR)/scripts/ubuntu.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build miniccc.qc2		-- Ubuntu Noble, headless, miniccc only, security updates (wind plant topologies)
miniccc: _miniccc_img

_miniccc_img: # use _img to avoid conflict with miniccc binary
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -T $(WORKDIR)/scripts/ubuntu.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)
	@mv -f $(WORKDIR)/$(@).qc2 $(WORKDIR)/miniccc.qc2

##
## ------------------------------------- Experiment image builds --------------------------------------
##

# Build bennu.qc2			-- Ubuntu Jammy, bennu, brash
bennu:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r jammy -O $(WORKDIR)/overlays/bennu,$(WORKDIR)/overlays/brash -T $(WORKDIR)/scripts/bennu.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build docker-hello-world.qc2	-- Ubuntu Noble, Docker hello-world
docker-hello-world:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -T $(WORKDIR)/scripts/atomic/docker.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build ot-sim.qc2          -- Ubuntu Focal, OTSim, Pandas, 
ot-sim:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r focal -T $(WORKDIR)/scripts/ot-sim.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build grafana.qc2		-- Ubuntu Noble, Grafana, Loki, Elasticsearch 8 (wind turbine dashboard node)
grafana:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -s 50G -P gpg -T $(WORKDIR)/scripts/grafana.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build wireguard.qc2		-- Ubuntu Noble, WireGuard tools, Wazuh agent 4.14.9 (wind plant VPN nodes)
wireguard:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -P wireguard-tools,iproute2,iputils-ping,tcpdump,gpg -T $(WORKDIR)/scripts/wireguard.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build zeek.qc2		-- Ubuntu Noble, Zeek LTS, Filebeat 8, Open vSwitch (wind plant ids node)
zeek:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -s 20G -P gpg,openvswitch-switch -T $(WORKDIR)/scripts/zeek.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build wazuh-manager.qc2	-- Ubuntu Noble, Wazuh manager 4.14, Elasticsearch 8, Filebeat 8 (wind plant manager node)
wazuh-manager:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -s 20G -P gpg,jq -T $(WORKDIR)/scripts/wazuh-manager.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build elasticsearch.qc2	-- Ubuntu Noble, Elasticsearch 8.19.23, Kibana 8.19.23, Firefox, GUI (soh packet capture server)
elasticsearch:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -v mingui -s 25G -P gpg -T $(WORKDIR)/scripts/elasticsearch.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build packetbeat.qc2		-- Ubuntu Noble, Packetbeat 8.19.23 (soh packet capture monitor)
packetbeat:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -P gpg -T $(WORKDIR)/scripts/packetbeat.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build ntp.qc2			-- Ubuntu Noble, chrony
ntp:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -P chrony $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build e2e.qc2			-- Ubuntu Noble, headless test guest for the phenix end-to-end tests
e2e:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -P ntp,socat,isc-dhcp-client,iputils-ping,iproute2,procps,iperf3,hping3,ettercap-text-only,snort,python3,netcat-openbsd,wireguard-tools -T $(WORKDIR)/scripts/e2e.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build vyos.qc2			-- VyOS rolling
vyos:
	@cd $(WORKDIR)/scripts/vyos/
	@VYOSTMP=$(VYOSTMP) ./build-vyos.sh -m $(MINICCC)
	@if command -v virt-sparsify >/dev/null 2>&1; then \
		echo "virt-sparsify found — creating sparse copy to $(WORKDIR)/vyos.qc2"; \
		virt-sparsify vyos.qc2 $(WORKDIR)/vyos.qc2 && rm -f vyos.qc2 || { echo "virt-sparsify failed — falling back to move"; mv vyos.qc2 $(WORKDIR); }; \
	else \
		echo "virt-sparsify not found — not sparsifying, moving vyos.qc2"; \
		mv vyos.qc2 $(WORKDIR); \
	fi

# Build minirouter.qc2 		-- Ubuntu Noble, minirouter
minirouter: _minirouter_img

_minirouter_img: # use _img to avoid conflict with minirouter binary
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create --scripts $(WORKDIR)/scripts/minirouter.sh -O $(WORKDIR)/overlays/minirouter -P dnsmasq,openvswitch-switch,bird,nano,iptables,nftables,isc-dhcp-client,isc-dhcp-common -r noble $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)
	if test -f $(WORKDIR)/$(@).qc2; then $(PHENIX) image inject-miniexe $(WORKDIR)/minirouter $(WORKDIR)/$(@).qc2; echo "----- Injected minirouter into $(@).qc2 -----"; fi
	@mv -f $(WORKDIR)/$(@).qc2 $(WORKDIR)/minirouter.qc2

# Build protonuke.qc2		-- Ubuntu Noble, minimega protonuke traffic generator (wind plant topologies)
protonuke: _protonuke_img

_protonuke_img: # use _img to avoid conflict with protonuke binary
	@if [ ! -f $(WORKDIR)/protonuke ]; then echo "\n\tprotonuke binary not found: '$(WORKDIR)/protonuke' -- build minimega's cmd/protonuke statically and put it there first\n"; exit 1; fi
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -T $(WORKDIR)/scripts/protonuke.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)
	@if test -f $(WORKDIR)/$(@).qc2; then $(PHENIX) image inject-miniexe $(WORKDIR)/protonuke $(WORKDIR)/$(@).qc2; echo "----- Injected protonuke into $(@).qc2 -----"; fi
	@mv -f $(WORKDIR)/$(@).qc2 $(WORKDIR)/protonuke.qc2

# Build ubuntu-soaptools.qc2	-- Ubuntu Jammy, soaptools
ubuntu-soaptools:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r jammy -v mingui -s 50G -T $(WORKDIR)/scripts/atomic/ubuntu-user.sh,$(WORKDIR)/scripts/soaptools.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build bennu-dev.qc2			-- Ubuntu Jammy, bennu-dev, bennu, brash, GUI
bennu-dev:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create --size 32G -r jammy -v mingui -O $(WORKDIR)/overlays/bennu-dev,$(WORKDIR)/overlays/bennu,$(WORKDIR)/overlays/brash -T $(WORKDIR)/scripts/bennu-dev.sh $(BENNU_DIR) $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build caldera.qc2		-- Ubuntu Noble, MITRE Caldera server, Firefox, GUI
caldera:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(PHENIX) image create -r noble -v mingui -s 20G -P git,gpg,python3-venv -T $(WORKDIR)/scripts/caldera.sh $(UBUNTU_MIRROR) $(COMPRESS) $(@)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

##
## ------------------------------- CherryMountain Brewery range image builds -------------------------------
##
## Ubuntu Noble images of the cherrymountain-brewery topology (sceptre-phenix-topologies), each built from its
## stored image config in configs/cherrymountain. See configs/cherrymountain/README.md.

# A stored image config (README, method 2) goes into the phenix store as it is, mirror included, so a
# UBUNTU_MIRROR=--mirror=<url> is written into a copy of the config first.
MIRROR_URL=$(subst ",,$(patsubst --mirror=%,%,$(UBUNTU_MIRROR)))
CONFIG_CREATE=config=$(1); if [ -n "$(MIRROR_URL)" ]; then sed 's|^  mirror: .*|  mirror: $(MIRROR_URL)|' $(1) > $(WORKDIR)/$(@).mirror.yml; config=$(WORKDIR)/$(@).mirror.yml; fi; $(PHENIX) config create $$config; rm -f $(WORKDIR)/$(@).mirror.yml
PROTONUKE=`if [ -f /phenix/protonuke ]; then echo /phenix/protonuke; else echo $(WORKDIR)/protonuke; fi`
INJECT_PROTONUKE=if test -f $(WORKDIR)/$(@).qc2; then $(PHENIX) image inject-miniexe $(PROTONUKE) $(WORKDIR)/$(@).qc2; echo "----- Injected protonuke into $(@).qc2 -----"; fi

# Build cm-sim.qc2		-- CherryMountain: HELICS broker and plant simulation federates
cm-sim:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-sim.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-otsim.qc2		-- CherryMountain: ot-sim field devices and BAS controllers
cm-otsim:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-otsim.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-openplc.qc2		-- CherryMountain: OpenPLC v4 runtime (the PLCs)
cm-openplc:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-openplc.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-fuxa.qc2		-- CherryMountain: FUXA SCADA server and HMI
cm-fuxa:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-fuxa.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-svc.qc2		-- CherryMountain: NTP, DNS, syslog relay, BACnet BBMD
cm-svc:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-svc.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-historian.qc2	-- CherryMountain: InfluxDB 2, Telegraf, Grafana, Mosquitto
cm-historian:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-historian.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-desktop.qc2		-- CherryMountain: workstation desktop and HMI kiosk, protonuke, GUI
cm-desktop:
	@if [ ! -f $(PROTONUKE) ]; then echo "\n\tprotonuke binary not found: '/phenix/protonuke' or '$(WORKDIR)/protonuke' -- build minimega's cmd/protonuke statically and put it there first\n"; exit 1; fi
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-desktop.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)
	@$(INJECT_PROTONUKE)

# Build cm-ews.qc2		-- CherryMountain: engineering workstation, OpenPLC Editor, GUI
cm-ews:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-ews.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-guacamole.qc2	-- CherryMountain: Guacamole jump host
cm-guacamole:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-guacamole.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-wireguard.qc2	-- CherryMountain: WireGuard gateway, Wazuh agent
cm-wireguard:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-wireguard.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-wazuh.qc2		-- CherryMountain: Wazuh manager, indexer, and dashboard
cm-wazuh:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-wazuh.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-malcolm.qc2		-- CherryMountain: Malcolm network sensor
cm-malcolm:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-malcolm.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-sensor.qc2		-- CherryMountain: site network sensor (Malcolm in its hedgehog profile)
cm-sensor:
	@$(CHECK_IMAGE)
	@$(CHECK_TAR)
	@$(call CONFIG_CREATE,$(WORKDIR)/configs/cherrymountain/cm-sensor.yml)
	@$(PHENIX_IMAGE_BUILD)
	@$(INJECT_MINICCC)

# Build cm-svc-protonuke.qc2	-- CherryMountain: cm-svc with protonuke (the internet traffic node); builds cm-svc.qc2 when it is missing
cm-svc-protonuke:
	@if [ ! -f $(PROTONUKE) ]; then echo "\n\tprotonuke binary not found: '/phenix/protonuke' or '$(WORKDIR)/protonuke' -- build minimega's cmd/protonuke statically and put it there first\n"; exit 1; fi
	@# The copy is built from $(WORKDIR)/configs/cherrymountain/cm-svc.yml, which makes that config an input of this recipe.
	@if [ ! -f $(WORKDIR)/cm-svc.qc2 ]; then $(MAKE) --no-print-directory cm-svc UBUNTU_MIRROR='$(UBUNTU_MIRROR)' WORKDIR='$(WORKDIR)'; fi
	@cp $(WORKDIR)/cm-svc.qc2 $(WORKDIR)/$(@).qc2
	@$(INJECT_PROTONUKE)

##
## ------------------------------------------ Administration ------------------------------------------
##

# Delete files [*.log *.qc2 *.tar *.vmdb]
clean: check_clean
	@echo "Deleting *.log *.qc2 *.tar *.vmdb..."
	rm -f *.log *.qc2 *.tar *.vmdb

##
## ------------------------------------------ Linting ------------------------------------------
##

# Run all prek hooks across the whole repository
lint:
	@command -v prek > /dev/null || { echo "Error: 'prek' not found. Run 'make install-dev' first."; exit 1; }
	@prek run --all-files

# Install local dev tooling (prek) and register git pre-commit hooks
install-dev:
	@command -v prek > /dev/null || pip install 'prek>=0.4.3'
	@prek install

update-actions:
	@echo "Updating pinned actions in GitHub workflows..."
	@docker run --rm -v $(CURDIR):/workflows mheap/pin-github-action .github/workflows/
