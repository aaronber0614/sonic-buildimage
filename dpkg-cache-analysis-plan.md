# Analysis & PoC Plan: DPKG Cache Artifact Consistency

## Problem Statement

The existing DPKG cache framework is designed to reuse artifacts when dependency hashes match, but we do not currently have an automated equivalence check that proves cache-loaded artifacts are functionally identical to artifacts built from source at the same commit. The framework includes dependency tracking, cache key generation, and cache restore/save mechanics — the issue is not that there is *no mechanism*, it is that the team lacks a **validation mechanism** to prove the mechanism is complete.

**Key insight**: Raw `sha256sum` comparison of `.deb`, Docker `.gz`, or `.bin` files between cached and non-cached builds will **almost certainly show differences** even when the underlying code is 100% identical. This is the well-known **reproducible builds problem** — archives embed timestamps, build paths, and non-deterministic file ordering. The correct question is not "are the checksums identical?" but "is the executable code and configuration data identical?"

## Severity Model for Findings

| Severity | Definition | Example |
|----------|-----------|---------|
| **P0** | Cache hit produces semantically different executable/config output | Wrong version of a library linked |
| **P1** | Cache key misses a dependency that could plausibly affect output | Source file not tracked in `.dep` |
| **P2** | Cache key misses metadata-only or low-risk inputs | Comment-only file not tracked |
| **P3** | Cosmetic reproducibility drift only | Timestamp in archive header |
| **P4** | Documentation/tooling cleanup | Missing `.dep` file for uncached target |

## Complete Build Artifact Inventory

The SONiC build system produces the following artifact types. Each has different caching behavior:

| # | Artifact Type | Output Path | Cached (LOAD+SAVE)? | Format | Evidence | Notes |
|---|---------------|-------------|---------------------|--------|----------|-------|
| 1 | `SONIC_DPKG_DEBS` | `target/debs/<codename>/` | ✅ Yes | `.deb` | Confirmed (`slave.mk:659,703`) | Built via `dpkg-buildpackage` from submodule source |
| 2 | `SONIC_MAKE_DEBS` | `target/debs/<codename>/` | ✅ Yes | `.deb` | Confirmed (`slave.mk:750`) | Built via custom Makefile |
| 3 | `SONIC_ONLINE_DEBS` | `target/debs/<codename>/` | ✅ Yes | `.deb` | Confirmed (`slave.mk:824,867`) | Downloaded from URL, cached to avoid re-download |
| 4 | `SONIC_COPY_DEBS` | `target/debs/<codename>/` | ✅ Yes | `.deb` | Confirmed (`slave.mk:983,1023`) | Copied from local path |
| 5 | `SONIC_DERIVED_DEBS` | `target/debs/<codename>/` | N/A (bundled) | `.deb` | Confirmed (bundled in parent .tgz) | Packaged into parent's cache tarball |
| 6 | `SONIC_EXTRA_DEBS` | `target/debs/<codename>/` | N/A (bundled) | `.deb` | Confirmed (bundled in parent .tgz) | Packaged into parent's cache tarball |
| 7 | `SONIC_MAKE_FILES` | `target/files/<codename>/` | ✅ Yes | misc files | Confirmed (`slave.mk:1244,1335`) | Built via custom Makefile (non-deb outputs) |
| 8 | `SONIC_ONLINE_FILES` | `target/files/<codename>/` | ❌ No | misc files | Confirmed (no LOAD/SAVE in slave.mk) | Downloaded from URL — no caching |
| 9 | `SONIC_COPY_FILES` | `target/files/<codename>/` | ❌ No | misc files | Confirmed (no LOAD/SAVE in slave.mk) | Simple copy — no caching |
| 10 | `SONIC_PYTHON_STDEB_DEBS` | `target/python-debs/<codename>/` | ✅ Yes | `.deb` | Confirmed (`slave.mk`) | Python packages converted to deb via stdeb |
| 11 | `SONIC_PYTHON_WHEELS` | `target/python-wheels/<codename>/` | ✅ Yes | `.whl` | Confirmed (`slave.mk`) | Python wheels built from source |
| 12 | `SONIC_DOCKER_IMAGES` | `target/` | ✅ Yes | `.gz` (docker save) | Confirmed (`slave.mk`) | Docker images for SONiC services |
| 13 | `SONIC_DOCKER_DBG_IMAGES` | `target/` | ✅ Yes | `.gz` (docker save) | Confirmed (`slave.mk`) | Debug variants of Docker images |
| 14 | `SONIC_SIMPLE_DOCKER_IMAGES` | `target/` | ❌ No | `.gz` (docker save) | Confirmed (no LOAD/SAVE) | Simple dockers — no caching |
| 15 | `SONIC_RFS_TARGETS` | `target/` | ⚠️ SAVE only | squashfs | Confirmed (`slave.mk:1426` LOAD commented) | Root filesystem — `LOAD_CACHE` is **commented out** |
| 16 | `SONIC_INSTALLERS` | `target/` | ❌ No | `.bin` | Confirmed (no LOAD/SAVE) | Final ONIE installer image — never cached |
| 17 | `SONIC_PHONIES` | `target/phony/<codename>/` | ❌ No | touch file | Confirmed (no LOAD/SAVE) | Phony targets (ordering only) — not cacheable |

### Key Observations:

- **RFS targets have SAVE_CACHE but LOAD_CACHE is commented out** (`slave.mk:1426`). This means the rootfs gets saved to cache but never loaded. This is intentional — the RFS split build optimization (`ENABLE_RFS_SPLIT_BUILD`, `rfs-split-build-improvement.md`) replaced monolithic RFS caching with a two-stage parallel build: Stage 1 (debootstrap + external packages) runs in parallel and saves progress as squashfs; Stage 2 (SONiC package installation + installer generation) loads the squashfs. This approach is faster and more reliable than caching the entire RFS.
- **Final installers (`.bin`) are never cached** — they're always rebuilt from constituent parts.
- **Simple Docker images, online files, and copy files are not cached** — they're trivial operations (download/copy).
- **The plan must cover**: `.deb` files (types 1-6, 10), `.whl` files (type 11), Docker images (types 12-13), RFS (type 15 — partial), and final installer (type 16 — comparison only).

### Suspected Gap: `sonic-slave-trixie` missing from `SONIC_COMMON_BASE_FILES_LIST`

`SONIC_COMMON_BASE_FILES_LIST` in `Makefile.cache` includes `sonic-slave-jessie`, `sonic-slave-stretch`, `sonic-slave-buster`, `sonic-slave-bullseye`, and `sonic-slave-bookworm` Dockerfile entries, but **not `sonic-slave-trixie`**. If trixie-based builds use DPKG cache, cache keys will not reflect changes to the trixie slave environment — meaning a change to the trixie build container would NOT invalidate the cache. **Severity: P1.**

**Immediate action item**: File a PR to add `sonic-slave-trixie/Dockerfile.j2` and `sonic-slave-trixie/Dockerfile.user.j2` to `SONIC_COMMON_BASE_FILES_LIST` in `Makefile.cache`. This is independent of the PoC and should be done regardless.

## How the Cache Works (Summary)

The caching framework (`Makefile.cache`) works as follows:

1. **Cache key derivation**: For each target (e.g., `swss_1.0.0_amd64.deb`), a compound hash is computed:
   - **hash1 (DEP_MOD_SHA, 24 chars)**: SHA1 of:
     - Part 1: For each dependency of this target — `git hash-object` of that dependency's `.flags`, `.dep.sha`, and `.smdep.sha` files
     - Part 2: DEP_MOD_SHA and MOD_HASH of each dependency (making this **transitively inclusive** — each dep's pre-computed hashes are incorporated)
   - **hash2 (MOD_HASH, 24 chars)**: SHA1 of `git hash-object` applied to:
     - The `.flags` file for this target (contains environment flag values)
     - The `.dep.sha` file for this target (hashes of all tracked dependency files)
     - The `.smdep.smsha` file for this target (if applicable — hashes of submodule files)
   - *Note*: In `Makefile.cache` code (line 208), hash2 has two modes:
     - `GIT_COMMIT_SHA` — uses `git log -1 --format="%H"` from the submodule (last commit only)
     - `GIT_CONTENT_SHA` (default) — hashes the .flags/.dep.sha/.smdep.smsha files as described above
   - *Correction from pptx*: The pptx states hash2 is derived from ".flags, .dep, .smdep" files. The actual code (`Makefile.cache:206`) uses **.flags, .dep.sha, .smdep.smsha** — the hash files, not the raw file listings.

2. **Cache filename**: `<target>-<hash1>-<hash2>.tgz`

3. **LOAD_CACHE**: If a `.tgz` file with matching hash exists in the cache dir, extract it; skip compilation.

4. **SAVE_CACHE**: After building, tar up the artifact (plus derived/extra debs) and save to cache dir.

5. **Scope of tracking** (per `.dep` file):
   - `_DEP_FILES`: Makefile rules, common infra files (`.platform`, `rules/functions`, `Makefile.cache`), slave Dockerfiles
   - `_SMDEP_FILES`: All git-tracked files in the submodule source tree
   - `_DEP_FLAGS`: Environment flags (`SONIC_DEBUGGING_ON`, `CONFIGURED_PLATFORM`, `CONFIGURED_ARCH`, etc.)
   - Dependency packages' own hash1+hash2 (transitively inclusive — each dep's hashes are pre-computed then incorporated)

6. **Build-time dependency install/uninstall cycle**: Dependencies listed in `_DEPENDS` are built, installed into the slave container **before** the target builds, then **uninstalled after** the target completes. This means the slave container state is transient per-target.

### Critical: How Make Behaves Differently With Caching Enabled

**Without caching**: Make uses its normal timestamp-based prerequisite tracking. A target is only rebuilt if:
- It doesn't exist, OR
- `.platform` changed, OR
- Build-time dependency `-install` targets need remaking

**With caching enabled**: The `dpkg_depend` function (`Makefile.cache:771`) adds the `.dep` file as a prerequisite to each target. This creates a dependency chain:

1. `.flags` rule uses **double-colon (`::`) with no prerequisites** (`Makefile.cache:551`) → recipe **always runs**
2. However, `.flags` uses `cmp -s` (line 554) to only **update the file if content changed**
3. `.dep` depends on `.flags` + actual source files + `.smdep` (line 646-647)
4. `.dep` also uses `cmp -s` (line 651) to only update if SHA content changed
5. Target depends on `.dep`

