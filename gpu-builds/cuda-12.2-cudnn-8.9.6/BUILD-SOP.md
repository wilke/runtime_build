# SOP: Building the Folding Container

Standard operating procedure for building the all-in-one protein structure
prediction container (AlphaFold, Chai, Boltz, ESMFold, predict-structure).

## Build approaches

There are two ways to build this container:

1. **Layered build** (documented below) — extract an existing base SIF,
   install additional tools into the sandbox, repack. Use this when adding tools
   to an existing container or updating individual components.

2. **Full rebuild** from `all-build.def` (documented at the end) — builds
   everything from scratch starting from `nvidia/cuda:12.2.0-devel-ubuntu22.04`.
   Requires the `{{runtime}}` tarball and `{{packages}}` list.

Both approaches have been tested (March 2026).

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

pip install --no-cache-dir "predict-structure[cwl] @ git+https://github.com/CEPI-dxkb/PredictStructureApp.git"

ln -sf $conda_dir/bin/predict-structure /usr/local/bin/predict-structure

conda clean --all --force-pkgs-dirs --yes
pip cache purge
'
```

## Step 4a: Install ESMFold2 (Biohub diffusion model)

Mirrors `reqts-esmfold2.def`. Creates `/opt/conda-esmfold2` and installs the
Biohub `esm` package plus `predict-structure` (the runner subprocess
`python -m predict_structure.runners.esmfold2` runs inside this env).

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
pip install --no-cache-dir "predict-structure @ git+https://github.com/CEPI-dxkb/PredictStructureApp.git"

conda clean --all --force-pkgs-dirs --yes
pip cache purge
'
```

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
- ESMFold2 (`esm` importable in `/opt/conda-esmfold2`, runner module responds to `--help`)
- CUDA availability and `CUDA_HOME`

All 21 checks should pass. The script accepts either a SIF path or a sandbox
directory, so you can run it against `/scout/tmp/all-sandbox` before repacking.

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

Move the SIF and update symlinks:

```bash
mv /scout/tmp/folding_YYMMDD.N.sif /scout/containers/

cd /scout/containers
ln -sf folding_YYMMDD.N.sif folding_latest.sif
ln -sf folding_YYMMDD.N.sif folding_dev.sif
# Only update prod after testing:
ln -sf folding_YYMMDD.N.sif folding_prod.sif
```

CWL tools reference `folding_prod.sif` in production.

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
| ESMFold2 | `/opt/conda-esmfold2` | `predict-structure esmfold2 ...` (runner: `python -m predict_structure.runners.esmfold2`) |
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
