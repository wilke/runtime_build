---
name: build-folding-container
description: Build and deploy the BV-BRC folding container (AlphaFold, Boltz, Chai, ESMFold, ESMFold2, OpenFold, DiffDock, predict-structure + report, stabiliNNator). Use when asked to build, rebuild, bump a tool version in, verify, or deploy the folding/predict-structure/stabiliNNator container image, or when adding a new tool to it.
---

# Build and deploy the folding container

One `apptainer build` from pinned definition files. **No sandbox.** If you find
yourself running `apptainer exec --writable` against `/scout/tmp/all-sandbox`,
stop — that path is deprecated and is why the image used to drift.

Authoritative reference: `gpu-builds/cuda-12.2-cudnn-8.9.6/BUILD-SOP.md`.
This skill is the short path; the SOP explains the reasoning.

## Layout

All paths below are relative to `gpu-builds/cuda-12.2-cudnn-8.9.6/`.

| File | Role |
|---|---|
| `stages.list` | ordered manifest — **the** source of truth for image contents |
| `assemble-folding-def.py` | generates `all-build.def`; holds every version pin (`PINS`, `DEVCONTAINER`, `CUDA_BASE`) |
| `all-build.def` | **generated — never edit by hand** |
| `build-folding-container` | the driver: preflights, builds, verifies |
| `test-container-env.sh` | 41 structural checks; run automatically by the driver |
| `test-container-acceptance.sh` | 26 behavioural checks through the service path |

## 0. Preconditions

```bash
grep "^$(id -u):" /etc/subuid /etc/subgid   # MUST return two lines
df -BG --output=avail /disks/tmp            # need ~120 GB
```

Without a subuid range `--fakeroot` cannot map uids, and ~30 of the 62 OS
packages fail to configure because their postinst chowns to a non-root user.
The build then dies far from the cause. The driver checks this, but check first
rather than 40 minutes in. An admin fixes it once:
`echo "$(id -u):4294705152:65536" >> /etc/subuid` (and `/etc/subgid`).

## 1. Bump whatever changed

Edit `PINS` in `assemble-folding-def.py`, then:

```bash
./assemble-folding-def.py && git diff all-build.def   # review what moved
```

- `ps_commit` pins the Python package **and** the Perl app together on purpose.
  They both come from PredictStructureApp, and #98/#110 were both cases of
  those halves drifting apart. Do not split them.
- To add a tool: write `reqts-<tool>.def`, add one line to `stages.list`,
  regenerate. Order matters — `reqts-predict-structure.def` must precede any
  stage that asserts on it.
- **Never put `%arguments` in a `reqts-*.def`.** The merger drops it silently
  (it warns now). Defaults belong in `PINS`.

## 2. Build (self-verifying, ~60–90 min)

```bash
cd gpu-builds/cuda-12.2-cudnn-8.9.6
./build-folding-container /disks/tmp/folding_YYMMDD.N.sif
```

Run it in the background and poll the log; do not block a foreground call for
90 minutes. The driver refuses a stale `all-build.def`, then runs
`test-container-env.sh` itself and **exits non-zero without printing success**
if the image fails. "Build complete and verified" is the only success signal.

Useful progress greps (`# === Stage from:` markers are comments and do *not*
appear in the log):

```bash
grep -c 'Successfully installed' <log>          # pip stages done
grep -cE 'FATAL|dpkg: error processing' <log>   # must stay 0
```

## 3. Acceptance + one real prediction

```bash
W=/scout/tmp/acceptance-$(date +%y%m%d); mkdir -p $W
# stage: crambin.fasta, other.fasta, crambin.a3m, 1crn_small.pdb
EXPECT=<short ps_commit> ./test-container-acceptance.sh <sif> $W
```

Expect `26 passed, 0 failed, 0 skipped`. A **skip is not a pass** — section 16
is the only end-to-end model run and it skips silently if `1crn_small.pdb`
(from the stabiliNNatorApp repo's `test_data/`) is not staged.

For a folding model, also do one real prediction on a free GPU:

```bash
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader
apptainer exec --nv --env CUDA_VISIBLE_DEVICES=<free gpu> ...
```

## 4. Deploy

```bash
cp /disks/tmp/folding_YYMMDD.N.sif /scout/containers/
cd /scout/containers
sha256sum folding_YYMMDD.N.sif /disks/tmp/folding_YYMMDD.N.sif   # must match
ln -sf folding_YYMMDD.N.sif folding_latest.sif
ln -sf folding_YYMMDD.N.sif folding_dev.sif
ln -sf folding_YYMMDD.N.sif folding_prod.sif    # only after §3 passes
```

Then re-run `./test-container-env.sh /scout/containers/folding_latest.sif` — it
verifies the deployed copy, not the scratch one.

Note: repointing `folding_prod.sif` may be blocked by the permission
classifier. Do not work around it. Ask the user to run that one line.

**Rollback** is one symlink: `ln -sf <previous>.sif folding_prod.sif`.

None of this is visible to BV-BRC. Promotion needs the `p3` account:
copy to `/vol/patric3/production/containers/`, repoint via
`p3x-show-container-config` on gum, then confirm with a real job's stderr
(`Container path:`) — the repoint has silently failed before.

## Traps that have cost real time

- **`%environment` is concatenated verbatim, not merged.** It used to hoist
  every `export` out of its enclosing `if`, leaving `then` followed by `fi` — a
  syntax error that makes Apptainer discard the *whole* block, so the image
  came up with no `PATH`/`KB_TOP`/`PERL5LIB` and every job died. Don't add a
  second copy of an accumulating export or loop; it now runs twice.
- **`. ./user-env.sh` exports `KB_TOP=/build/dev_container`.** Anything using
  `$KB_TOP` as a deploy destination after that line silently retargets — the
  `perl -c` guard included, so it validates the file it just misplaced.
  `reqts-bvbrc-deploy.def` uses `DEPLOY` for this reason.
- **`set -o pipefail` leaks between stages** (base-build sets it). A guard like
  `n=$(ls ... | wc -l)` aborts the build instead of reporting `n=0`. Scope it
  off inside the substitution.
- **stabiliNNator's two checkpoints are different architectures.**
  `proline_gat` (GATConv) must be converted to the PyG 2.4 layout;
  `cys_gat` (GATv2Conv) must not be. One shared assertion over both is wrong.
- **`stabilinnator` defaults to `--device cuda`.** Without `--nv` it dies at
  model load. Pass `--device cpu` for CLI/test runs — that is also what the app
  spec defaults to and what the Perl service passes on a CPU node.
- **Testing `App-StabiliNNator` by hand throws a harmless save error.** Invoked
  outside the P3 shepherd against an `output_path` that already exists,
  AppScript's post-run job-metadata write reports
  `Cannot overwrite directory .../<output_path>/ on save!`. Exit code is still
  0 and every app output uploads correctly -- it is an artifact of running
  outside the scheduler, not a stabiliNNator fault. Don't chase it.
- **Verify by content, never by version.** `predict-structure` and
  `protein_compare` do not bump versions per commit, so `--version` proves
  nothing. Check the `BVBRC.*` labels (`apptainer inspect <sif> | grep BVBRC`)
  or grep the installed source.