**In practice**: Starting from a clean state (no .flags/.dep files exist), ALL targets cascade through the chain — the `.flags` file is created, `.dep` is created, and the target rule fires (which then checks cache). This is the scenario for our PoC Build C.

**For incremental builds** (target already exists, .flags/.dep exist, nothing changed): the `.flags` recipe runs but doesn't update the file → `.dep` isn't triggered → target isn't rebuilt. The pptx oversimplifies by saying "Make will always remake the targets" — this is only true when starting from clean or when flags/deps actually changed.

**Implication for our PoC**: Since Build C starts from a clean artifact tree (we remove .flags/.dep/.sha files), all targets will fire their rules, check cache, and load from cache if hash matches. This is correct behavior for our test.

## Why Identical Code Produces Different Checksums

A `.deb` file is an `ar` archive containing `tar` files. The hash drifts due to:

1. **Timestamps** — `dpkg-buildpackage` stamps `.o` files, binaries, and the archive with compilation time. Cached `.deb` retains the original build timestamp.
2. **Embedded Build Paths** — GCC embeds absolute paths (`/tmp/sonic-build-xyz/`) into debug symbols and `__FILE__` macros. Different build runs use different temp paths.
3. **File Ordering** — Non-deterministic filesystem order in `tar` archiving means `file_B` may be packed before `file_A` in one build but not another.
4. **Gzip Non-Determinism** — `gzip` embeds a timestamp in the `.gz` header.
5. **Host Metadata** — Occasionally hostname/user leaks (mitigated by sonic-slave Docker containers).

These same issues cascade into Docker images (`.gz`) via layer timestamps and gzip headers, and into the final ONIE installer (`.bin`) via SquashFS/ext4 creation timestamps and archive headers.

## Important: Two Separate Caching Systems

SONiC has **two independent caching mechanisms** that must not be confused:

| System | Config Variable | What It Caches | Level |
|--------|----------------|----------------|-------|
| **DPKG Cache** | `SONIC_DPKG_CACHE_METHOD` | Built artifacts (.deb, .whl, Docker .gz) | Output of compilation |
| **Version Cache** | `SONIC_VERSION_CACHE_METHOD` | Downloaded external dependencies (apt packages, pip packages, wget files, git clones, Docker base images, Go modules) | Input to compilation |

**DPKG Cache** (our primary focus): Caches the *output* of building a target. Cache key is based on source file hashes and dependency hashes. Question: "If my source hasn't changed, can I skip building?"

**Version Cache**: Caches *downloaded inputs* so they don't need to be re-fetched from the internet. Controlled by `SONIC_VERSION_CACHE_SOURCE` (default: `<dpkg_cache>/vcache`). Question: "Can I avoid re-downloading this external package?"

**Additionally**, `SONIC_VERSION_CONTROL_COMPONENTS` (default: `py2,py3,web,git,docker`) pins specific versions of external packages using files in `files/build/versions/` (per-docker version files like `versions-deb-trixie`, `versions-py3`). When enabled with `deb` component, it forces `MIRROR_SNAPSHOT=y` (uses a frozen Debian snapshot mirror at a specific timestamp, e.g. `debian==20260518T000600Z`).

**Key observation**: Azure Pipelines CI already sets `MIRROR_SNAPSHOT=y` (`.azure-pipelines/template-variables.yml:9`), which means CI builds USE frozen Debian mirrors regardless of `SONIC_VERSION_CONTROL_COMPONENTS`. Local builds default to `MIRROR_SNAPSHOT=n` unless `deb` is in `SONIC_VERSION_CONTROL_COMPONENTS`.

**Implication for our PoC**: If Version Cache is enabled during our test, pip/apt/wget will always pull from local cache — masking the "external dependency drift" risks we identified. We must explicitly control BOTH cache settings and document which combination we're testing.

## Potential Sources of Cache/Non-Cache Divergence

### Category A: Known Risks in the Cache Design (Semantic — real bugs)

**Applies to ALL cached artifact types (.deb, .whl, Docker .gz, make-files):**

1. **Incomplete dependency tracking in `.dep` files** — If a `.dep` file doesn't list all actual build inputs, the cache key won't change when the actual input changes.

2. **`slave.mk` excluded from `SONIC_COMMON_FILES_LIST`** — The cache intentionally excludes `slave.mk` to avoid 100% invalidation. `Makefile.cache` mitigates this with `SONIC_CACHE_RECIPE_VER` plus a baseline hash guard (`SONIC_CACHE_SLAVE_HASH` vs `SONIC_CACHE_RECIPE_VER_BASELINE`) that emits warnings when `slave.mk` changes while cache is enabled. This is a useful guard, but still requires human review to decide whether the recipe version should be bumped.

3. **Docker build slave environment drift** — The build slave Dockerfiles are tracked via `SONIC_COMMON_BASE_FILES_LIST`, but tool/library versions installed inside that container can drift between cache-write and cache-read if the slave image was rebuilt. Note: the slave container persists for the duration of one `make` invocation but may be rebuilt between invocations.

4. **Missing `.dep` files** — 7 packages have no `.dep` file (`docker-stp`, `grpc`, `iproute2`, `sonic-nettools`, `sonic-genl-packet-ko`, `sonic-packages`, `docker-sonic-redfish`). These are never cached — no divergence risk but no caching benefit.

