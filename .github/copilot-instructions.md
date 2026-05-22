# Copilot Instructions for sonic-buildimage

## Project Overview

sonic-buildimage is the master build system for SONiC (Software for Open Networking in the Cloud). It produces ONIE-compatible network operating system installer images for network switches across multiple ASIC platforms (Broadcom, Mellanox/NVIDIA, Marvell, etc.). This is the central repo that pulls in all other SONiC components as submodules and builds them into a complete NOS image.

## Architecture

The build flows top-down: `Makefile` → `Makefile.work` (enters Docker build slave) → `slave.mk` (orchestrates all targets inside the container).

- **`rules/`** — Each component has a `.mk` file (build definition) and a `.dep` file (dependency graph). The `.mk` file declares the package variable, its `_SRC_PATH`, `_DEPENDS`, `_RDEPENDS`, and registers it into a build category.
- **`dockers/`** — Dockerfile.j2 templates for each SONiC service container. Built via rules in `rules/docker-*.mk`.
- **`device/`** — Per-platform device configs: `device/<vendor>/<platform>/`. Contains plugins, LED configs, platform.json, hwsku dirs.
- **`platform/`** — Platform-specific build rules and kernel modules (e.g., `platform/broadcom/`, `platform/mellanox/`).
- **`src/`** — Git submodules for SONiC components. **Do NOT modify files here directly** — changes go to the respective submodule repos.
- **`sonic-slave-*`** — Dockerfiles for the build environment containers (one per Debian release).
- **`slave.mk`** — The main build orchestrator. Defines path variables (`DEBS_PATH`, `PYTHON_WHEELS_PATH`, etc.) and includes all rules.

### Build Target Categories (in `.mk` files)

Packages register into one of these categories which determines how they're built:

| Category | Meaning |
|----------|---------|
| `SONIC_DPKG_DEBS` | Built from source via `dpkg-buildpackage` (has `_SRC_PATH`) |
| `SONIC_MAKE_DEBS` | Built from source via custom Makefile |
| `SONIC_ONLINE_DEBS` | Downloaded from a URL |
| `SONIC_DOCKER_IMAGES` | Docker images built from Dockerfile.j2 |
| `SONIC_INSTALL_DOCKER_IMAGES` | Docker images included in the final NOS image |

### Rules `.mk` File Pattern

```makefile
# Package variable = filename
SWSS = swss_1.0.0_$(CONFIGURED_ARCH).deb
$(SWSS)_SRC_PATH = $(SRC_PATH)/sonic-swss
$(SWSS)_DEPENDS += $(LIBSAIREDIS_DEV) $(LIBSWSSCOMMON_DEV)
$(SWSS)_RDEPENDS += $(LIBSAIREDIS) $(LIBSWSSCOMMON)
SONIC_DPKG_DEBS += $(SWSS)
```

For Docker images:
```makefile
DOCKER_ORCHAGENT_STEM = docker-orchagent
DOCKER_ORCHAGENT = $(DOCKER_ORCHAGENT_STEM).gz
$(DOCKER_ORCHAGENT)_PATH = $(DOCKERS_PATH)/$(DOCKER_ORCHAGENT_STEM)
$(DOCKER_ORCHAGENT)_DEPENDS += $(SWSS)
$(DOCKER_ORCHAGENT)_LOAD_DOCKERS += $(DOCKER_SWSS_LAYER_TRIXIE)
SONIC_DOCKER_IMAGES += $(DOCKER_ORCHAGENT)
SONIC_INSTALL_DOCKER_IMAGES += $(DOCKER_ORCHAGENT)
```

## Language & Style

- **Primary languages**: Makefile, Shell (bash), Python, Jinja2 templates
- **Makefile style**: Use tabs for indentation (GNU Make requirement)
- **Shell scripts**: Use `#!/bin/bash`, 4-space indentation
- **Python**: Follow PEP 8, 4-space indentation
- **Naming**: snake_case for variables/functions in shell/Python; UPPER_CASE for Make variables

## Build Commands

```bash
# Initialize and configure
make init
make configure PLATFORM=vs  # Virtual Switch for testing

# Build full image
make SONIC_BUILD_JOBS=4 target/sonic-vs.img.gz

# Build a single .deb package
make target/debs/bookworm/swss_1.0.0_amd64.deb

# Build a single Docker image
make target/docker-orchagent.gz

# Clean everything
make clean    # remove build artifacts
make reset    # full reset including Docker images
```

### Build Environment Requirements
- Multiple CPU cores, 8+ GiB RAM, 300+ GiB disk
- Docker installed and running
- KVM virtualization support (for some builds)

### Key Build Variables (`rules/config`)

- `SONIC_CONFIG_BUILD_JOBS` — Parallel package build jobs (auto-detected)
- `SONIC_CONFIG_MAKE_JOBS` — Make -j within each package (defaults to nproc)
- `ENABLE_*` — Feature toggles (e.g., `ENABLE_ZTP`, `ENABLE_SYNCD_RPC`)
- `INCLUDE_*` — Component inclusion flags (e.g., `INCLUDE_SNMP`, `INCLUDE_NAT`)
- `DEFAULT_KERNEL_PROCURE_METHOD` — `build` or `download`

## Testing

- **VS (Virtual Switch)** platform is the primary testing platform
- CI runs on Azure Pipelines (`.azure-pipelines/`)
- Test images are built with `PLATFORM=vs`
- Integration tests run against VS images in the sonic-mgmt repo
- Python tests use pytest; `pytest.ini` at root sets rootdir

## PR Guidelines

- **Commit format**: `[component/folder]: Description of changes`
- **Signed-off-by**: All commits MUST include `Signed-off-by: Your Name <email>` (DCO requirement, use `git commit -s`)
- **Single logical change per PR**
- **Submodule updates**: Reference the PR in the submodule repo
- **PR template sections** (all required): Why I did it, Work item tracking, How I did it, How to verify it, Which release branch to backport, Tested branch, Description for the changelog

## Common Patterns

- **Adding a new package**: Create `rules/<pkg>.mk` and `rules/<pkg>.dep`, add source in `src/`
- **Adding a Docker container**: Create `dockers/<name>/Dockerfile.j2`, add `rules/docker-<name>.mk` and `.dep`
- **Platform support**: Add config in `device/<vendor>/<platform>/`, build rules in `platform/<vendor>/`
- **Feature flags**: Add `ENABLE_*` or `INCLUDE_*` in `rules/config`, gate with `ifeq` in `.mk` files

## Gotchas

- **Build times**: Full builds take 2-6 hours; use `SONIC_BUILD_JOBS` to parallelize
- **Disk space**: Builds require 100+ GiB
- **Submodule versions**: Always check that submodule pins are correct before building
- **Branch compatibility**: Component branches must match buildimage branch (master ↔ master)
- **Do NOT modify `src/` directly**: Changes go to the respective submodule repos, then update the submodule pin here
- **Debian version matters**: Build outputs go to `target/debs/<codename>/` (bookworm, bullseye, etc.). The active codename is determined by the build slave container.
