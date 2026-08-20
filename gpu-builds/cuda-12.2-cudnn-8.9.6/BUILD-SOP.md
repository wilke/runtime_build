# SOP: Building the Folding Container

Standard operating procedure for building the all-in-one protein structure
prediction container (AlphaFold, Chai, Boltz, ESMFold, predict-structure).

## Build approaches

There are three ways to build this container:

0. **Incremental refresh** ([documented first](#incremental-refresh-the-usual-case)) —
   the sandbox at `/scout/tmp/all-sandbox` already exists from the last build;
   update only the code that changed and repack. **This is what almost every
   rebuild actually is.** Steps 3–4a below use `conda create` and will fail on an
   existing env, so do not start there for a routine rebuild.

1. **Layered build** (Steps 1–9) — extract a base SIF, install tools into a
   fresh sandbox, repack. Use when adding a tool or starting from a new base.

2. **Full rebuild** from `all-build.def` (documented at the end) — everything
   from scratch starting at `nvidia/cuda:12.2.0-devel-ubuntu22.04`. Requires the
   `{{runtime}}` tarball and `{{packages}}` list.

All three have been used; the incremental path is the one exercised most.

---

## Incremental refresh (the usual case)

The sandbox persists between builds. A routine rebuild is: update the Python
packages, redeploy the Perl app + app specs, verify, stamp, repack.

### 1. Refresh the Python packages

```bash
APPTAINER_TMPDIR=/scout/tmp apptainer exec --fakeroot --writable /scout/tmp/all-sandbox /bin/bash -c '
set -e
. /opt/miniforge/etc/profile.d/conda.sh
conda activate /opt/conda-predict
pip install --no-cache-dir --force-reinstall --no-deps \
  "predict-structure @ git+https://github.com/CEPI-dxkb/PredictStructureApp.git@main"
pip install --no-cache-dir --force-reinstall --no-deps \
  "protein_compare @ git+https://github.com/wilke/protein_structure_analysis.git@main"
pip cache purge
'
```

`--force-reinstall` is mandatory: pip considers an identical version already
satisfied and would silently keep the old code. `--no-cache-dir` defeats the
wheel cache, which has served stale builds before. Refresh **both** packages —
report fixes (histograms, TOC, PAE rendering) ship through `protein_compare`,
not through `predict-structure`.

### 2. Verify by CONTENT, never by version

Neither package bumps its version per commit, so `--version` and `pip show`
prove nothing. Grep for a marker unique to the change you are shipping, from a
neutral cwd (`apptainer` binds `$HOME` and the cwd, so checking from a checkout
can find the package on `sys.path` instead of in the image):

```bash
cd /tmp && apptainer exec /scout/tmp/all-sandbox /bin/bash -c '
SP=/opt/conda-predict/lib/python3.12/site-packages
grep -c "<a symbol your change introduced>" $SP/predict_structure/<file>.py
'
```

### 3. Then continue at [Step 4b](#step-4b-deploy-the-perl-app--app_specs-always)

Step 4b (Perl + app specs), Step 5 (verify), Step 6 (stamp), Step 7 (repack),
Step 8 (deploy). Steps 1–4a are for fresh sandboxes only.

---

## Prerequisites

- Apptainer 1.4+
- Access to the base SIF (e.g. `/scout/containers/all-2026-0224b.sif`)
- Local scratch disk with ~120 GB free (NFS home dirs will not work for builds)
- No sudo required

## Overview

The build uses a sandbox (extracted directory) approach because `apptainer build
--fakeroot` cannot reliably extract large SIF files due to UID/GID mapping
failures. The workflow is:

1. Extract the base SIF to a sandbox using `unsquashfs`
2. Install new tools into the sandbox using `apptainer exec --writable`
3. Verify all tools
4. Repack the sandbox into a new SIF
5. Deploy to `/scout/containers/` with symlinks

## Step 1: Find the squashfs offset in the base SIF

```bash
apptainer sif list /scout/containers/all-2026-0224b.sif
```

Look for the `FS (Squashfs)` entry and note the start position (e.g. `81920`).

## Step 2: Extract the base SIF to a sandbox

```bash
/usr/libexec/apptainer/bin/unsquashfs \
    -offset 81920 \
    -d /scout/tmp/all-sandbox \
    /scout/containers/all-2026-0224b.sif
```

This takes ~5 minutes and produces an ~80 GB directory. Exit code 2 from xattr
warnings is expected and harmless.

Verify the extraction:

```bash
ls /scout/tmp/all-sandbox/etc/hosts
ls /scout/tmp/all-sandbox/opt/conda-boltz/bin/boltz
ls /scout/tmp/all-sandbox/opt/conda-chai/bin/chai-lab
ls /scout/tmp/all-sandbox/opt/conda-alphafold/bin/python
```

## Step 3: Install ESMFold

```bash
APPTAINER_TMPDIR=/scout/tmp apptainer exec --fakeroot --writable \
    /scout/tmp/all-sandbox /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export CONDA_PLUGINS_AUTO_ACCEPT_TOS="yes"

conda_dir=/opt/conda-esmfold
. /opt/miniforge/etc/profile.d/conda.sh

conda create -p $conda_dir --yes --quiet python=3.11
conda activate $conda_dir

pip install torch>=2.0 --index-url https://download.pytorch.org/whl/cu121
pip install --no-cache-dir "git+https://github.com/wilke/ESMFoldApp.git#subdirectory=esm_hf"

conda clean --all --force-pkgs-dirs --yes
pip cache purge
'
```

## Step 4: Install predict-structure CLI

Mirrors `reqts-predict-structure.def` — **that def is the source of truth**; if
the two disagree, the def wins and this block should be corrected.

Note the two installs: `predict-structure[all]` and `protein_compare`. The
container needs both — `protein_compare` renders every HTML report, and the
service script calls it directly (`python -m protein_compare characterize`).

```bash
APPTAINER_TMPDIR=/scout/tmp apptainer exec --fakeroot --writable \
    /scout/tmp/all-sandbox /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export CONDA_PLUGINS_AUTO_ACCEPT_TOS="yes"

conda_dir=/opt/conda-predict
. /opt/miniforge/etc/profile.d/conda.sh

conda create -p $conda_dir --yes --quiet python=3.12
conda activate $conda_dir

pip install --no-cache-dir "predict-structure[all] @ git+https://github.com/CEPI-dxkb/PredictStructureApp.git"
pip install --no-cache-dir "git+https://github.com/wilke/protein_structure_analysis.git"

ln -sf $conda_dir/bin/predict-structure /usr/local/bin/predict-structure

conda clean --all --force-pkgs-dirs --yes
pip cache purge
'
```

## Step 4a: Install ESMFold2 (Biohub diffusion model)

Mirrors `reqts-esmfold2.def`. Creates `/opt/conda-esmfold2` and installs the
Biohub `esm` package. **Do NOT install `predict-structure` into this env** —
the runner is invoked by file path from the conda-predict installation
(`{runner:...}` in tools.yml), so a copy here would never be imported. Its
presence is worse than useless: the old `-m` invocation imported it, rebuilds
only refreshed conda-predict, and it silently ran June's code for two months
(PredictStructureApp#98).

```bash
APPTAINER_TMPDIR=/scout/tmp apptainer exec --fakeroot --writable \
    /scout/tmp/all-sandbox /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export CONDA_PLUGINS_AUTO_ACCEPT_TOS="yes"

conda_dir=/opt/conda-esmfold2
. /opt/miniforge/etc/profile.d/conda.sh

conda create -p $conda_dir --yes --quiet python=3.12 pip
conda activate $conda_dir

pip install --no-cache-dir "torch>=2.6"
pip install --no-cache-dir "esm @ git+https://github.com/Biohub/esm.git@main"

conda clean --all --force-pkgs-dirs --yes
pip cache purge
'
```

**Mandatory post-step check** — run from a neutral cwd (apptainer binds $HOME
and the repo cwd by default, so a naive check from the checkout falsely "finds"
the package via sys.path):

```bash
cd /tmp && apptainer exec /scout/tmp/all-sandbox /bin/bash -c '
n=$(ls -d /opt/conda-*/lib/python3.*/site-packages/predict_structure 2>/dev/null \
    | xargs -r readlink -f | sort -u | wc -l)
[ "$n" = "1" ] && echo "OK: single predict_structure install" \
    || { echo "FATAL: $n real installs — PredictStructureApp#98 hazard"; exit 1; }'
```

## Step 4b: Deploy the Perl app + app_specs (ALWAYS)

**Run this on every build, without deciding whether it is needed.** It was
written as conditional ("when App-PredictStructure changes"), and the result was
that Python-only builds skipped it and the container shipped a **June app spec
beside an August checkout for two months** (PredictStructureApp#110). The copy
costs a second; judging whether it is needed costs a production bug. The
verification at the end of this step is what makes the mistake impossible to
ship silently.

**Steps 3–4a only update the Python `predict-structure` package.** The BV-BRC
service entrypoint is a *Perl* script, `App-PredictStructure.pl`, deployed
separately at `/opt/p3/deployment/plbin/`. A Python reinstall does **not** touch
it, so app-layer changes (preflight contract, upload behavior, report wiring)
never reach the running container unless you redeploy it here.

The container carries these files in **three** places. Only the deployed copies
are read at runtime, which is exactly why a stale one hides:

| Path | Who reads it |
|---|---|
| `/opt/p3/deployment/plbin/App-PredictStructure.pl` | **the running job** |
| `/opt/p3/deployment/services/app_service/app_specs/` | **the AppService registry** |
| `/build/dev_container/modules/PredictStructureApp/` | `stamp-labels.sh` provenance |
| `/kb/module/` | `reqts-bvbrc-service.def` fallback copy |

The deploy mechanism is a plain copy (`make deploy-service-scripts` is just
`cp` + a wrapper, and the wrapper already exists), so copy the files directly
from a clean checkout of PredictStructureApp `main`:

```bash
SB=/scout/tmp/all-sandbox

# clean checkout of main (the clone persists between builds -- refresh it)
if [ -d /scout/tmp/psa-main/.git ]; then
    git -C /scout/tmp/psa-main fetch -q origin main
    git -C /scout/tmp/psa-main reset -q --hard origin/main
else
    git clone -q --depth 1 https://github.com/CEPI-dxkb/PredictStructureApp.git /scout/tmp/psa-main
fi

# 1. the service script (the wrapper /opt/p3/deployment/bin/App-PredictStructure
#    already execs this path — no regeneration needed)
cp /scout/tmp/psa-main/service-scripts/App-PredictStructure.pl \
   $SB/opt/p3/deployment/plbin/App-PredictStructure.pl
chmod +x $SB/opt/p3/deployment/plbin/App-PredictStructure.pl

# 2. the PredictStructure app_specs ONLY (the deployment dir also holds other
#    apps' specs — do NOT wipe it; copy just these files + modes/)
SPECS=$SB/opt/p3/deployment/services/app_service/app_specs
cp /scout/tmp/psa-main/app_specs/PredictStructure.json        $SPECS/
cp /scout/tmp/psa-main/app_specs/PredictStructureFull.spec    $SPECS/
cp /scout/tmp/psa-main/app_specs/PredictStructureMerged.spec  $SPECS/
mkdir -p $SPECS/modes && cp /scout/tmp/psa-main/app_specs/modes/*.json $SPECS/modes/

# 3. refresh the dev_container module checkout so stamp-labels.sh records the
#    correct BVBRC.app_predictstructure_commit
git -C $SB/build/dev_container/modules/PredictStructureApp fetch -q origin main
git -C $SB/build/dev_container/modules/PredictStructureApp reset --hard origin/main

# 4. the /kb/module fallback copy (reqts-bvbrc-service.def puts one here)
cp /scout/tmp/psa-main/service-scripts/App-PredictStructure.pl $SB/kb/module/service-scripts/
cp /scout/tmp/psa-main/app_specs/PredictStructure.json         $SB/kb/module/app_specs/
```

Verify with `perl -c` inside the container (it needs the BV-BRC `PERL5LIB`, which
only exists in the image):

```bash
apptainer exec --bind $SB/opt/p3/deployment/plbin:/mnt /scout/containers/<any>.sif \
    perl -c /mnt/App-PredictStructure.pl   # -> "syntax OK"
```

**Then prove every copy agrees.** This is the check that would have caught #110:

```bash
md5sum $SB/opt/p3/deployment/plbin/App-PredictStructure.pl \
       $SB/build/dev_container/modules/PredictStructureApp/service-scripts/App-PredictStructure.pl \
       $SB/kb/module/service-scripts/App-PredictStructure.pl \
       /scout/tmp/psa-main/service-scripts/App-PredictStructure.pl

md5sum $SB/opt/p3/deployment/services/app_service/app_specs/PredictStructure.json \
       $SB/build/dev_container/modules/PredictStructureApp/app_specs/PredictStructure.json \
       $SB/kb/module/app_specs/PredictStructure.json \
       /scout/tmp/psa-main/app_specs/PredictStructure.json
```

All four hashes in each group must match. `test-container-env.sh` asserts this
too (see Step 5), so a mismatch fails the build gate rather than shipping.

> If `App-PredictStructure.pl` calls a new `protein_compare` flag (e.g. `--metadata`,
> PR #70), reinstall `protein_compare` from `wilke/protein_structure_analysis` in
> Step 4 so the app and report stay in lock-step.

## Step 5: Verify the container

Run the automated test suite against the repacked SIF:

```bash
./test-container-env.sh /scout/containers/folding_YYMMDD.N.sif
```

This checks:
- Shell environment (`90-environment.sh` parses, `KB_TOP`/`PERL5LIB`/`LD_LIBRARY_PATH` set)
- BV-BRC runtime (`p3x-app-shepherd` on PATH, `App-PredictStructure.pl` exists and passes `perl -c`)
- Python tools (`predict-structure --version`, `protein_compare` importable)
- All 8 conda envs exist
- ESMFold2 (`esm` importable in `/opt/conda-esmfold2`, runner file runs by path,
  and the tool env has NO `predict_structure` — both directions of the #98 contract)
- Duplicated copies agree: the Perl app and app spec are byte-identical across
  the deployed, dev_container, and `/kb/module` locations (#110)
- CUDA availability and `CUDA_HOME`

All **24** checks should pass. The script accepts either a SIF path or a sandbox
directory, so run it against `/scout/tmp/all-sandbox` before repacking — and
again against the finished SIF.

**Run it as its own step and read the result before packing.** A previous build
chained verify-and-pack in one command line and packed an image whose env suite
had failed.

### Step 5b: Acceptance — exercise the SERVICE path, not just the CLI

`test-container-env.sh` proves the image is *assembled* correctly.
`test-container-acceptance.sh` proves it *behaves* correctly, through the path
BV-BRC actually uses. This distinction is not academic: an ESMFold2 case passed
every local CLI check and still died in production, because the Perl passed a
flag the subcommand did not define.

```bash
W=/scout/tmp/acceptance-$(date +%y%m%d); mkdir -p $W
# needs crambin.fasta, other.fasta, crambin.a3m in $W
EXPECT=<short-commit> ./test-container-acceptance.sh /scout/containers/folding_YYMMDD.N.sif $W
```

It checks provenance labels against the commit you meant to ship, the #98
single-install and path-invocation contracts, `auto` never resolving to
AlphaFold, the service-script preflight (the F01 path), and the behavior of
whatever shipped in this build. **Extend it each time you ship a fix** — the
checks are cheap and they are what turns "I believe it works" into evidence.

### Step 5c: One real prediction

Neither suite runs the model. Do one small prediction end to end and render a
report from it:

```bash
apptainer exec --nv --bind /local_databases --bind $W:$W \
  --env CUDA_VISIBLE_DEVICES=<a free GPU> /scout/containers/folding_YYMMDD.N.sif \
  /bin/bash -lc "cd /tmp && /opt/conda-predict/bin/predict-structure esmfold \
    --protein $W/crambin.fasta -o $W/e2e --device gpu"

apptainer exec --bind $W:$W /scout/containers/folding_YYMMDD.N.sif /bin/bash -lc \
  "cd /tmp && /opt/conda-predict/bin/python -m protein_compare characterize \
    $W/e2e/model_1.pdb -o $W/e2e/report --format all"
```

> **Pin a free GPU.** On a shared host the default device 0 is often full, and
> the failure is a bare `RuntimeError: CUDA error: out of memory` at model load
> that reads like a container defect. Check `nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader`
> first.

To decide whether an odd-looking result is a regression, run the **same input
through the previous production SIF** and compare `predictions/confidence.json`.
Identical numbers mean the behavior predates your build.

## Step 6: Stamp BVBRC metadata into the sandbox

Before repacking, stamp `BVBRC.*` labels into `labels.json` so the resulting
SIF carries build provenance (date, user, runtime_build commit,
predict-structure version + commit, App-PredictStructure commit).

```bash
./stamp-labels.sh /scout/tmp/all-sandbox folding_YYMMDD.N.sif
```

The default base SIF is `/vol/patric3/production/containers/cuda-12.2-025-base-gpu.2026-05-11.002.sif`;
pass a third argument to override.

The base image's labels (Author, CUDA-Version, build_hash from olson's gitlab,
etc.) are left untouched — only `BVBRC.*` keys are added/updated.

After repack, verify with:

```bash
apptainer inspect /scout/containers/folding_YYMMDD.N.sif | grep BVBRC
```

## Step 7: Repack into SIF

```bash
APPTAINER_TMPDIR=/scout/tmp apptainer build --fakeroot \
    /scout/tmp/folding_YYMMDD.N.sif \
    /scout/tmp/all-sandbox
```

Replace `YYMMDD.N` with the date and build number (e.g. `260527.1`).
This takes ~10 minutes and compresses the sandbox back to ~36 GB.

Verify the final SIF with the test script:

```bash
./test-container-env.sh /scout/tmp/folding_YYMMDD.N.sif
```

## Step 8: Deploy

Deployment has **two distinct stages**, and conflating them is a common
mistake: nothing under `/scout/containers` is visible to BV-BRC.

### 8a. Local testing (this account, no special privileges)

```bash
mv /scout/tmp/folding_YYMMDD.N.sif /scout/containers/

cd /scout/containers
ln -sf folding_YYMMDD.N.sif folding_latest.sif
ln -sf folding_YYMMDD.N.sif folding_dev.sif
ln -sf folding_YYMMDD.N.sif folding_prod.sif   # only after testing
```

`folding_prod.sif` is what local CWL runs and the repo's `perl -c` checks
resolve. **It has no effect on BV-BRC jobs.**

### 8b. Promotion to BV-BRC (needs the `p3` account)

Two actions, both outside this account:

```bash
# 1. copy the SIF where the scheduler can stage it
cp /scout/containers/folding_YYMMDD.N.sif /vol/patric3/production/containers/

# 2. repoint the app at it (on gum, as p3)
p3x-show-container-config          # inspect ApplicationDefaultContainer
# ... repoint PredictStructure -> folding_YYMMDD.N.sif
```

### 8c. Verify the repoint actually took

**Do not skip this.** The repoint has silently failed to take twice. The only
reliable evidence is a real job's stderr:

```bash
TOKEN=$(cat ~/.patric_token)
curl -s -H "Authorization: OAuth $TOKEN" \
  "https://p3.theseed.org/services/app_service/task_info/<task-id>/stderr" \
  | grep "Container path:"
# -> Container path: /disks/patric-common/container-cache/folding_YYMMDD.N.sif
```

Notes that cost time when forgotten:

- `AppService.enumerate_apps` returns a curated ~39-app list that **never**
  includes PredictStructure. It cannot tell you whether the app is registered.
- The first submission after a switch takes several minutes (~8 was observed)
  while a 32 GB SIF stages into the container cache. The test runner allows
  900 s; a slow first call is not a failure.
- If `start_app2` returns an empty `"Error submitting job: \n"`, the registered
  container filename probably does not exist — the scheduler runs preflight
  *inside* the container, so a missing image produces no error text at all.

## Step 9: Clean up

```bash
rm -rf /scout/tmp/all-sandbox
```

## Container contents

| Tool | Conda env | Command |
|------|-----------|---------|
| predict-structure | `/opt/conda-predict` | `predict-structure <tool> ...` |
| AlphaFold 2.3.2 | `/opt/conda-alphafold` | `/opt/conda-alphafold/bin/python /app/alphafold/run_alphafold.py` |
| Boltz-2 | `/opt/conda-boltz` | `/opt/conda-boltz/bin/boltz predict` |
| Chai-1 | `/opt/conda-chai` | `/opt/conda-chai/bin/chai-lab fold` |
| ESMFold | `/opt/conda-esmfold` | `/opt/conda-esmfold/bin/esm-fold-hf` |
| DiffDock | `/opt/conda-diffdock` | (present in the image; not driven by predict-structure) |
| ESMFold2 | `/opt/conda-esmfold2` | `predict-structure esmfold2 ...` (runner: conda-esmfold2 python executing the runner FILE from the conda-predict install — never `-m`, see #98) |
| OpenFold 3 | `/opt/conda-openfold` | `/opt/conda-openfold/bin/run_openfold predict` |

## Symlink convention

```
/scout/containers/
  folding_YYMMDD.N.sif    # Versioned image (immutable)
  folding_latest.sif  ->  folding_YYMMDD.N.sif
  folding_dev.sif     ->  folding_YYMMDD.N.sif
  folding_prod.sif    ->  folding_YYMMDD.N.sif
```

---

## Full rebuild from all-build.def

This builds everything from scratch. Takes ~20-30 minutes.

### Prerequisites

- The BV-BRC runtime tarball and packages list. Current versions:
  - `/home/olson/BV-BRC/runtime_build/gpu-builds/runtime-137-12.tgz` (2.5 GB)
  - `/home/olson/BV-BRC/runtime_build/gpu-builds/packages-137-12.txt`
- Local scratch disk with ~120 GB free
- Network access (pulls `nvidia/cuda` Docker image, conda packages, pip packages, git repos)

### Build command

```bash
cd gpu-builds/cuda-12.2-cudnn-8.9.6

APPTAINER_TMPDIR=/scout/tmp apptainer build --fakeroot \
    --build-arg runtime=/home/olson/BV-BRC/runtime_build/gpu-builds/runtime-137-12.tgz \
    --build-arg packages=/home/olson/BV-BRC/runtime_build/gpu-builds/packages-137-12.txt \
    --warn-unused-build-args \
    /scout/tmp/folding_YYMMDD.N.sif \
    all-build.def
```

### Verify

```bash
./test-container-env.sh /scout/tmp/folding_YYMMDD.N.sif
```

Then stamp labels and deploy using Steps 6–9 from the layered build above.

### Notes

- `all-build.def` uses `--no-same-owner` in the tar command to avoid fakeroot
  UID/GID failures during `%setup`.
- The full build pulls `nvidia/cuda:12.2.0-devel-ubuntu22.04` from Docker Hub,
  so an OCI image cache speeds up repeated builds.
- The resulting SIF is ~19 GB (smaller than the layered build because squashfs
  compression is applied to the whole image at once).

---

## Troubleshooting

### `apptainer build --fakeroot` fails with "root filesystem extraction failed"

Do not use `apptainer build --fakeroot --build-arg base=<sif>` with large SIF
files. The fakeroot UID/GID mapping fails during extraction. Use the sandbox
approach documented above instead.

### `unsquashfs` reports "Can't find a valid SQUASHFS superblock"

The SIF has a header before the squashfs payload. Use `apptainer sif list <sif>`
to find the squashfs offset, then pass `-offset <N>` to `unsquashfs`.

### `unsquashfs` exits with code 2

Exit code 2 from xattr warnings (`could not write xattr security.capability`)
is expected when running without root. The extraction is successful.

### Build runs out of space in /tmp

Set `APPTAINER_TMPDIR` to a local disk with sufficient space:

```bash
export APPTAINER_TMPDIR=/scout/tmp
```