5. **Transitive dependency hash propagation** — If package A's `.dep` is incomplete, stale A is served, and downstream package B won't detect the problem. This is amplified by the transitive nature of hash1 — if A's hash is wrong, B's hash1 (which includes A's pre-computed DEP_MOD_SHA+MOD_HASH) will also be wrong.

6. **Make prerequisite bypass in from-clean builds** — When starting from a clean state with caching on, every target fires through the .flags→.dep→target chain and checks cache. Make's normal "only rebuild if prereqs are newer" logic is bypassed because the .dep file is freshly created (newer than the nonexistent target). This means in from-clean builds, the ONLY protection against stale artifacts is the cache hash — if the hash is wrong (due to incomplete .dep), stale cache is served without question.

**Python wheel specific risks:**

6. **Unpinned transitive pip dependencies** — Wheel builds use `python -m build -n` (bookworm/trixie) or `python setup.py bdist_wheel` (older). Before building, `pip install .` is used for dependency resolution only (the package is immediately uninstalled). If the build slave's pip cache or available packages differ between cache-write time and cache-read time, the cached wheel might have been built against different transitive deps than a fresh build would use.

7. **Exclusion patterns in `.dep` files** — `sonic-platform-common.dep` uses `grep -Ev "^sonic_sfp|^sonic_eeprom"` to exclude files. If those excluded files affect the build output, the cache won't detect the change.

8. **Build backend/tooling version drift** — Python version, pip/setuptools/wheel versions, PEP 517 build backend version, and files like `pyproject.toml`, `setup.cfg`, `setup.py`, `MANIFEST.in` must be tracked. Also, packages using `setuptools_scm` or git metadata for version generation may produce different version strings if the cache key doesn't account for git state beyond tracked source files.

**Docker image specific risks:**

9. **`apt-get install` inside Dockerfiles** — Docker images install additional packages via apt during `docker build`. If these aren't version-pinned (or pinned versions differ from what's in the version-control framework), a cached Docker image might contain different system packages than a fresh build.

10. **Docker build scripts not tracked** — `scripts/prepare_docker_buildinfo.sh` and `scripts/collect_docker_version_files.sh` modify the Dockerfile context at build time. If these scripts change behavior without changing tracked files, cache may serve stale images.

11. **`_LOAD_DOCKERS` (base layer) changes** — If a base Docker image changes but the dependent image's `.dep` doesn't detect it through `_DEPENDS`, the cache may serve an image built on an outdated base.

**Online/Copy package specific risks:**

12. **Different correctness question for downloaded packages** — For built packages, the question is "did the cache skip compilation correctly?" For `SONIC_ONLINE_DEBS` and `SONIC_ONLINE_FILES`, the question is "did the cache preserve the exact external input/version that would otherwise have been downloaded?" Verify whether the cache key includes the URL, expected filename, version-control metadata, and any checksum file. If not, URL content drift could be masked by cache.

**RFS / Installer specific risks:**

13. **RFS LOAD_CACHE disabled** — `slave.mk:1426` has `LOAD_CACHE` commented out for RFS targets. SAVE works but LOAD doesn't. This means RFS always rebuilds (no cache divergence risk, but also no speed benefit). **Note**: RFS comparison is useful as an integration signal, but should not block the initial DPKG cache enablement decision unless RFS `LOAD_CACHE` is re-enabled.

14. **Installer never cached** — The `.bin` installer assembles from cached components. If any component was incorrectly cached (risks 1-12 above), the error propagates into the final image.

### Category B: Cosmetic Differences (Functionally Equivalent)

**Applies to `.deb` files:**

15. **Timestamps in deb metadata** — Different hash, same code. Solvable with `SOURCE_DATE_EPOCH`.
16. **Non-deterministic archive ordering** — Different hash, same contents.
17. **Build paths in debug symbols** — Different hash, same executable logic. Solvable with `-fmacro-prefix-map`.

**Applies to `.whl` files:**

18. **ZIP metadata timestamps** — `.whl` is a ZIP file; metadata includes modification times.
19. **`.pyc` compilation timestamps** — Bytecode files embed compile time.

**Applies to Docker images:**

20. **Docker layer timestamps** — `Created` field in layer JSON config.
21. **Gzip header timestamps** — `.gz` format includes OS timestamp in header.

**Applies to `.bin` installers:**

22. **SquashFS/ext4 creation timestamps** — Filesystem images record creation time.
23. **Self-extracting archive headers** — May embed build metadata.

## Proposed Analysis & PoC Plan

### Phase 1: Static Analysis of Cache Correctness

**Goal**: Identify gaps in dependency tracking without running any builds — across ALL cached artifact types.

**1a. `.deb` packages (SONIC_DPKG_DEBS, SONIC_MAKE_DEBS):**
- [ ] Audit all `rules/*.dep` files to verify they track all source inputs for their `.mk` target.
- [ ] Identify packages using `GIT_COMMIT_SHA` vs `GIT_CONTENT_SHA` and assess appropriateness.
- [ ] Check if any `.mk` files reference files outside the declared `_SRC_PATH` (undeclared cross-module deps).
- [ ] Verify `SONIC_COMMON_FLAGS_LIST` captures all env variables that affect deb build output.
- [ ] Check `SONIC_COMMON_BASE_FILES_LIST` covers all active slave Dockerfiles (trixie is missing — see Suspected Gap above).

