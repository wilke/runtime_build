# SOP: Building the Folding Container

Standard operating procedure for building the all-in-one protein structure
container: prediction (AlphaFold, Chai, Boltz, ESMFold, ESMFold2, OpenFold),
the `predict-structure` CLI and its HTML report, and stability prediction
(stabiliNNator). It serves **two** BV-BRC apps — PredictStructure and
StabiliNNator.

## How this container is built

**One command, from pinned definition files:**

```bash
cd gpu-builds/cuda-12.2-cudnn-8.9.6
./build-folding-container /disks/tmp/folding_YYMMDD.N.sif
```

That is the whole build. It takes ~60–90 min, needs ~120 GB of scratch, and
requires no sudo, no sandbox, and no existing SIF.

### What makes it reproducible

| File | Role |
|---|---|
| `stages.list` | ordered manifest — **the** source of truth for what is in the image |
| `assemble-folding-def.py` | generates `all-build.def`; holds every version pin |
| `all-build.def` | **generated — do not edit by hand** |
| `build-folding-container` | driver; refuses to build a stale `all-build.def` |
| `packages-folding.txt` | the 62 OS packages, vendored into this repo |

Both base images are pinned by digest and every application repo by commit
(as `%arguments` defaults, so a plain build is deterministic while
`--build-arg ps_commit=<sha>` still works for a one-off). Adding a tool means
writing a `reqts-<tool>.def` and adding one line to `stages.list`.

**`ps_commit` deliberately pins two things at once.** `PredictStructureApp`
supplies both the Python package (`reqts-predict-structure.def`) and the Perl
service script (`reqts-bvbrc-deploy.def`). Every documented production failure
in this container — #98 and #110 — was those two halves drifting apart, which
is exactly what two independent `main` trackers cannot prevent and one shared
build-arg makes impossible.

To bump a version, edit `PINS` in `assemble-folding-def.py`, regenerate, and
rebuild:

```bash
./assemble-folding-def.py && git diff all-build.def   # review what moved
```

> **Do not put `%arguments` in a `reqts-*.def`.** `merge_singularity_defs.py`
> parses the section but has nowhere to store it, so the defaults are dropped
> and every `{{placeholder}}` in that file becomes an unresolvable literal at
> build time. It now warns when this happens. Defaults belong in `PINS`.
> The consequence is that individual stage defs are fragments: building one
> standalone requires passing `--build-arg` explicitly.

> **`%environment` blocks now concatenate verbatim — they used to merge.**
> `merge_singularity_defs.py` previously hoisted every `export VAR=` into a
> last-wins dict and emitted it once at the bottom of the block; it now just
> concatenates each stage's `%environment`, in `stages.list` order, unchanged.
> Two consequences for whoever edits a `reqts-*.def` next:
> - Conditional exports (`if [[ -d /local_databases/chai ]] ; then export ...
>   fi`) survive intact. Hoisting the `export` out left the `if` and the `fi`
>   in place with **nothing between them** — `then` must be followed by a
>   statement list, so that is a bash syntax error (see "After the build" below
>   for what it broke in practice). Five stages were affected: chai, boltz,
>   openfold, esmfold, esmfold2.
> - Accumulating exports now accumulate correctly. Three stages export
>   `PATH=<something>:$PATH`; under last-wins only the final one survived,
>   silently dropping `/opt/conda-predict/bin` and `/opt/miniforge/bin`. In
>   `stages.list` order the result (verified by simulation) is
>   `/opt/p3/deployment/bin:/opt/patric-common/runtime/bin:/opt/conda-predict/bin:/opt/conda-alphafold:/opt/hhsuite/bin:/usr/local/cuda/bin:/opt/miniforge/bin:...`,
>   matching the known-good production image.
> - Do **not** add a second copy of an accumulating export or loop to a new
>   def assuming dedup will collapse it — it now runs twice. The
>   `LD_LIBRARY_PATH` nvidia-glob loop lives in `base-build.def` only, for
>   exactly this reason.

### Two things about this host

