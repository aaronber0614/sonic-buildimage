# DPKG Cache Artifact Consistency — Detailed Analysis & PoC Plan

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Background: What is SONiC and How Does It Build?](#background)
3. [The Problem We're Solving](#the-problem)
4. [Key Concepts Refresher](#key-concepts-refresher)
5. [The Two Caching Systems (Don't Confuse Them!)](#two-caching-systems)
6. [How the DPKG Cache Works (Step-by-Step)](#how-dpkg-cache-works)
7. [Why "Same Code" Doesn't Mean "Same Checksum"](#why-checksums-differ)
8. [Complete Artifact Inventory](#artifact-inventory)
9. [What Could Go Wrong (Risk Analysis)](#risk-analysis)
10. [The Plan: 4 Phases](#the-plan)
11. [Phase 1: Static Analysis](#phase-1)
12. [Phase 2: Binary Comparison PoC](#phase-2)
13. [Phase 3: Verification Tooling](#phase-3)
14. [Phase 4: Documentation & Recommendations](#phase-4)
15. [Key References](#references)
16. [FAQ / Likely Questions](#faq)

---

<a name="executive-summary"></a>
## 1. Executive Summary

**One-line goal**: Prove (or disprove) that enabling the DPKG build cache produces functionally identical SONiC artifacts compared to building from scratch, so the team can confidently enable caching and cut build times from hours to minutes.

**The punchline**: The cache mechanism is well-designed. Our job is NOT to build a new cache — it's to **validate the existing one** by:
1. Auditing whether the cache "knows about" all the inputs that affect each build target
2. Running controlled builds with and without cache, then comparing the outputs
3. Building a repeatable script so CI can do this automatically going forward

**Expected outcome**: Most differences will be cosmetic (timestamps embedded in files). If we find any *semantic* differences (actual code/config drift), we file bugs to fix specific `.dep` tracking files — then re-validate.

---

<a name="background"></a>
## 2. Background: What is SONiC and How Does It Build?

### What is SONiC?
SONiC (Software for Open Networking in the Cloud) is a Linux-based network operating system that runs on commercial network switches. Think of it as "Ubuntu, but optimized for switches" with specialized networking containers.

### What does `sonic-buildimage` produce?
A single **ONIE installer** (`.bin` file) that you flash onto a switch. Inside that installer is:

```
sonic-vs.bin (the installer — ~3-6 GB)
├── vmlinuz (Linux kernel)
├── initrd (initial ramdisk)
├── rootfs.squashfs (compressed root filesystem)
│   ├── Base Debian packages (via apt-get during build)
│   ├── SONiC .deb packages (compiled from src/ submodules)
│   ├── Python wheels (.whl files)
│   ├── Configuration files
│   └── Docker images (.gz files) ← these are the main services
│       ├── docker-orchagent.gz (SWSS orchestration)
│       ├── docker-syncd-vs.gz (SAI syncd for Virtual Switch)
│       ├── docker-database.gz (Redis)
│       ├── docker-fpm-frr.gz (routing — FRR)
│       └── ... ~20 more containers
└── installer scripts (ONIE bootstrap)
```

### How does the build work?
The build system is based on **GNU Make** running inside a **Docker container** (called a "build slave"):

```
Your Host Machine
└── make (reads Makefile, slave.mk, rules/*.mk)
    └── Docker container ("sonic-slave-bookworm" or "sonic-slave-trixie")
        └── make (actual compilation happens here)
            ├── Compile C/C++ code → .deb packages
            ├── Build Python wheels → .whl files
            ├── Build Docker images → .gz files
            └── Assemble everything → .bin installer
```

**Key files**:
- `Makefile` → top-level entry point
- `Makefile.work` → sets up the Docker build slave and enters it
- `slave.mk` → the real build orchestrator (runs INSIDE the Docker slave)
- `rules/*.mk` → per-package build rules (one .mk per component)
- `rules/*.dep` → per-package dependency tracking (what files affect this package)
- `Makefile.cache` → the caching framework we're analyzing
- `rules/config` → build configuration (platform, cache settings, feature flags)

### Build commands (for reference):
```bash
make init                          # Initialize submodules
make configure PLATFORM=vs         # Configure for Virtual Switch (fastest)
make target/sonic-vs.img.gz        # Build the final image
# Takes 2-6 hours from scratch, ~5 min with full caching
```

---

<a name="the-problem"></a>
## 3. The Problem We're Solving

### The situation:
- Building SONiC from scratch takes **2-6 hours**
- The DPKG cache can reduce this to **~5 minutes** (40x speedup!)
- The cache has been implemented since 2019 (PR #4117) and is technically available
- **But** the team doesn't use it in production because there's no proof it produces the same output

### What "same output" means (and doesn't):
- ❌ We do NOT expect byte-for-byte identical files (that's called "reproducible builds" — a different, harder problem)
- ✅ We DO expect functionally identical outputs: same code, same configs, same behavior
- The difference: a `.deb` file always embeds the current timestamp. Two builds at different times produce different file hashes, but the *code inside* is identical.

### What we need to deliver:
1. **Evidence** that the cache produces semantically equivalent artifacts
2. **A gap list** of any tracking issues in `.dep` files (with fixes)
3. **A verification script** that CI can run to continuously validate this
4. **A recommendation**: "safe to enable" / "need fixes first"

---

<a name="key-concepts-refresher"></a>
## 4. Key Concepts Refresher

### GNU Make basics (as they apply here):
- Make uses **rules**: `target: prerequisites → recipe`
- If a target file is newer than all its prerequisites, Make skips rebuilding it
- **Double-colon rules** (`target::`) — recipe ALWAYS runs regardless of prerequisites
- `cmp -s file1 file2` — compares two files; returns 0 if identical, 1 if different
  - Used in the cache framework to avoid unnecessary rebuilds: "run the rule, but only update the tracking file if the content actually changed"

### What is a `.deb` file?
- Debian package format — the standard way Linux distros distribute software
- It's literally an `ar` archive containing:
  - `debian-binary` (version number)
  - `control.tar.gz` (metadata: package name, version, dependencies)
  - `data.tar.gz` (the actual files to install)
- Built by `dpkg-buildpackage` which runs `debian/rules` (a Makefile inside the source)

### What is a `.whl` file?
- Python wheel — a ZIP file containing Python code + metadata
- Name format: `package-version-py3-none-any.whl`
- Built by `python -m build` (on bookworm/trixie) or `python setup.py bdist_wheel` (older)

### What is a Docker `.gz`?
- Output of `docker save image:tag | pigz -c > image.gz` (uses `pigz` for parallel compression)
- Contains all the filesystem layers that make up a Docker image
- Can be loaded back with `docker load -i image.gz`

### What is SquashFS?
- A compressed, read-only filesystem used by SONiC for the root filesystem
- Created by `mksquashfs` — compresses an entire directory tree into one file
- Mounted at boot time on the switch

### What is ONIE?
- Open Network Install Environment — a standard boot loader for network switches
- SONiC produces `.bin` installers that ONIE knows how to install
- The installer is a self-extracting shell script with a compressed payload

### What is `diffoscope`?
- A tool that recursively unpacks archives and shows exactly what differs between two files
- Example: give it two `.deb` files and it'll show "line 3 of data.tar.gz/usr/bin/foo has a different timestamp"
- Very powerful but can be slow on large files (GB-scale)

### What is `container-diff`?
- Google's tool for comparing Docker images
- Shows: which files differ, which apt packages differ, which pip packages differ
- Faster than diffoscope for Docker-scale comparisons

---

<a name="two-caching-systems"></a>
## 5. The Two Caching Systems (Don't Confuse Them!)

This is one of the most common sources of confusion. SONiC has TWO separate caching systems:

### System 1: DPKG Cache (Our Focus)

| | |
|---|---|
| **Config variable** | `SONIC_DPKG_CACHE_METHOD` in `rules/config` |
| **Values** | `none` (default), `wcache` (write-only), `rcache` (read-only), `cache` (read+write) |
| **What it caches** | **Built artifacts** — the .deb, .whl, .gz files that come OUT of compilation |
| **Where it stores** | `SONIC_DPKG_CACHE_SOURCE` (default: `/var/cache/sonic/artifacts`) |
| **Cache key** | Hash of source files + dependency hashes (recursive) |
| **Question it answers** | "My source code hasn't changed — can I skip rebuilding this target?" |
| **Implementation** | `Makefile.cache` |

### System 2: Version Cache (NOT our focus, but important to understand)

| | |
|---|---|
| **Config variable** | `SONIC_VERSION_CACHE_METHOD` in `rules/config` |
| **Values** | `none` (default), `cache` (read+write) |
| **What it caches** | **Downloaded inputs** — apt packages, pip packages, wget files, git clones, Docker base images, Go modules |
| **Where it stores** | `SONIC_VERSION_CACHE_SOURCE` (default: `<dpkg_cache>/vcache`) |
| **Cache key** | Varies per type (URL + hash, constraint file hash, etc.) |
| **Question it answers** | "Can I avoid re-downloading this external package from the internet?" |
| **Implementation** | `src/sonic-build-hooks/scripts/buildinfo_base.sh`, various scripts |

### System 3: Version Control (Pinning — not caching)

| | |
|---|---|
| **Config variable** | `SONIC_VERSION_CONTROL_COMPONENTS` in `rules/config` |
| **Default** | `py2,py3,web,git,docker` (NOTE: `deb` is NOT in the default!) |
| **What it does** | Pins specific versions of external packages using version files in `files/build/versions/` |
| **For pip** | Hooks `pip3` command (via `src/sonic-build-hooks/hooks/pip3`) and injects `--constraint <versions-py3>` to force pinned versions |
| **For apt** | When `deb` is included, forces `MIRROR_SNAPSHOT=y` → uses a frozen Debian mirror at a specific timestamp (e.g., `debian==20260518T000600Z`) |
| **For web/git/docker** | Verifies downloaded files match expected hashes |

### How they interact:

```
Internet (apt, pip, wget, docker hub)
    │
    ▼
[Version Control] ← pins which versions to download
    │
    ▼
[Version Cache] ← stores downloaded files locally to avoid re-downloading
    │
    ▼
[Build/Compilation] ← uses downloaded inputs + source code to produce artifacts
    │
    ▼
[DPKG Cache] ← stores built artifacts to avoid re-compiling
    │
    ▼
Final artifacts (.deb, .whl, .gz, .bin)
```

### Why this matters for our PoC:
- If we enable Version Cache during our test, pip/apt/wget will always pull from local storage → no internet drift → cleaner experiment
- If we DON'T enable it, some external dependencies might change between builds → creating noise that isn't the DPKG cache's fault
- **Recommendation**: Enable Version Cache + Version Control for all PoC builds to isolate the DPKG cache as the only variable

### Critical observation about CI:
Azure Pipelines CI (`.azure-pipelines/template-variables.yml:9`) already sets `MIRROR_SNAPSHOT=y`, meaning CI builds use frozen Debian mirrors. But local developer builds default to `MIRROR_SNAPSHOT=n` (live mirrors). This means:
- A dev building locally without `deb` in version control → gets latest Debian packages
- CI → gets frozen snapshot packages
- A DPKG cache populated by CI → may serve artifacts built against older apt packages than what a local dev would get

This isn't a DPKG cache bug — it's an environment configuration difference. Our PoC must control for this.

---

<a name="how-dpkg-cache-works"></a>
## 6. How the DPKG Cache Works (Step-by-Step)

Let's trace what happens when you build `swss_1.0.0_amd64.deb` with caching enabled.

### Step 1: Cache Key Generation

The system computes a unique filename for the cached artifact:

```
swss_1.0.0_amd64.deb-<hash1>-<hash2>.tgz
                       │        │
                       │        └── hash2 (MOD_HASH): "What does THIS target's source look like?"
                       │            • SHA1 of: this target's .flags + .dep.sha + .smdep.smsha
                       │            • 24 characters
                       │
                       └── hash1 (DEP_MOD_SHA): "What do my DEPENDENCIES look like?"
                           • For each dependency of swss:
                             - git hash-object of dependency's .flags, .dep.sha, .smdep.smsha
                             - dependency's own DEP_MOD_SHA + MOD_HASH (indirectly transitive)
                           • SHA1 of all the above → 24 characters
```

**The transitivity is important**: If `swss` depends on `swss-common`, and `swss-common` depends on `libnl`, then swss's hash1 incorporates swss-common's pre-computed hashes (DEP_MOD_SHA and MOD_HASH), which themselves incorporated libnl's hashes. A change to libnl propagates all the way up. Note: this is not an explicit recursive function call — each target's hashes are computed independently by Make, then included by dependents.

### Step 2: The .flags File

Each target has a `.flags` file that captures environment variables affecting the build:

```makefile
# Generated content of target/debs/bookworm/swss_1.0.0_amd64.deb.flags (conceptual):
SONIC_DEBUGGING_ON=n
CONFIGURED_PLATFORM=vs
CONFIGURED_ARCH=amd64
BUILD_NUMBER=0
...
```

The flags rule is a **double-colon rule with no prerequisites** (`Makefile.cache:551`):
```makefile
$(TARGET_PATH)/%.flags ::
    @echo "$(FLAGS_CONTENT)" > $@.tmp
    @cmp -s $@.tmp $@ || mv $@.tmp $@   ← only updates file if content changed!
    @rm -f $@.tmp
```

Because it's double-colon with no prereqs, Make **always runs this recipe**. But thanks to `cmp -s`, the file's modification timestamp only changes if the flags actually changed. This prevents unnecessary cascading.

### Step 3: The .dep File (SHA of Dependencies)

The `.dep.sha` file records the SHA1 hash of all tracked source files:

```makefile
# rules/swss.dep declares:
SWSS_DEP_FILES = $(SONIC_COMMON_FILES_LIST) rules/swss.mk rules/swss.dep
SWSS_SMDEP_FILES = $(shell git ls-files src/sonic-swss/)
SWSS_DEP_FLAGS = $(SONIC_COMMON_FLAGS_LIST)
```

The build system hashes all files in `_DEP_FILES` + `_SMDEP_FILES` + `_DEP_FLAGS` values into `.dep.sha`. Again, `cmp -s` prevents unnecessary timestamp updates.

### Step 4: LOAD_CACHE (Cache Lookup)

When it's time to build the target (`slave.mk:659`):

```makefile
$(call LOAD_CACHE,$*,$@)
# Expands to roughly:
# 1. Compute hash1 and hash2
# 2. Look for: /var/cache/sonic/artifacts/swss_1.0.0_amd64.deb-<hash1>-<hash2>.tgz
# 3. If found → extract .tgz to target/ → skip build → set $*_CACHE_LOADED=y
# 4. If not found → proceed with normal build
```

### Step 5: Build (if cache miss)

Normal `dpkg-buildpackage` runs inside the Docker slave container.

### Step 6: SAVE_CACHE (After Build)

```makefile
$(call SAVE_CACHE,$*,$@)
# Expands to roughly:
# 1. Compute hash1 and hash2 (same as step 4)
# 2. tar -czf /var/cache/sonic/artifacts/swss_1.0.0_amd64.deb-<hash1>-<hash2>.tgz target/debs/bookworm/swss*.deb
# 3. Also includes any DERIVED_DEBS and EXTRA_DEBS in the tarball
```

### The Critical Question:

**Is the cache key computation COMPLETE?** If the hash1+hash2 captures ALL inputs that affect the build output, then cache hits are guaranteed to produce the same artifact. If any input is MISSING from the hash computation (not tracked in `.dep`), then the cache could serve a stale artifact.

---

<a name="why-checksums-differ"></a>
## 7. Why "Same Code" Doesn't Mean "Same Checksum"

This is the #1 question that comes up. Here's the full explanation:

### The problem:
```bash
# Build swss at 10:00 AM:
sha256sum target/debs/bookworm/swss_1.0.0_amd64.deb
# → a1b2c3d4...

# Build EXACT same source at 11:00 AM:
sha256sum target/debs/bookworm/swss_1.0.0_amd64.deb
# → e5f6g7h8...  ← DIFFERENT HASH! But code is identical!
```

### Why this happens:

| Source of Non-Determinism | Where It Appears | Impact |
|---|---|---|
| **Timestamps** | `.deb` `ar` archive header, `tar` file entries, ELF `.comment` sections | Different hash every build |
| **Build paths** | GCC `-D__FILE__="/tmp/build-1234/src/foo.c"` in debug symbols | Different path each run |
| **File ordering** | `tar` archives list files in filesystem order (non-deterministic on ext4) | Different ordering = different hash |
| **Gzip headers** | Gzip format includes OS byte + timestamp in 10-byte header | Always different |
| **Docker layer IDs** | Docker generates random layer IDs at build time | Always different |
| **SquashFS metadata** | `mksquashfs` embeds creation timestamp | Always different |

### How this cascades:

```
.deb files (timestamps)
  └── Installed into Docker images
        └── docker save | pigz → .gz file (pigz header + layer timestamps)
            └── Loaded into rootfs
                 └── mksquashfs → rootfs.squashfs (squashfs creation timestamp)
                      └── Bundled into .bin installer (archive headers)
```

### What this means for us:

**We CANNOT use raw `sha256sum` as the pass/fail criterion.** Instead, we must:
1. **Unpack** the archives (extract .deb contents, extract Docker filesystem, etc.)
2. **Compare the actual content** (binary code, config files, scripts)
3. **Classify differences** as:
   - **Cosmetic** (timestamps, paths, ordering) → PASS, cache is working correctly
   - **Semantic** (different code, different libraries, different configs) → FAIL, cache key is incomplete

### The "is this safe?" answer:

> "The cached .deb file will have a different SHA256 than a freshly-built .deb file — that's expected and harmless. What matters is that the *executable code and configuration data* inside both files is identical. Our PoC will prove this by extracting the contents and comparing them at the semantic level."

---

<a name="artifact-inventory"></a>
## 8. Complete Artifact Inventory

The SONiC build produces 17 types of artifacts. Here's what each is, whether it's cached, and why:

| # | Type | What Is It? | Cached? | Why/Why Not |
|---|------|-------------|---------|-------------|
| 1 | `SONIC_DPKG_DEBS` | C/C++ packages compiled from submodule source via `dpkg-buildpackage` | ✅ Yes | Main compilation targets — expensive to rebuild |
| 2 | `SONIC_MAKE_DEBS` | Packages built via custom Makefile (not standard debian/rules) | ✅ Yes | Same as above, just different build method |
| 3 | `SONIC_ONLINE_DEBS` | .deb packages downloaded from a URL | ✅ Yes | Avoids re-downloading (URL could be slow/flaky) |
| 4 | `SONIC_COPY_DEBS` | .deb packages copied from a local path | ✅ Yes | Minor optimization (avoids re-copy) |
| 5 | `SONIC_DERIVED_DEBS` | Extra .debs produced as side-effects of building another package | N/A | Bundled in parent's cache tarball |
| 6 | `SONIC_EXTRA_DEBS` | Additional .debs produced by building another package (e.g., `-dev`, `-dbgsym` variants) | N/A | Bundled in parent's cache tarball |
| 7 | `SONIC_MAKE_FILES` | Non-deb outputs (kernel modules, binaries) built via Makefile | ✅ Yes | Similar to MAKE_DEBS but output isn't a .deb |
| 8 | `SONIC_ONLINE_FILES` | Files downloaded from URL (not .deb) | ❌ No | Simple wget — no build step to cache |
| 9 | `SONIC_COPY_FILES` | Files copied from local path | ❌ No | Trivial operation — not worth caching |
| 10 | `SONIC_PYTHON_STDEB_DEBS` | Python packages converted to .deb format via `stdeb` tool | ✅ Yes | Conversion is non-trivial |
| 11 | `SONIC_PYTHON_WHEELS` | Python wheel (.whl) packages built from source | ✅ Yes | pip build can be slow |
| 12 | `SONIC_DOCKER_IMAGES` | Docker images for SONiC services (orchagent, syncd, etc.) | ✅ Yes | Docker builds take 5-30 min each |
| 13 | `SONIC_DOCKER_DBG_IMAGES` | Debug variants of Docker images (with symbols, extra tools) | ✅ Yes | Same as above |
| 14 | `SONIC_SIMPLE_DOCKER_IMAGES` | Simple Docker images (minimal, rarely change) | ❌ No | No LOAD/SAVE_CACHE or dpkg_depend — builds every time |
| 15 | `DOWNLOADED_DOCKER_IMAGES` | Docker images downloaded via wget (rare, platform-specific) | ❌ No | Simple download — no caching needed |
| 16 | `COPY_DOCKER_IMAGES` | Docker images copied from local path (rare — only `docker-dpu-base` on Pensando) | ❌ No | Simple copy — no caching needed |
| 17 | `SONIC_RFS_TARGETS` | Root filesystem (squashfs) — base system | ⚠️ Save only | LOAD is commented out — replaced by RFS split build |
| 18 | `SONIC_INSTALLERS` | Final .bin installer file | ❌ No | Always rebuilt from components (it's the final assembly step) |
| 19 | `SONIC_PHONIES` | Ordering-only targets (no actual output) | ❌ No | Nothing to cache — just `touch` a file for ordering |

### Why is RFS caching disabled?

The RFS (root filesystem) used to be cacheable, but `LOAD_CACHE` was commented out at `slave.mk:1426`. This is intentional — it was replaced by the **RFS split build optimization**:

- **Old approach**: Build the entire rootfs in one step → cache it → restore on next build
- **New approach** (current): Split into 2 stages:
  - Stage 1: Build base system (debootstrap + apt packages) → save as squashfs → runs in PARALLEL with other targets
  - Stage 2: Install SONiC-specific packages + Docker images → produce final rootfs
- The new approach is faster because Stage 1 can run in parallel, and it's more reliable than trying to cache a multi-GB filesystem image.

### What's NOT cached but still matters:

The **final installer** (`.bin`) is never cached but is assembled FROM cached components. So if any component was incorrectly cached (stale), the error propagates silently into the final image. This is why we need to compare at multiple levels — not just individual .debs, but also the final assembled product.

---

<a name="risk-analysis"></a>
## 9. What Could Go Wrong (Risk Analysis)

### Severity Model:

| Severity | What It Means | Example | Action Required |
|----------|--------------|---------|-----------------|
| **P0** | Cache serves wrong code/config | Wrong library version linked in binary | Emergency fix — blocks cache enablement |
| **P1** | Cache key misses a plausible input | Source file not tracked in `.dep` | Must fix before enablement |
| **P2** | Cache key misses low-risk input | Comment-only file not tracked | Fix recommended, doesn't block |
| **P3** | Cosmetic difference only | Timestamp in archive header | Document, no fix needed |
| **P4** | Documentation/tooling gap | Missing `.dep` for uncached target | Nice to have |

### The Big Risks (Semantic — actual bugs if they happen):

**Risk 1: Incomplete `.dep` files (P1)**

This is the #1 risk. If a `.dep` file doesn't list all files that affect the build, the cache key won't change when those files change → stale cache served.

*Example*: If `swss.dep` doesn't track `src/sonic-swss/orchagent/new_feature.cpp` (maybe it was added after the .dep was written), then modifying that file won't invalidate the cache.

*Mitigation*: Most `.dep` files use `git ls-files` which automatically picks up new files. But some use explicit file lists or exclusion patterns (`grep -Ev`).

**Risk 2: Build environment drift (P1)**

The build happens inside a Docker container ("sonic-slave"). If that container's tools/libraries change between when the cache was written and when it's read, the cached artifact might have been compiled with different tool versions.

*Mitigation*: The slave Dockerfiles are tracked in `SONIC_COMMON_BASE_FILES_LIST`. But there's a **known gap**: `sonic-slave-trixie` is NOT in this list. Changes to the Trixie build environment won't invalidate the cache.

**Risk 3: External dependency drift (P1 for local builds, mitigated for CI)**

When building Docker images, `apt-get install` pulls packages from Debian mirrors. If the mirror is live (not frozen), different builds at different times get different versions.

*Mitigation*: 
- CI uses `MIRROR_SNAPSHOT=y` → frozen mirrors → no drift ✅
- Local builds default to `MIRROR_SNAPSHOT=n` → live mirrors → drift possible ⚠️
- The fix: set `SONIC_VERSION_CONTROL_COMPONENTS=all` for local builds too

**Risk 4: Transitive dependency propagation (P1)**

Cache keys incorporate dependencies: if package A depends on package B, A's hash1 includes B's `DEP_MOD_SHA` and `MOD_HASH` (which themselves include B's own dependencies' hashes — making this transitively recursive). So if B's `.dep` is incomplete, B gets a wrong hash → A's hash1 is also wrong → stale A is served.

*Example*: If `swss-common` has an incomplete dep, then `swss` (which depends on `swss-common`) will ALSO get stale cache hits — even if swss's own `.dep` is perfect.

**Risk 5: `slave.mk` excluded from cache keys (P2 — by design)**

The build orchestrator `slave.mk` is intentionally excluded from the cache key (because any change to it would invalidate 100% of all caches). Instead, there's a manual guard:
- `SONIC_CACHE_RECIPE_VER` — a version number that must be manually bumped when slave.mk changes affect build outputs
- A baseline hash check emits warnings if slave.mk changes without a version bump

This is a reasonable tradeoff but relies on human discipline.

### Cosmetic Risks (Not bugs — just noise in our comparison):

- Timestamps in .deb, .whl, .gz files
- Build paths in debug symbols
- Non-deterministic file ordering in tar archives
- Docker layer creation timestamps
- SquashFS creation timestamps
- `stdeb`-generated `debian/changelog` with current timestamp

These will ALL show up as differences in our PoC comparison but are NOT cache defects.

### Known Gaps (Already identified):

1. **`sonic-slave-trixie` missing from `SONIC_COMMON_BASE_FILES_LIST`** — P1, should file PR immediately
2. **7 packages have no `.dep` file** at all — P4 (they're never cached, so no risk, just no benefit)
3. **RFS `LOAD_CACHE` commented out** — by design, replaced with split build
4. **Default version control omits `deb`** — Debian apt packages not pinned by default

---

<a name="the-plan"></a>
## 10. The Plan: 4 Phases

```
Phase 1: Static Analysis
       │
       ▼
Phase 2: Binary Comparison PoC
       │
       ▼
Phase 3: Verification Tooling
       │
       ▼
Phase 4: Documentation
```

| Phase | What |
|-------|------|
| 1 | Read `.dep` files, identify gaps |
| 2 | Run 3 builds, compare artifacts |
| 3 | Build `verify_cache_equivalence.sh` |
| 4 | Document findings and recommendations |

### Complete Script Inventory

Here's a quick-reference of all automation scripts across phases:

| Script | Phase | Purpose | Saves You From... |
|--------|-------|---------|-------------------|
| `audit_dep_completeness.sh` | 1 | Scans all `.dep` files, cross-references against source tree for tracking gaps | Manually reading 50+ dep files and cross-referencing (hours → seconds) |
| `check_common_files.sh` | 1 | Validates `SONIC_COMMON_BASE_FILES_LIST` and `FLAGS_LIST` completeness | Missing new slave containers or build flags |
| `run_poc_builds.sh` | 2 | Orchestrates builds A/B/C with environment locking and cleanup | Forgetting cleanup steps, environment drift between builds |
| `run_negative_controls.sh` | 2 | Runs NC-1 through NC-4 to prove tooling catches real bugs | Trusting results from untested comparison tools |
| `verify_cache_equivalence.sh` | 3 | Deep-compares two build directories, classifies diffs as cosmetic/semantic | Manual file-by-file comparison across hundreds of artifacts |
| `classify_diff.sh` | 3 | Parses diffoscope output, applies whitelist patterns | Manually reviewing every timestamp diff as "is this real?" |
| `dump_cache_keys.sh` | 3 | Shows computed hash1/hash2 and cache status for every target | Guessing why a specific target had cache hit/miss |
| `generate_findings_report.sh` | 4 | Aggregates all phase outputs into a presentation-ready report | Spending days writing up raw data into a readable format |
| `ci_cache_regression_check.sh` | 4 | Lightweight CI check that warns when modified files aren't tracked by `.dep` | Future PRs silently breaking cache correctness |

**Implementation order**: Scripts build on each other. Phase 1 scripts produce data consumed by Phase 2 scripts (e.g., `audit_dep_completeness.sh` finds untracked files that `run_negative_controls.sh` uses for NC-2). Phase 3 scripts consume Phase 2 build outputs. Phase 4 scripts consume everything.

---

<a name="phase-1"></a>
## 11. Phase 1: Static Analysis of Cache Correctness

**Goal**: Find gaps in dependency tracking WITHOUT running any builds.

### What you're doing:
For each cached package, open its `.dep` file and verify it tracks ALL inputs. Think of it like code review but for build dependency declarations.

### How to do it:

**For each `.dep` file** (e.g., `rules/swss.dep`):
1. Look at `_DEP_FILES` — does it include all the Makefile rules that affect this target?
2. Look at `_SMDEP_FILES` — does it capture all source files? (usually `git ls-files` which is comprehensive)
3. Look at `_DEP_FLAGS` — does it include all environment variables that change the build?
4. Look at `_DEPENDS` — are all build-time package dependencies listed?
5. Check for exclusion patterns (like `grep -Ev`) — are the exclusions correct?

### Key audit areas by artifact type:

**1a. C/C++ .deb packages** — Check: source tracking complete? Flags complete? Cross-module deps declared?

**1b. Python wheels** — Check: `setup.py`/`pyproject.toml` tracked? Transitive pip deps pinned? Build tool versions tracked?

**1c. Python stdeb debs** — Same as 1b, plus: stdeb version tracked? (Known: `stdeb` injects timestamps — P3 cosmetic)

**1d. Docker images** — Check: All installed .debs in `_DEPENDS`? Dockerfile.j2 directory fully tracked? Base images (`_LOAD_DOCKERS`) included in key? apt versions pinned?

**1e. Make files** — Check: kernel modules track all source + kernel headers?

**1f. Root filesystem** — Check: `RFS_DEP_FILES` complete? (Mostly academic since LOAD is disabled)

**1g. Cross-cutting** — Check: `sonic-slave-trixie` in common files? `SONIC_CACHE_RECIPE_VER` up to date?

### Automation Scripts for Phase 1:

#### Script: `audit_dep_completeness.sh`

**What it does**: Automatically scans all `rules/*.dep` files and cross-references them against the actual source tree to find tracking gaps.

**How it works**:
1. For each `.dep` file, extracts the `_DEP_FILES`, `_SMDEP_FILES`, `_DEP_FLAGS`, and `_DEPENDS` variables
2. For `_SMDEP_FILES`: Runs `git ls-files` on the package source directory and compares against what the dep file tracks — flags any source files that exist but aren't tracked
3. For `_DEP_FLAGS`: Cross-references against all flags used in the package's build rule (`.mk` file) — flags any flags referenced in the build but not in the `.dep`
4. For `_DEPENDS`: Checks that all packages listed as build dependencies in the `.mk` rule are declared in the `.dep`
5. Outputs a CSV/table of gaps with severity ratings

**Why it's useful**: Manually reading 50+ `.dep` files and cross-referencing against source is tedious and error-prone. This script does in seconds what would take hours manually, and can be re-run after fixes to verify they're complete.

**Example output**:
```
PACKAGE              | ISSUE                                    | SEVERITY
swss                 | Missing flag: SONIC_ENABLE_SYNCD_RPC     | P2
sonic-platform-common| grep -Ev excludes sfp/eeprom             | P2-verify
docker-orchagent     | dep swss not in _DEPENDS                 | P1
```

---

#### Script: `check_common_files.sh`

**What it does**: Validates that `SONIC_COMMON_BASE_FILES_LIST` and `SONIC_COMMON_FLAGS_LIST` in `Makefile.cache` are complete relative to the actual build environment.

**How it works**:
1. Scans for all `sonic-slave-*` directories and checks each is listed in `SONIC_COMMON_BASE_FILES_LIST`
2. Scans `slave.mk` and `Makefile.cache` for all `$(...)` variable references that affect build output, checks each is in `SONIC_COMMON_FLAGS_LIST`
3. Validates `SONIC_CACHE_RECIPE_VER` by checking if `slave.mk` has changed since the last version bump (using git blame)
4. Reports any missing entries

**Why it's useful**: The `sonic-slave-trixie` gap we already know about was found this way. This script catches similar drift as new Debian codenames or build flags are added over time.

---

### Deliverable:
A table like:

| Package | Issue Found | Severity | Fix |
|---------|------------|----------|-----|
| sonic-slave-trixie | Missing from SONIC_COMMON_BASE_FILES_LIST | P1 | Add to Makefile.cache |
| sonic-platform-common | `grep -Ev` excludes sfp/eeprom — might affect output | P2 | Verify exclusions correct |
| docker-orchagent | apt packages inside not version-pinned when deb not in VERSION_CONTROL | P1 (local builds) | Recommend SONIC_VERSION_CONTROL_COMPONENTS=all |

---

<a name="phase-2"></a>
## 12. Phase 2: Binary Comparison PoC

**Goal**: Actually run builds and compare the outputs.

### The three builds:

| Build | Cache Setting | Purpose |
|-------|--------------|---------|
| **Build A** | `SONIC_DPKG_CACHE_METHOD=none` | Baseline — "what does a normal build produce?" |
| **Build B** | `SONIC_DPKG_CACHE_METHOD=wcache` | Write cache — "populate the cache for the first time" |
| **Build C** | `SONIC_DPKG_CACHE_METHOD=rcache` | Read cache — "use the cache to skip building" |

### What we compare:
- **Build B vs Build C**: These should produce functionally identical artifacts (same code built them both; C just loaded B's output from cache instead of rebuilding)
- **Build A vs Build B**: These might differ slightly (different cache mode = different code paths in slave.mk), but the semantic content should be the same

### Environment lockdown (CRITICAL):

Before EACH build, record:
```bash
git rev-parse HEAD                          # Same commit
git submodule status --recursive            # Same submodule versions
cat rules/config rules/config.user          # Same config
docker images | grep sonic-slave            # Same build slave image
echo $SONIC_DPKG_CACHE_METHOD              # The variable we're testing
echo $SONIC_VERSION_CONTROL_COMPONENTS     # Should be 'all' for PoC
echo $SONIC_VERSION_CACHE_METHOD           # Should be 'cache' for PoC
echo $MIRROR_SNAPSHOT                       # Should be 'y' for PoC
uname -m                                    # Same architecture
```

**If ANY of these differ between builds, differences in artifacts are NOT evidence of a DPKG cache bug.** They're environment drift.

### Recommended PoC configuration:
```bash
# In rules/config.user (or via make command line):
SONIC_DPKG_CACHE_METHOD = <varies per build>
SONIC_VERSION_CONTROL_COMPONENTS = all      # Pin EVERYTHING
SONIC_VERSION_CACHE_METHOD = cache          # Cache external downloads
MIRROR_SNAPSHOT = y                         # Frozen Debian mirrors
PLATFORM = vs                               # Virtual Switch (fastest)
```

This isolates the DPKG cache as the ONLY variable.

### Cleanup between Build B and Build C:

Build C must start from a clean artifact tree so it actually exercises the cache LOAD path:
```bash
# Remove built artifacts (forces cache lookup)
rm -rf target/debs/ target/python-wheels/ target/python-debs/
rm -rf target/*.gz target/sonic-vs.*
rm -rf target/files/

# Remove tracking files (forces .flags/.dep regeneration)
find target/ -name "*.flags" -o -name "*.dep" -o -name "*.dep.sha" \
     -o -name "*.smdep" -o -name "*.smdep.smsha" | xargs rm -f

# Remove Docker images from daemon (safety measure)
docker system prune -a --force
```

**Note on Docker `--no-cache`**: SONiC builds already use `docker build --no-cache` by default (`slave.mk:360`). This means Docker's own layer cache won't mask DPKG cache failures. But running `docker system prune -a` is an extra safety measure.

### Comparison levels:

After Build B and Build C complete, compare at increasing levels of integration:

| Level | What to Compare | Tool | Expected Result |
|-------|----------------|------|-----------------|
| 1 | Individual .deb files | diffoscope | Timestamp diffs only (cosmetic) |
| 2 | Python .whl files | unzip + diff | Identical .py source, maybe .pyc timestamp diffs |
| 3 | Docker .gz images | container-diff | Same packages, same files, different layer timestamps |
| 4 | Root filesystem | unsquashfs + diff -r | Same installed packages, different FS timestamps |
| 5 | Final installer .bin | extract + recursive diff | Integration check of all the above |

### Negative control tests (Phase 2b):

These tests prove our comparison tooling WORKS — that it would catch real bugs:

| Test | What We Do | What Should Happen |
|------|-----------|-------------------|
| **NC-1** | Modify a file tracked in `.dep` | Cache MISS → full rebuild → proves .dep tracking works |
| **NC-2** | Modify a file NOT tracked in `.dep` | Cache HIT (stale!) → our tooling should detect the semantic diff |
| **NC-3** | Change a build flag in SONIC_COMMON_FLAGS_LIST | Cache key changes → MISS → proves flags are tracked |
| **NC-4** | Change a Dockerfile input | Docker cache key changes → MISS → proves Docker tracking works |

**NC-2 is the most important**: It simulates the exact failure mode we're worried about. If our tooling catches it, we know the tooling works.

### Automation Scripts for Phase 2:

#### Script: `run_poc_builds.sh`

**What it does**: Orchestrates all three PoC builds (A, B, C) with proper environment locking and cleanup between them.

**How it works**:
1. **Pre-flight checks**: Validates git state (clean tree, correct branch), records environment snapshot (git SHA, submodule status, rules/config, arch, etc.) to `poc-env-snapshot.json`
2. **Build A** (`SONIC_DPKG_CACHE_METHOD=none`): Runs `make configure PLATFORM=vs` then `make target/sonic-vs.bin` with caching disabled. Copies all artifacts to `poc-results/build-A/`
3. **Build B** (`SONIC_DPKG_CACHE_METHOD=wcache`): Same build but writes to cache directory. Copies artifacts to `poc-results/build-B/`
4. **Cleanup between B and C**: Removes all built artifacts (`target/debs/`, `target/python-wheels/`, etc.), tracking files (`.flags`, `.dep`, `.dep.sha`), and Docker images (`docker system prune -a --force`)
5. **Build C** (`SONIC_DPKG_CACHE_METHOD=rcache`): Reads from cache, loading Build B's output. Copies artifacts to `poc-results/build-C/`
6. Records timing data for each build (proves speedup)
7. Generates `poc-results/manifest.json` listing every artifact with sha256, path, and build origin

**Why it's useful**: Running 3 controlled builds with proper environment locking is fiddly. One mistake (forgetting to clean between B and C, Docker layer cache leaking, environment drift) invalidates the experiment. This script enforces the protocol.

**Key flags**:
```bash
./run_poc_builds.sh --platform vs --cache-dir /tmp/sonic-cache \
    --version-control all --mirror-snapshot y \
    --output-dir ./poc-results
```

**Safety features**:
- Aborts if working tree is dirty
- Compares environment snapshots before each build; aborts if drift detected
- Forces `docker build --no-cache` (already default, but enforced)
- Logs everything to `poc-results/build-{A,B,C}.log`

---

#### Script: `run_negative_controls.sh`

**What it does**: Automates the 4 negative control tests (NC-1 through NC-4) that validate our comparison tooling actually catches real bugs.

**How it works**:
1. **NC-1** (tracked file change): 
   - Picks a target (e.g., `sonic-utilities`)
   - Adds a comment to a tracked source file
   - Runs build with `rcache` → expects cache MISS (hash changed)
   - Reverts the change
2. **NC-2** (untracked file change):
   - Identifies a file NOT listed in any `.dep` (uses output from `audit_dep_completeness.sh`)
   - Modifies that file (adds a string)
   - Runs build with `rcache` → expects cache HIT (stale!)
   - Compares artifact content with `diffoscope` → expects semantic difference detected
   - Reverts the change
3. **NC-3** (flag change):
   - Changes `SONIC_DEBUGGING_ON` value
   - Runs build → expects cache MISS (flag in common FLAGS_LIST)
   - Reverts
4. **NC-4** (Dockerfile input change):
   - Adds a comment to a Dockerfile.j2
   - Runs build → expects cache MISS (Dockerfile tracked in dep)
   - Reverts

**Why it's useful**: Proves our tooling isn't just showing "everything passes" because it can't detect differences. If NC-2 passes (detects the semantic diff from stale cache), we know the tooling is trustworthy. If NC-1/NC-3/NC-4 fail (cache miss as expected), we know the hash mechanism works.

**Output format**:
```
NC-1: PASS — Tracked file change triggered cache miss (expected)
NC-2: PASS — Untracked file change produced stale hit, diffoscope detected semantic diff
NC-3: PASS — Flag change triggered cache miss (expected)  
NC-4: PASS — Dockerfile change triggered cache miss (expected)
```

---

<a name="phase-3"></a>
## 13. Phase 3: Verification Tooling

**Goal**: Build a script (`verify_cache_equivalence.sh`) that automates the comparison.

### Script structure:
```bash
verify_cache_equivalence.sh
├── compare_debs()        # Level 1: .deb comparison
├── compare_wheels()      # Level 2: .whl comparison
├── compare_dockers()     # Level 3: Docker image comparison
├── compare_rfs()         # Level 4: Root filesystem comparison
├── compare_installer()   # Level 5: Final .bin comparison
└── generate_report()     # Summary: pass/fail with classifications
```

### For each comparison function:
1. Find matching filenames in both build directories
2. Raw SHA256 comparison (record but don't fail on this)
3. Deep comparison using appropriate tool (diffoscope, container-diff, diff -r)
4. Classify each difference as cosmetic (P3) or semantic (P0-P1)
5. Fail the script if any semantic differences found

### Performance guardrails:
- `diffoscope --max-report-size 50000000` (50MB report limit)
- Hard timeout per file: 300 seconds
- For large files (rootfs, installer): use `diff -r` first to find specific changed files, THEN target `diffoscope` at just those files
- For Docker images: prefer `container-diff` (faster) over `diffoscope` (comprehensive but slow)

### Known cosmetic patterns to whitelist:
- Timestamp fields in ar/tar/pigz headers
- `Created` field in Docker image JSON config
- Build path strings in ELF .comment or .debug sections
- File ordering differences in tar archives
- `.pyc` magic number timestamps
- `stdeb`-generated `debian/changelog` dates

### Exit code:
- `0` = all differences are cosmetic (PASS — cache is safe)
- `1` = semantic differences found (FAIL — cache has bugs)
- `2` = script error / environment issue

### Detailed Script Descriptions for Phase 3:

#### Script: `verify_cache_equivalence.sh` (the main comparison tool)

**What it does**: Takes two build output directories (e.g., `poc-results/build-B/` and `poc-results/build-C/`) and produces a comprehensive equivalence report.

**How it works — each comparison function in detail**:

##### `compare_debs(dir_a, dir_b)`
1. Finds all `.deb` files in both directories using `find ... -name "*.deb"`
2. For each matching pair:
   - Quick SHA256 check — if identical, mark PASS and skip
   - If different, extract both with `ar x` into temp dirs
   - Compare `data.tar.*` contents (file-by-file) stripping timestamps
   - Compare `control.tar.*` (package metadata)
   - Use `diffoscope --max-report-size 10000000 --max-diff-block-lines 100` for detailed diff
3. Classifies differences:
   - **Cosmetic**: `ar` header timestamps, `control/md5sums` ordering, `debian-binary` (always "2.0\n")
   - **Semantic**: Different file content in `data.tar`, different `control` fields (Version, Depends)

##### `compare_wheels(dir_a, dir_b)`
1. Finds all `.whl` files (which are just ZIP archives)
2. For each pair:
   - Quick SHA256 check
   - If different, `unzip` both into temp dirs
   - Compare `.py` source files directly (`diff`)
   - Compare `.dist-info/METADATA` and `.dist-info/RECORD`
   - Flag `.pyc` differences as cosmetic (timestamp-dependent bytecode cache)
   - Flag `RECORD` hash differences as cosmetic IF the underlying `.py` is identical

##### `compare_dockers(dir_a, dir_b)`
1. Finds all `.gz` Docker image archives
2. For each pair:
   - `docker load -i` both images (into different tags)
   - Run `container-diff diff` to get apt/pip/file layer diffs
   - Normalize `docker inspect` output (strip `Created`, `Id`, `RepoDigests`)
   - Compare layer-by-layer: extract each layer tar, `diff -r` their contents
   - Flag known cosmetic: Docker config timestamps, layer diff IDs, manifest digest
   - **Semantic check**: If `container-diff` shows different installed packages → P0 failure

##### `compare_rfs(dir_a, dir_b)`
1. Extracts squashfs from both rootfs images: `unsquashfs -d /tmp/rfs-a rfs-a.squashfs`
2. Runs `diff -rq /tmp/rfs-a /tmp/rfs-b` for quick file list comparison
3. For any differing files, uses `diffoscope` targeted at just those specific files
4. Whitelists: `/etc/buildinfo/`, FS creation timestamps in superblock

##### `compare_installer(dir_a, dir_b)`
1. Extracts the `.bin` ONIE installer (it's a self-extracting shell script + payload)
2. Separates the shell header from the compressed payload
3. Decompresses the payload, compares inner filesystem recursively
4. This is an integration check — most issues should already be caught at levels 1-4

##### `generate_report()`
1. Aggregates all comparison results into `equivalence-report.json` and `equivalence-report.md`
2. Summary format:
```
=== DPKG Cache Equivalence Report ===
Build B: /path/to/build-B (2026-05-21 14:30 UTC)
Build C: /path/to/build-C (2026-05-21 16:45 UTC)

Level 1 (Debs):    47/47 PASS (23 byte-identical, 24 cosmetic-only diffs)
Level 2 (Wheels):  12/12 PASS (8 byte-identical, 4 cosmetic-only diffs)
Level 3 (Docker):  15/15 PASS (0 byte-identical, 15 cosmetic-only diffs)
Level 4 (RFS):     1/1  PASS (cosmetic-only diffs in timestamps)
Level 5 (Installer): 1/1 PASS

OVERALL: PASS ✅ — All differences classified as cosmetic.
```
3. For failures, includes the specific files and diffs that triggered semantic classification

---

#### Script: `classify_diff.sh` (helper — called by verify_cache_equivalence.sh)

**What it does**: Takes a `diffoscope` JSON report and classifies each difference as cosmetic or semantic using pattern matching.

**How it works**:
1. Parses `diffoscope` JSON output
2. For each difference block, matches against whitelist patterns:
   - `/^[0-9]+ seconds since epoch/` → cosmetic (ar timestamp)
   - `/Created.*20[0-9]{2}-/` → cosmetic (Docker creation date)
   - `/Build-Date:/` → cosmetic (deb build date)
   - `/^.pyc.*magic/` → cosmetic (pyc header)
   - `/debian\/changelog.*Date:/` → cosmetic (stdeb timestamp)
3. Any difference NOT matching a whitelist pattern → classified as semantic → raises alert

**Why it's a separate script**: Keeps the classification rules modular and easy to extend as we discover new cosmetic patterns during the PoC.

---

#### Script: `dump_cache_keys.sh` (debugging helper)

**What it does**: For every target in a build, dumps the computed cache key components (hash1, hash2, expected filename) so you can trace exactly WHY a cache hit/miss happened.

**How it works**:
1. Invokes Make in dry-run mode with special debug output enabled
2. For each target, computes and displays:
   - The `.flags` file content
   - The `.dep.sha` hash
   - The `.smdep.smsha` hash
   - The computed `MOD_HASH` (hash2)
   - All dependency targets and their `DEP_MOD_SHA` values
   - The computed `DEP_MOD_SHA` (hash1)
   - The expected cache filename: `<target>-<hash1>-<hash2>.tgz`
   - Whether that file exists in the cache directory

**Why it's useful**: When a cache hit/miss is unexpected, this script tells you exactly which input changed. Instead of guessing "why did swss rebuild?", you see "hash2 changed because .dep.sha changed because file X was modified".

**Example output**:
```
TARGET: swss_1.0.0_amd64.deb
  MOD_HASH (hash2):     a1b2c3d4e5f6g7h8i9j0k1l2
  DEP_MOD_SHA (hash1):  x1y2z3a4b5c6d7e8f9g0h1i2
  CACHE FILE:           swss_1.0.0_amd64.deb-x1y2z3a4b5c6d7e8f9g0h1i2-a1b2c3d4e5f6g7h8i9j0k1l2.tgz
  CACHE STATUS:         HIT (file found in /tmp/sonic-cache/)
  DEPENDENCIES:
    libswsscommon_1.0.0_amd64.deb  DEP_MOD_SHA=... MOD_HASH=...
    libnl-3-200_3.5.0_amd64.deb   DEP_MOD_SHA=... MOD_HASH=...
```

---

<a name="phase-4"></a>
## 14. Phase 4: Documentation & Recommendations

**Goal**: Document findings with clear, evidence-backed recommendations.

### Deliverables:
1. **Gap list**: Which `.dep` files are incomplete (with fixes)
2. **PoC results**: Evidence that cached vs non-cached artifacts are functionally identical
3. **Recommendation matrix**:

| Scenario | Recommendation |
|----------|---------------|
| 0 semantic differences found | ✅ "Safe to enable. All outputs are functionally identical." |
| Semantic diffs found, all in fixable `.dep` files | ⚠️ "Fix N `.dep` files (see list), then re-validate." |
| Systematic issues (environment drift, unfixable gaps) | ❌ "Additional infrastructure changes needed before enablement." |

4. **Ongoing CI proposal**: Run `verify_cache_equivalence.sh` weekly or on-demand to catch regressions
5. **Build time savings**: "Build A took X hours. Build C took Y minutes. Speedup: Z×."

### Automation Scripts for Phase 4:

#### Script: `generate_findings_report.sh`

**What it does**: Collects all outputs from Phases 1-3 and generates a consolidated findings report (Markdown + JSON) suitable for presentation or PR submission.

**How it works**:
1. Reads `audit_dep_completeness.sh` output → generates the gap table
2. Reads `poc-results/manifest.json` → generates timing summary and speedup calculation
3. Reads `equivalence-report.json` → generates pass/fail summary with links to detailed diffs
4. Reads negative control test results → generates validation proof section
5. Combines into `cache-analysis-findings.md`:
   - Executive summary (1 paragraph)
   - Gap table (Phase 1 results)
   - Build timing comparison (Phase 2 results)
   - Equivalence results (Phase 3 results)
   - Negative control validation
   - Recommendation (based on decision matrix above)
   - Proposed `.dep` fixes (patches or PRs to submit)

**Why it's useful**: After spending days running builds and comparisons, you don't want to spend more days writing up results. This script turns raw data into a presentable report automatically.

---

#### Script: `ci_cache_regression_check.sh` (for ongoing CI integration)

**What it does**: A lightweight version of the full PoC that can run in CI to catch cache regressions on every PR.

**How it works**:
1. Takes a PR's changeset (list of modified files)
2. Identifies which `.dep` files should have changed based on modified source files
3. If modified source files are NOT covered by any `.dep`, raises a warning:
   ```
   WARNING: Modified file src/sonic-swss/orchagent/new_feature.cpp 
   is not tracked by any .dep file. Cache may serve stale artifacts.
   ```
4. Optionally: runs a targeted build of affected packages with `wcache`/`rcache` and does Level 1 comparison

**Why it's useful**: Prevents FUTURE regressions. Once we prove the cache works today, this script ensures new code contributions don't silently break cache correctness by adding source files without updating `.dep` tracking.

**Integration**: Add as a GitHub Action or Azure Pipeline step that runs on PRs modifying files under `src/` or `rules/`.

---

<a name="references"></a>
## 15. Key References

| Resource | What It Is | Where |
|----------|-----------|-------|
| Cache framework implementation | The core code that computes cache keys and loads/saves | `Makefile.cache` |
| Build orchestrator | Where LOAD_CACHE/SAVE_CACHE are called | `slave.mk` |
| Per-package dependency tracking | What each package considers its inputs | `rules/*.dep` |
| Cache configuration | Where you enable/disable caching | `rules/config` (lines 149-157) |
| Version control config | Pinning external dependencies | `rules/config` (lines 317-346) |
| Version pinning files | Actual pinned versions for each component | `files/build/versions/` |
| Build hooks (pip/apt wrappers) | How pip/apt are constrained | `src/sonic-build-hooks/` |
| PR that introduced caching | Original design and motivation | [PR #4117](https://github.com/sonic-net/sonic-buildimage/pull/4117) |
| DPKG caching framework doc | Official design doc (pptx) | [SONiC docs](https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/DPKG%20caching%20framework%20.pptx) |
| Reproducible Build doc | Version pinning framework | [SONiC docs](https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/SONiC-Reproduceable-Build.md) |
| Build enhancements doc | Version cache + build optimizations | [SONiC docs](https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/build-enhancements.md) |
| RFS split build doc | Why RFS caching was disabled | [SONiC docs](https://github.com/sonic-net/SONiC/blob/master/doc/sonic-build-system/rfs-split-build-improvement.md) |
| Azure CI config | CI pipeline settings | `.azure-pipelines/template-variables.yml` |
| diffoscope | Deep archive comparison tool | [diffoscope.org](https://diffoscope.org/) |
| container-diff | Docker image comparison tool | [GitHub](https://github.com/GoogleContainerTools/container-diff) |
| Debian Reproducible Builds | Industry context | [reproducible-builds.org](https://reproducible-builds.org/) |

---

<a name="faq"></a>
## 16. FAQ / Likely Questions

### Q: "Why can't we just compare SHA256 hashes? If they're different, doesn't that mean the cache is wrong?"

**A**: No. Even building the exact same source code twice in a row produces different hashes because `.deb` files embed timestamps, build paths, and non-deterministic file ordering. This is a well-known industry problem called "reproducible builds." The correct approach is to unpack the archives and compare the actual executable code and configuration — ignoring cosmetic metadata.

### Q: "If the hashes are always different, how do we KNOW the cache is correct?"

**A**: We use semantic comparison: extract the binary code (`.text` section of ELFs), the installed files, the configuration, the package manifests — and compare THOSE. If the code and config are identical, the cache is correct even if the overall file hash differs. Our verification script automates this classification.

### Q: "What about supply chain security? Can't a bad actor poison the cache?"

**A**: The cache key is a cryptographic hash of ALL tracked inputs. To poison the cache, an attacker would need to either:
1. Modify the cache storage directly (protected by filesystem permissions / CI access controls)
2. Find a hash collision (computationally infeasible with SHA1/SHA256)
3. Exploit an incomplete `.dep` file (which is what Phase 1 audits for)

Additionally, if the team wants stronger guarantees, we can add a signature/verification step to the cache save/load process.

### Q: "How much faster is it really?"

**A**: Based on the `build-enhancements.md` doc and PR #4117:
- Full build from scratch: 2-6 hours (depends on platform and parallelism)
- With DPKG cache + Version cache: ~5 minutes (Buster measurement)
- Speedup: **40-70×** for subsequent builds where source hasn't changed

### Q: "What if we find semantic differences?"

**A**: Each difference will be traced to a specific `.dep` file that's missing an input. The fix is simple: add the missing file/flag to the `.dep` file. Then re-run the comparison to verify. This is a targeted fix, not a system redesign.

### Q: "Why hasn't anyone done this validation before?"

**A**: The caching framework was introduced in 2019 (PR #4117) and has been used by some teams. The framework itself is well-designed. What's missing is a formal validation that gives the broader team confidence. This analysis fills that gap.

### Q: "What's the risk of enabling caching NOW without this analysis?"

**A**: The main risk is that a stale cache could serve an outdated artifact (due to incomplete `.dep` tracking). This would manifest as subtle bugs that are hard to debug because the developer made a code change, but the cached artifact doesn't reflect it. The developer would be confused ("I changed this code, why isn't it working?"). Our analysis eliminates this risk by finding and fixing tracking gaps first.

### Q: "What's `SONIC_CACHE_RECIPE_VER` and why does it matter?"

**A**: It's a manual version number (`Makefile.cache:82-105`) that acts as a "global cache invalidation switch." When someone changes `slave.mk` in a way that affects build outputs (not just ordering or logging), they should bump this number — which invalidates ALL cached artifacts. It's a safety net for changes that aren't captured by individual `.dep` files. The risk is that someone forgets to bump it.

### Q: "We use Azure Pipelines for CI. Does caching work there?"

**A**: Yes. Azure CI already sets `MIRROR_SNAPSHOT=y` (frozen mirrors) and has infrastructure for cache storage. The DPKG cache can be stored as a CI artifact or in Azure Blob Storage. The pipeline templates in `.azure-pipelines/` already have variables for cache configuration.

### Q: "What about the Version Cache vs DPKG Cache? Do we need both?"

**A**: They solve different problems:
- **DPKG Cache** = "don't recompile if source hasn't changed" (saves compilation time)
- **Version Cache** = "don't re-download if we already have it" (saves network time, avoids flaky downloads)
- You can use either independently. Using both together gives maximum speed improvement.
- Our analysis focuses on DPKG Cache correctness. Version Cache is simpler (just stores exact downloaded files) and doesn't have the same "stale artifact" risk.