**1a2. Online/Copy `.deb` packages (SONIC_ONLINE_DEBS, SONIC_COPY_DEBS):**
- [ ] Verify whether cache keys include the download URL, expected filename, and version-control metadata.
- [ ] Check if any checksum verification is included in the cache key (URL content could drift silently if not).
- [ ] For SONIC_COPY_DEBS, verify the source path is tracked in the cache key.

**1b. Python wheels (SONIC_PYTHON_WHEELS):**
- [ ] Verify each wheel's `.dep` tracks all source files (some use `git ls-files` with grep exclusions like `sonic-platform-common` — are exclusions correct?).
- [ ] Check if wheel `_DEPENDS` and `_DEBS_DEPENDS` properly track all build-time Python/deb deps.
- [ ] Assess risk: wheel builds use `python -m build -n` (bookworm/trixie) or `python setup.py bdist_wheel` (older), with `pip install .` used only for dependency resolution beforehand — are transitive deps pinned in the build environment?
- [ ] **⚠️ Network drift risk**: Audit whether the build environment forces offline pip installation (`--no-index`) or uses a version-pinned local PyPI mirror. The `SONIC_VERSION_CONTROL_COMPONENTS` setting (default includes `py2,py3`) hooks `pip3` via `src/sonic-build-hooks/hooks/pip3` which wraps the real pip and injects `--constraint <versions-py3>` file (line 347-349 of `buildinfo_base.sh`). When version control is enabled (default for py2/py3), pip is constrained to pinned versions. However, transitive dependencies NOT listed in the constraint file may still drift. Document whether the constraints are comprehensive or only cover direct deps.
- [ ] Check if `_WHEEL_DEPENDS` relationships are correctly reflected in the cache key's PART A.
- [ ] Verify that `setup.py`/`setup.cfg`/`pyproject.toml`/`MANIFEST.in` and build backend versions are tracked in `.dep` files.
- [ ] Check whether generated package version logic depends on git metadata beyond tracked source file contents (e.g., `setuptools_scm`).

**1c. Python stdeb debs (SONIC_PYTHON_STDEB_DEBS):**
- [ ] Same audit as 1b but for stdeb-converted packages.
- [ ] Check if stdeb version itself is tracked as a dependency.
- [ ] **Known cosmetic issue**: `stdeb` auto-generates `debian/changelog` files during conversion, injecting the current execution timestamp. This guarantees a hash mismatch on every build — must be stripped during diff comparison (P3).

**1d. Docker images (SONIC_DOCKER_IMAGES, SONIC_DOCKER_DBG_IMAGES):**
- [ ] Verify Docker `.dep` files track the full Dockerfile.j2 directory content.
- [ ] **Key concern**: Docker `.dep` tracks the Dockerfile directory (`git ls-files $(DPATH)`) but the `.deb` files installed inside the container are tracked only via `_DEPENDS` in the `.mk` file. Verify these `_DEPENDS` lists are complete.
- [ ] Check if `_LOAD_DOCKERS` (base layer images) are properly included in the cache key.
- [ ] Assess Docker-specific non-determinism: layer ordering, `apt-get install` inside Dockerfile pulling latest from mirrors (are versions pinned?).
- [ ] **⚠️ Upstream apt drift**: Even if the Dockerfile and `.dep` are perfectly tracked, upstream Debian/Ubuntu repositories update continuously. A cached image retains older apt packages; a fresh build installs newer ones. The SONiC version control framework addresses this: when `SONIC_VERSION_CONTROL_COMPONENTS` includes `deb`, it forces `MIRROR_SNAPSHOT=y` which uses a frozen Debian mirror (managed by Aptly). Verify whether production builds use this mode. If `deb` is NOT in `SONIC_VERSION_CONTROL_COMPONENTS` (current default omits it!), document as a known source of semantic drift that the DPKG cache key cannot detect.
- [ ] Check if `scripts/prepare_docker_buildinfo.sh` and `scripts/collect_docker_version_files.sh` outputs affect the image but aren't tracked.

**1e. Make files (SONIC_MAKE_FILES):**
- [ ] Verify `.dep` files for make-file targets (e.g., `ixgbe.ko`, `rdb-cli`) track all source inputs.
- [ ] These are non-deb artifacts (kernel modules, binaries) — confirm their build recipes in `slave.mk` use LOAD/SAVE_CACHE correctly.

**1f. Root filesystem (SONIC_RFS_TARGETS):**
- [ ] Note that LOAD_CACHE is disabled — analyze why (comment/git history).
- [ ] Assess whether `RFS_DEP_FILES` list in `Makefile.cache` is complete (it tracks `build_debian.sh`, initramfs, kernel, image_config, etc.).
- [ ] Check if enabling RFS caching is feasible and what risks exist.

**1g. Cross-cutting concerns:**
- [ ] Verify `SONIC_COMMON_BASE_FILES_LIST` — currently missing `sonic-slave-trixie/` entries.
- [ ] Audit the `SONIC_CACHE_RECIPE_VER` guard mechanism — when was it last bumped? Are there unreviewed `slave.mk` changes?
- [ ] Check if `Makefile.work` (which enters the Docker build slave) has settings that affect builds but aren't tracked.

**Deliverable**: A written report listing dependency tracking gaps per artifact type, with severity ratings.

### Phase 2: Binary Comparison PoC (Controlled Environment)

**Goal**: Empirically prove that cached artifacts are functionally identical to fresh-built ones.