- **The build user needs an `/etc/subuid` + `/etc/subgid` range.** This is a
  hard prerequisite, and its absence is the single most expensive way to lose an
  hour here. Without a range, `--fakeroot` cannot map a uid span, apptainer
  falls back to a root-mapped namespace in which *only* uid 0 exists, and every
  package whose postinst chowns to a non-root user fails to configure — about
  **30 of the 62** in `packages-folding.txt` (`fontconfig`, `openssh-client`,
  `openjdk-11-jre`, `r-base-core`, `redis-server`, `dbus`, …). The build fails
  far downstream of the real cause with a misleading message. A wrapping
  `fakeroot` inside `%post` does **not** work around it — `dpkg-statoverride`
  still fails. `build-folding-container` checks for the range before starting.

  ```bash
  grep "^$(id -u):" /etc/subuid /etc/subgid   # must return two lines
  # if not, an admin adds (once):
  #   echo "$(id -u):4294705152:65536" >> /etc/subuid
  #   echo "$(id -u):4294705152:65536" >> /etc/subgid
  ```

- **`00-build-env.def` must stay first in `stages.list`.** It sets
  `APT::Sandbox::User "root"` before the first `apt-get`, and fails fast if apt
  is unusable — so an apt problem surfaces as an apt error rather than as an
  unrelated `locale-gen: command not found` twenty lines downstream in another
  stage.

### After the build

**Verification is automatic — you do not run it by hand.**
`build-folding-container` runs Step 5's `./test-container-env.sh` on the
finished SIF itself, immediately after `apptainer build`, and exits non-zero
**without printing success** if any check fails. This exists because a merger
bug once produced a `%environment` with an empty `if ... fi` (a bash syntax
error). Apptainer parses `%environment` as a whole, so the image came up with
**no** `PATH`/`KB_TOP`/`PERL5LIB` and every job would have died at startup —
yet `apptainer build` still exited 0 after 90 minutes. The harness now catches
it in seconds.

The remaining steps below are **not** deprecated — they apply to a def-built
SIF unchanged:

1. [Step 5](#step-5-verify-the-container) — already ran automatically above;
   re-run by hand only to check a SIF built some other way, e.g. directly from
   `all-build.def` (see "Full rebuild from all-build.def")
2. [Step 5b](#step-5b-acceptance--exercise-the-service-path-not-just-the-cli) — acceptance, the service path
3. [Step 5c](#step-5c-one-real-prediction) — one real prediction on a free GPU
4. [Step 8](#step-8-deploy) — deploy and promote

Skip Step 6 (stamp) and Step 7 (repack): there is no sandbox to stamp or repack.
`assemble-folding-def.py` writes the `BVBRC.*` provenance labels straight into
the generated def, so a def build carries them without a stamping step:

```bash
apptainer inspect <sif> | grep BVBRC
#   BVBRC.base_cuda                   nvidia/cuda@sha256:c4e8...
#   BVBRC.predict_structure_commit    b3f8bfc...
#   BVBRC.app_stabilinnator_commit    dd80c40...
#   BVBRC.stabilinnator_commit        28f0fc9...
apptainer inspect --deffile <sif>     # the exact def it was built from
```

The labels carry no build date or hostname on purpose — those would make the
generated file differ on every run and defeat `--check`.

---

## The old sandbox path (deprecated)

Everything below documents the previous workflow: extract a SIF to
`/scout/tmp/all-sandbox`, mutate it with `apptainer exec --writable`, repack.
**Do not use it for new work.** It is kept because images through
`folding_260820.1.sif` were built this way, so it explains how they came to be.

It was abandoned because it was not reproducible, and the drift was real rather
than theoretical: the committed `all-build.def` built **6** conda envs while the
shipped image had **8** — `esmfold` and `esmfold2` existed only as hand-applied
sandbox edits that no file in this repo described. Nothing was version-pinned,
and `reqts-bvbrc-service.def` wrapped every deploy step in `|| true` with stderr
discarded, so a failed deploy still produced an image that looked healthy.

---

## Incremental refresh (deprecated — sandbox path)

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

## Step 4c: stabiliNNator (tool env)

> **In a def build this is automatic** — `reqts-stabilinnator.def` is in
> `stages.list` and needs no action. The commands below are the deprecated
> sandbox equivalent. **The knowledge in this section is not deprecated**: the
> three-repo distinction and the three failure modes apply either way, and the
> def encodes exactly what is described here.

Three repos are involved and confusing them wastes an afternoon:

| Repo | Role |
|---|---|
| `schoederlab/stabiliNNator` | the model code **and** the committed `.pt` checkpoints — pinned at `28f0fc9` |
| `CEPI-dxkb/stabiliNNatorApp` | the BV-BRC wrapper: `app_specs`, `App-StabiliNNator.pl`, the HTML report, `convert_checkpoint.py` — deployed in Step 4d |
| `jakobriccabona/stabiliNNator` | referenced by the app repo's README and CWL, **not** what is built. Do not "correct" the URL to this. |

```bash
APPTAINER_TMPDIR=/scout/tmp apptainer exec --fakeroot --writable \
    /scout/tmp/all-sandbox /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export CONDA_PLUGINS_AUTO_ACCEPT_TOS="yes"

conda_dir=/opt/conda-stabilinnator
. /opt/miniforge/etc/profile.d/conda.sh

# python 3.11 is mandatory: torch 2.1.0 publishes no cp312 wheels.
conda create -p $conda_dir --yes --quiet python=3.11 pip
conda activate $conda_dir

$conda_dir/bin/pip install --no-cache-dir torch==2.1.0 torchvision==0.16.0 \
    torchaudio==2.1.0 --index-url https://download.pytorch.org/whl/cu121
$conda_dir/bin/pip install --no-cache-dir "numpy>=1.24.0,<2.0.0"
for pkg in torch-scatter torch-sparse torch-cluster torch-spline-conv; do
    $conda_dir/bin/pip install --no-cache-dir "$pkg" \
        -f https://data.pyg.org/whl/torch-2.1.0+cu121.html
done
$conda_dir/bin/pip install --no-cache-dir torch-geometric==2.4.0 \
    "biopython>=1.81" "matplotlib>=3.7.0" "scikit-learn>=1.2.0"

rm -rf /opt/stabilinnator
git clone https://github.com/schoederlab/stabiliNNator.git /opt/stabilinnator
git -C /opt/stabilinnator checkout 28f0fc99b12be333d7143bd560f9279ce1374caa

conda clean --all --force-pkgs-dirs --yes
$conda_dir/bin/pip cache purge
'
```

### The three things that are easy to get wrong

**1. The CUDA suffix appears twice.** Upstream builds cu118 on a CUDA 11.8 base;
this image is CUDA 12.2, so we take cu121. The torch `--index-url` **and** the
`data.pyg.org` wheel index must carry the same suffix. Mix them and pip happily
installs a cu121 torch beside cu118 extensions — which imports fine at build
time and dies at predict time.

**2. Only the proline checkpoint gets converted.** The two models are different
architectures, and one shared assertion over both is wrong:

| Checkpoint | Arch | Ships as | Conversion |
|---|---|---|---|
| `proline_gat.pt` | GATConv | `gat.lin.weight` (pre-2.4) | **required** → `lin_src`/`lin_dst` |
| `cys_gat.pt` | GATv2Conv | `gat.lin_l/lin_r` + `lin_edge` | none — already current, converter copies it through |

```bash
curl -fsSL -o /tmp/convert_checkpoint.py \
  https://raw.githubusercontent.com/CEPI-dxkb/stabiliNNatorApp/dd80c40/container/convert_checkpoint.py
for m in proliNNator/models/proline_gat disulfiNNate/models/cys_gat; do
    /opt/conda-stabilinnator/bin/python /tmp/convert_checkpoint.py \
        /opt/stabilinnator/$m.pt /opt/stabilinnator/$m.converted.pt
    mv /opt/stabilinnator/$m.converted.pt /opt/stabilinnator/$m.pt
done
```

Skip the proline conversion and the model does not load at all under
torch-geometric 2.4 — a hard failure at predict time, not a silent one.

**3. `--hidden-dim 32` is not optional.** The checkpoints were trained at 32
while the scripts default to 128. The `/usr/local/bin` wrappers inject it (and
the model path) when absent; see the def for their exact content. Those wrappers
hardcode `/opt/conda-stabilinnator/bin/python` rather than calling bare
`python` — in this image bare `python` is conda-predict's 3.12, which has no
torch and no PyG.

> **Do not put `/opt/conda-stabilinnator/bin` on the global PATH.** It would
> shadow conda-predict's interpreter for every other tool in the image. The
> wrappers name the interpreter explicitly; Step 4d handles the service path.

**Incremental refresh:** to update only the model code, skip `conda create` and
re-clone `/opt/stabilinnator` (then re-run the conversion — a fresh clone
restores the unconverted checkpoints).

## Step 4d: The StabiliNNator BV-BRC app

> **In a def build this is automatic** — `reqts-bvbrc-deploy.def` deploys both
> apps. The commands below are the deprecated sandbox equivalent; the
> explanation of *why* the wrapper exists applies to both paths.

This container now serves **two** BV-BRC apps. StabiliNNator's deploy differs
from PredictStructure's in one important way, and it is the whole reason this
step exists as prose rather than a copy of Step 4b.

`App-StabiliNNator.pl` shells out with a bare `system("python", ...)` at three
call sites (the two model scripts and `generate_report.py`) and offers **no**
environment override for the interpreter — `STABILINNATOR_DIR`,
`PROLINNATOR_MODEL`, `DISULFINNATE_MODEL` and `STABILINNATOR_MODULE_DIR` are
overridable, the Python binary is not. In its own single-tool image bare
`python` is the only Python. Here it is conda-predict's 3.12.

Rather than patch upstream Perl, the **deploy wrapper** supplies the
environment. This keeps the checkout byte-identical to `main`:

```bash
SB=/scout/tmp/all-sandbox

# clean checkout of the wrapper repo
if [ -d /scout/tmp/stab-main/.git ]; then
    git -C /scout/tmp/stab-main fetch -q origin main
    git -C /scout/tmp/stab-main reset -q --hard origin/main
else
    git clone -q --depth 1 https://github.com/CEPI-dxkb/stabiliNNatorApp.git \
        /scout/tmp/stab-main
fi

# 1. the service script
cp /scout/tmp/stab-main/service-scripts/App-StabiliNNator.pl \
   $SB/opt/p3/deployment/plbin/App-StabiliNNator.pl
chmod +x $SB/opt/p3/deployment/plbin/App-StabiliNNator.pl

# 2. the module tree the report generator needs. It gets its OWN directory:
#    /kb/module already holds PredictStructure fallback copies, and the two
#    apps' service-scripts/ and app_specs/ would collide there.
MOD=$SB/kb/module/StabiliNNatorApp
mkdir -p $MOD
cp -r /scout/tmp/stab-main/report      $MOD/          # incl. vendor/3Dmol-min.js
cp -r /scout/tmp/stab-main/app_specs   $MOD/
cp -r /scout/tmp/stab-main/service-scripts $MOD/

# 3. the app spec the AppService registry reads (add ONLY this file; the dir
#    holds other apps' specs)
cp /scout/tmp/stab-main/app_specs/StabiliNNator.json \
   $SB/opt/p3/deployment/services/app_service/app_specs/

# 4. the wrapper -- this is what makes bare `python` resolve to the torch env
cat > $SB/opt/p3/deployment/bin/App-StabiliNNator <<'EOF'
#!/bin/bash
export KB_TOP=/opt/p3/deployment
export KB_RUNTIME=/opt/patric-common/runtime
export KB_MODULE_DIR=StabiliNNatorApp
export STABILINNATOR_MODULE_DIR=/kb/module/StabiliNNatorApp
export STABILINNATOR_DIR=/opt/stabilinnator
# App-StabiliNNator.pl calls bare `python` via system() and cannot be told
# otherwise. Put the tool env FIRST so those calls get torch + PyG. Scoped to
# this wrapper on purpose -- globally it would shadow conda-predict.
export PATH="/opt/conda-stabilinnator/bin:/opt/patric-common/runtime/bin:/opt/p3/deployment/bin:$PATH"
export PERL5LIB=/opt/p3/deployment/lib
exec /opt/patric-common/runtime/bin/perl \
     /opt/p3/deployment/plbin/App-StabiliNNator.pl "$@"
EOF
chmod +x $SB/opt/p3/deployment/bin/App-StabiliNNator
```

Verify the syntax and the interpreter contract:

```bash
apptainer exec --bind $SB/opt/p3/deployment/plbin:/mnt /scout/containers/<any>.sif \
    perl -c /mnt/App-StabiliNNator.pl        # -> syntax OK

apptainer exec /scout/tmp/all-sandbox /bin/bash -c \
    'PATH=/opt/conda-stabilinnator/bin:$PATH python -c "import torch_geometric"'
```

`test-container-env.sh` asserts both, plus that the env stays off the global
PATH (see Step 5).

### Resource expectations

The tool's own docs recommend **CPU**, and the shipped app spec agrees
(`accelerator=cpu`, `gpu_count: 0`, cpu 2, memory 1G, runtime 120s). The models
are 14–22 KB; CUDA init costs more than the inference. Measured on CPU: 46 res
≈ 5 s, 415 res ≈ 5 s, 8,015 res ≈ 8 s (proline) / 19 s (disulfide — it is O(n²)
over cysteine pairs within 6 Å). Peak RSS ≈ 470 MB.

The env is nonetheless built CUDA-capable so an explicit `--device cuda`
request still works. If image size ever becomes the binding constraint, a
CPU-only torch here is the single largest saving available (~3 GB) and matches
the default execution path.

> **`--device` defaults to `cuda` upstream — pass `--device cpu` for CLI runs
> without `--nv`.** Both upstream scripts default to CUDA, so a bare
> `apptainer exec <sif> stabilinnator proline ...` (no `--nv`) fails at model
> load with:
>
> ```
> RuntimeError: Attempting to deserialize object on a CUDA device but
> torch.cuda.is_available() is False.
> ```
>
> This does **not** affect BV-BRC jobs: `App-StabiliNNator.pl` probes
> `torch.cuda.is_available()` and passes `--device` explicitly. It bites
> interactive CLI use and test harnesses, which is why
> `test-container-acceptance.sh` section 16 passes `--device cpu` — that is
> what reproduces the production path, not a workaround.

## Step 5: Verify the container

Run the automated test suite against the repacked SIF:

```bash
./test-container-env.sh /scout/containers/folding_YYMMDD.N.sif
```

This checks:
- Shell environment (`90-environment.sh` parses, `KB_TOP`/`PERL5LIB`/`LD_LIBRARY_PATH` set)
- BV-BRC runtime (`p3x-app-shepherd` on PATH, `App-PredictStructure.pl` exists and passes `perl -c`)
- Python tools (`predict-structure --version`, `protein_compare` importable)
- All 9 conda envs exist
- ESMFold2 (`esm` importable in `/opt/conda-esmfold2`, runner file runs by path,
  and the tool env has NO `predict_structure` — both directions of the #98 contract)
- stabiliNNator: torch/PyG import, model code present, **proline checkpoint
  converted and disulfide checkpoint intact** (asserted separately — they are
  different architectures), the wrappers pin the tool interpreter, and the env
  is *not* on the global PATH
- StabiliNNator app: `App-StabiliNNator.pl` present + `perl -c`, spec deployed,
  report generator and vendored 3Dmol present, and the wrapper makes bare
  `python` resolve to the torch env
- Duplicated copies agree: the Perl app and app spec are byte-identical across
  the deployed, dev_container, and `/kb/module` locations (#110)
- CUDA availability and `CUDA_HOME`

All **41** checks should pass. The script accepts either a SIF path or a sandbox
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
| stabiliNNator | `/opt/conda-stabilinnator` | `stabilinnator {proline\|disulfide\|both} --pdb-path X --output-path Y` (wrappers pin the env's python; the env is deliberately off the global PATH) |

### Running the container directly (`apptainer run`)

`assemble-folding-def.py` emits exactly **one** authoritative `%runscript` in
the merged def and strips the per-stage ones. It didn't always: the merger
used to concatenate all four stage runscripts, and base-build's `exec "$@"`
ran first — so `apptainer run <sif> somecmd` worked, but `apptainer run <sif>`
with **no** arguments made that `exec` a no-op, execution fell through the
other three runscripts, and the container silently ran AlphaFold
(`cd /app/alphafold; exec /app/run_alphafold.sh`).

Now a no-arg `apptainer run <sif>` prints a usage message naming the real
entry points and exits 2:

- `predict-structure <tool> ...`
- `stabilinnator {proline|disulfide|both} ...`
- `App-PredictStructure params.json`
- `App-StabiliNNator params.json`

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

> **Run this from `gpu-builds/cuda-12.2-cudnn-8.9.6/`, as shown above.**
> `all-build.def` declares `%files` with the relative source path
> `packages-folding.txt`; apptainer resolves that against the build's working
> directory, not the def file's location. `build-folding-container` always
> `cd`s there first — a direct `apptainer build ... all-build.def` invocation
> run from anywhere else will fail to find the packages file.

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