#### Environment Preconditions (MUST record before each build):

To avoid conflating cache correctness with environment drift, lock and record these before Builds A/B/C:

```text
- git rev-parse HEAD
- git submodule status --recursive
- rules/config + rules/config.user (full contents)
- docker image ID/digest for sonic-slave-<bldenv>
- SONIC_DPKG_CACHE_METHOD, SONIC_DPKG_CACHE_SOURCE, BLDENV, PLATFORM, CONFIGURED_ARCH
- SONIC_VERSION_CONTROL_COMPONENTS (default: py2,py3,web,git,docker)
- SONIC_VERSION_CACHE_METHOD, SONIC_VERSION_CACHE_SOURCE
- MIRROR_SNAPSHOT setting (y/n — controls whether frozen Debian mirror is used)
- DOCKER_BUILDKIT / SONIC_USE_DOCKER_BUILDKIT
- Host architecture (uname -m)
- Python/pip/setuptools versions inside slave container
```

**Recommended PoC configuration**: Set `SONIC_VERSION_CONTROL_COMPONENTS=all` and `SONIC_VERSION_CACHE_METHOD=cache` for ALL three builds. This pins external dependencies and eliminates internet-induced drift — isolating the DPKG cache as the only variable. If testing without version control, document that external dep drift is expected and NOT a DPKG cache defect.

If ANY of these differ between builds, mismatches are NOT evidence of a DPKG cache defect.

#### PoC Design:

1. **Build A (Baseline)**: Full clean build with `SONIC_DPKG_CACHE_METHOD=none` on VS platform.
2. **Build B (Cache-Write)**: Same commit, full clean build with `SONIC_DPKG_CACHE_METHOD=wcache` — this populates the cache.
3. **Build C (Cache-Read)**: Clean artifact tree + rebuild with `SONIC_DPKG_CACHE_METHOD=rcache` — this reads from the cache populated in Build B.

**Important**: Build C cleanup must go beyond `make clean`. Remove:
- `target/debs/<bldenv>/` and `target/python-wheels/<bldenv>/` for package-level PoC
- `target/*.gz` for Docker-level PoC
- `target/sonic-vs.img.gz`, `fsroot-*` for image-level PoC
- Related `.dep`/`.sha`/`.flags` tracking files to force cache lookup

**⚠️ Docker daemon cache isolation (critical):** If Build B and Build C run on the same host, Docker's own layer cache could theoretically mask DPKG cache failures. However, SONiC builds already use `--no-cache` by default (`slave.mk:360`, unless `SONIC_CONFIG_USE_DOCKER_CACHE=y`). Verify this flag is NOT overridden in your PoC environment. As an additional safety measure, run `docker system prune -a` between Build B and Build C to remove any lingering images from the previous build.

**Primary comparison**: Build B artifacts vs Build C artifacts (same cache → same output?). Build A is a control for understanding what "fresh build" variation looks like.

#### Multi-Level Comparison Strategy:

**Level 1 — `.deb` packages (SONIC_DPKG_DEBS, SONIC_MAKE_DEBS, SONIC_PYTHON_STDEB_DEBS):**
- Raw `sha256sum` comparison (expected to differ due to timestamps)
- `diffoscope` to explain structural differences — recursively unpacks and reports what differs
- For ELF binaries inside: tiered comparison approach:
  1. Compare file type, ELF headers, program headers, dynamic section, needed libraries
  2. Compare loadable sections (.text, .rodata, .data, .bss size)
  3. For debug-only drift: use `objcopy --strip-debug` (NOT `strip --strip-all` — that can remove metadata needed for kernel modules)
  4. For kernel modules: compare `modinfo`, vermagic, exported symbols, and loadable sections
- Classify differences: known benign (timestamps, gzip headers, archive ordering, debug paths) vs unexplained content differences (treat as semantic until reviewed)

**Level 1b — Online/Copy `.deb` packages (SONIC_ONLINE_DEBS, SONIC_COPY_DEBS):**
- Different correctness question: "Did the cache preserve the exact external input that would have been downloaded/copied?"
- Verify cache key includes URL, expected filename, and version metadata
- Raw `sha256sum` should match exactly (no compilation involved — binary should be identical)

**Level 2 — Python wheels (SONIC_PYTHON_WHEELS):**
- `.whl` files are ZIP archives — raw hash may differ due to ZIP metadata timestamps
- Unzip both, compare file-by-file with `sha256sum`
- `.pyc` files may embed timestamps — compare `.py` source files directly
- Compare `METADATA`, `RECORD` files for version/dependency drift

**Level 3 — Docker images (SONIC_DOCKER_IMAGES, SONIC_DOCKER_DBG_IMAGES):**
- Raw `.gz` hash will differ (pigz header, Docker layer timestamps)
- Load both into Docker: `docker load -i <image>.gz`
- Compare `docker inspect` output after normalizing `Created` timestamps and image IDs — treat `Env`, `Entrypoint`, `Cmd`, `Labels`, `User`, `WorkingDir`, and exposed ports as semantic
- Use `container-diff` to compare filesystem state and package manifests:
  ```
  container-diff analyze daemon://cached:latest daemon://scratch:latest --type=file --type=apt
  ```
- Fallback (if `container-diff` unavailable): `docker create` + `docker export` → compare extracted filesystem; `docker inspect` for config comparison
- Compare installed apt package list and SONiC deb list inside image

**Level 4 — Root filesystem (SONIC_RFS_TARGETS):**
- Note: LOAD_CACHE is currently disabled for RFS, so this is less critical for the cache question
- But for completeness: `unsquashfs` both squashfs images → `diffoscope` on extracted trees
- Focus on installed packages, config files, and binary content

**Level 5 — Final installer (SONIC_INSTALLERS / `.bin`):**
- Never cached — always rebuilt from components — so it serves as an end-to-end integration check
- Extract payload: `./sonic-vs.bin --noexec --target /tmp/extracted/`
- Unpack rootfs squashfs: `unsquashfs rootfs.squashfs`
- `diffoscope` on extracted root filesystems
- Compare kernel, initramfs, and Docker images bundled inside

#### Scope for Initial PoC:

- VS platform (`PLATFORM=vs`) — fastest build
- Focus on key packages: `swss`, `swss-common`, `sairedis`, `sonic-utilities`, `linux-kernel`
- Expand to full image + `.bin` comparison if subset passes

#### Negative Control Tests (Phase 2b):

**Goal**: Prove the verification tooling actually catches real bugs — not just confirming "everything looks fine."

These tests intentionally introduce changes to verify the cache model detects (or fails to detect) them:

| Test | Action | Expected Result |
|------|--------|-----------------|
| **NC-1: Tracked file change → cache miss** | Modify a file listed in a target's `.dep` | Cache miss → full rebuild → artifacts differ from cache |
| **NC-2: Untracked file change → cache hit with drift** | Modify a file used by the build but NOT listed in `.dep` | Cache hit (stale) → verification tool detects semantic drift |
| **NC-3: Build flag change → key change** | Change a flag in `SONIC_COMMON_FLAGS_LIST` (e.g., `SONIC_DEBUGGING_ON`) | Cache key changes → miss → rebuild |
| **NC-4: Dockerfile base change → Docker cache miss** | Change a Dockerfile base input tracked in Docker `.dep` | Docker cache key changes → miss → rebuild |

**Why these matter**: Without negative controls, the PoC only proves "things look the same" — it cannot prove the tool would *catch* a real defect. NC-2 is the most important: it simulates the exact failure mode we're worried about (incomplete `.dep` → stale cache served).

### Phase 3: Develop Verification Tooling

**Goal**: Create a repeatable script/CI check that can validate cache consistency across ALL artifact types.

- [ ] Build a `verify_cache_equivalence.sh` script with sub-commands per artifact type:

  **⚠️ `diffoscope` performance guardrails:** Running `diffoscope` unconditionally on multi-GB root filesystems or installers will take hours or OOM. Use `--max-report-size` flag and set a hard timeout. For Levels 3-5, rely on `container-diff` or `diff -r` on extracted filesystems to isolate the specific binary that drifted, then target `diffoscope` at that specific file only.

  **3a. `.deb` packages** (`target/debs/`, `target/python-debs/`):
  1. Find matching `.deb` filenames across both build directories
  2. `sha256sum` comparison (document raw differences — expected for built packages)
  3. `diffoscope` on mismatched `.deb` files to explain differences
  4. For ELF binaries inside: `dpkg -x` → `objcopy --strip-debug` → `sha256sum` stripped binaries
  5. For kernel modules: compare `modinfo` output, vermagic, exported symbols
  6. Classify as semantic (FAIL) vs cosmetic (PASS) using the severity model (P0-P4)
  7. For SONIC_ONLINE_DEBS/SONIC_COPY_DEBS: raw `sha256sum` SHOULD match exactly (no build involved)

  **3b. Python wheels** (`target/python-wheels/`):
  1. Find matching `.whl` filenames across both build directories
  2. `sha256sum` comparison (raw — may differ due to ZIP metadata)
  3. Unzip both `.whl` files to temp dirs
  4. Compare `METADATA` and `RECORD` manifests for version/dep drift
  5. Compare `.py` source files directly (ignore `.pyc` timestamp diffs)
  6. Compare any compiled extensions (`.so`) after stripping

  **3c. Docker images** (`target/*.gz`):
  1. Find matching `docker-*.gz` filenames
  2. `sha256sum` comparison (raw — will differ due to gzip/layer timestamps)
  3. `docker load` both images
  4. Compare `docker inspect` output (normalize `Created` timestamp and ID; treat Env, Entrypoint, Cmd, Labels, User, WorkingDir as semantic)
  5. `container-diff --type=file --type=apt` for filesystem/package comparison
  6. Fallback: `docker create` + `docker export` + tar extract for filesystem comparison
  7. Compare installed apt package manifests and SONiC deb lists inside image

  **3d. Root filesystem** (`target/*-rfs.squashfs` or similar):
  1. `unsquashfs` both images to temp dirs
  2. `diff -r` on extracted trees (file listing, permissions, sizes)
  3. `diffoscope` on any binaries/configs that differ
  4. Focus on: installed packages list, config files, systemd units

  **3e. Final installer** (`target/sonic-*.bin`):
  1. Extract payload: `./sonic-vs.bin --noexec --target /tmp/extracted/`
  2. Compare embedded kernel (`vmlinuz`) hashes
  3. Compare initramfs: extract with `unmkinitramfs` → diff trees
  4. Extract and compare rootfs squashfs (reuse 3d logic)
  5. Extract and compare Docker images bundled inside (reuse 3c logic)

  **3f. Summary report generation:**
  1. Per-artifact pass/fail status with classification
  2. Aggregate stats: N packages compared, N identical, N cosmetic-only, N semantic failures
  3. Build time savings comparison (Build A duration vs Build C duration)
  4. Exit code: 0 if all differences are cosmetic, non-zero if any semantic failures

- [ ] If the team requires byte-for-byte reproducibility for supply-chain assurance or provenance goals, implement deterministic build fixes:
  - Set `SOURCE_DATE_EPOCH` to latest git commit timestamp before `make`
  - Pass `-fmacro-prefix-map=$(pwd)=.` to GCC to normalize build paths
  - Enable `DOCKER_BUILDKIT=1` for reproducible Docker layer creation
  - Use `gzip -n` (no timestamp) for archive creation
  - Use `strip-nondeterminism` on `.deb` and `.whl` archives

### Phase 4: Document Findings & Recommendations

**Goal**: Present analysis to team lead with evidence-backed recommendations.

- [ ] Document which packages (if any) produce semantically different outputs with cache enabled
- [ ] For each difference found, classify as:
  - **Cosmetic** (timestamps, paths, ordering) — safe, cache is correct
  - **Semantic** (code/data drift) — bug in `.dep` file, must be fixed
- [ ] Quantify build time savings (Build A duration vs Build C duration)
- [ ] Provide recommendation matrix:
  - If 0 semantic differences → "Cache is safe to enable with current `.dep` coverage"
  - If semantic differences found → "Fix specific `.dep` files, then re-verify"
  - If strict reproducibility required for compliance or provenance goals → "Enable cache + implement `SOURCE_DATE_EPOCH` + build path normalization for identical checksums"
- [ ] Propose an ongoing CI validation: periodic cached vs non-cached comparison run

## Key References

| Resource | Location |
|----------|----------|
| Cache framework implementation | `Makefile.cache` |
| Cache integration in build rules | `slave.mk` (lines with LOAD_CACHE/SAVE_CACHE) |
| Per-package dependency tracking | `rules/*.dep` |
| Cache configuration | `rules/config` (SONIC_DPKG_CACHE_METHOD, lines 149-157) |
| Version control configuration | `rules/config` (SONIC_VERSION_CONTROL_COMPONENTS, lines 317-346) |
| Version cache configuration | `rules/config` (SONIC_VERSION_CACHE_METHOD, lines 339-346) |
| Template for new .dep files | `rules/template.dep` |
| PR that introduced caching | https://github.com/sonic-net/sonic-buildimage/pull/4117 |
| DPKG caching framework doc | https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/DPKG%20caching%20framework%20.pptx |
| Reproducible Build doc | https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/SONiC-Reproduceable-Build.md |
| Build enhancements doc | https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/build-enhancements.md |
| Build system improvements doc | https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/build_system_improvements.md |
| RFS split build doc | https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/rfs-split-build-improvement.md |
| Azure CI cache config | `.azure-pipelines/build-template.yml` |
| Debian Reproducible Builds | https://reproducible-builds.org/ |
| diffoscope tool | https://diffoscope.org/ |
| container-diff tool | https://github.com/GoogleContainerTools/container-diff |

## Important Context

- **Raw checksum differences are expected and are NOT evidence that caching is broken.** The `.deb` format embeds non-deterministic metadata. Only semantic differences (actual code/data drift) indicate a caching defect.
- **`diffoscope` explains differences but does not automatically prove equivalence.** The verification tool must classify known benign differences (timestamps, gzip headers, archive ordering, debug paths, Docker layer metadata); any unexplained content difference should be treated as semantic until reviewed.
- The SONiC Reproducible Build effort (version pinning) is complementary — it addresses "same commit → same output across time" while the cache question is "does loading from cache give same output as building from source on the same commit?"
- **Two caching systems exist**: DPKG cache (build outputs) and Version cache (downloaded inputs). They are complementary and independently configured. Our PoC isolates the DPKG cache question by keeping Version cache settings consistent across all builds.
- **Default version control** (`py2,py3,web,git,docker`) does NOT include `deb` — meaning Debian packages from apt are NOT version-pinned by default. This is the main source of upstream drift risk for Docker image layers.
- `SOURCE_DATE_EPOCH` + `-fmacro-prefix-map` + `gzip -n` can make artifacts checksum-identical if strict compliance is required, but this is a separate (larger) effort from proving cache correctness.
- The `SONIC_CACHE_RECIPE_VER` guard in `Makefile.cache` is a good safety mechanism but relies on manual discipline.
- **RFS LOAD_CACHE is intentionally disabled** — replaced by the RFS split build optimization (2-stage parallel build via squashfs handoff), which is faster and more reliable than caching the entire rootfs.
- **Build time with both caches**: The `build-enhancements.md` doc reports 5 minutes for a full buster build with DPKG_CACHE=Y + VERSION_CACHE=Y (vs >40 min without). This is the target state we're validating.
- The SONiC Foundation is exploring Bazel-style build improvements, but Bazel should not be assumed to automatically solve artifact equivalence. Existing internal analysis notes that Bazel-built artifacts may differ significantly from Makefile-built artifacts and require their own comparison/testing strategy. Reproducible builds with Bazel remain an open question.
