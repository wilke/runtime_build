# Container Build Status

Last updated: 2026-06-22

## Current Production Image

| Field | Value |
|-------|-------|
| SIF | `/scout/containers/folding_260622.1.sif` (32 GB) |
| Symlinks | `folding_dev.sif`, `folding_latest.sif`, `folding_prod.sif` → all 260622.1 |
| Base image | `/vol/patric3/production/containers/cuda-12.2-025-base-gpu.2026-05-11.002.sif` |
| CUDA | 12.2 + cuDNN 8.9.6 |

> predict-structure `153439f` (main with PRs #57–#68 merged). Validated on H200 before
> promotion: 21/21 env checks + real Boltz/ESMFold2/ESMFold folds.

## Tool Versions

| Tool | Conda env | Version/Commit | PyTorch |
|------|-----------|----------------|---------|
| predict-structure | `/opt/conda-predict` (Py 3.12) | 0.17.0 (153439f) | — |
| protein_compare | `/opt/conda-predict` | 0.2.1 (\_\_init\_\_ shows 0.2.0) | — |
| Boltz-2 | `/opt/conda-boltz` (Py 3.11) | 2.2.1 | 2.12.0+cu130 |
| Chai-1 | `/opt/conda-chai` (Py 3.10) | latest | cu121 |
| AlphaFold 2 | `/opt/conda-alphafold` (Py 3.11) | 2.3.2 | JAX 0.4.26 |
| ESMFold | `/opt/conda-esmfold` (Py 3.11) | latest | 2.6+cu124 |
| ESMFold2 | `/opt/conda-esmfold2` (Py 3.12) | esm 3.3.0 (Biohub) + predict-structure 153439f | 2.6+cu130 |
| OpenFold 3 | `/opt/conda-openfold` (Py 3.11) | latest | 2.5.1+cu121 |
| DiffDock | `/opt/conda-diffdock` (Py 3.11) | v1.1 | 2.1.2+cu121 |

## BV-BRC Integration

| Component | Path | Status |
|-----------|------|--------|
| Perl runtime | `/opt/patric-common/runtime` | Perl 5.40 |
| BV-BRC deployment | `/opt/p3/deployment` | Full deploy from production base |
| App-PredictStructure | `/opt/p3/deployment/plbin/App-PredictStructure.pl` | d7f2a43 |
| App specs | `/opt/p3/deployment/services/app_service/app_specs/` | PredictStructure.json + modes/ |
| dev_container | `/build/dev_container` | With PredictStructureApp module |

## Runtime Fixes Applied

- **LD_LIBRARY_PATH glob** in `90-environment.sh` — auto-discovers CUDA libs from conda envs (fixes Boltz cu13 `libnvrtc-builtins.so.13.0`)
- **BV-BRC env vars** in `90-environment.sh` — `KB_TOP`, `PERL5LIB`, `PATH`, `IN_BVBRC_CONTAINER`
- **Empty `if` blocks removed** from `90-environment.sh` — empty `if [[ -d /local_databases/... ]]; then fi` blocks caused shell parse error under apptainer 1.5.0's strict POSIX env-script parser, preventing env setup and `p3x-app-shepherd` from being found. Apptainer 1.4.5 tolerated the syntax error; 1.5.0 made it fatal.
- **BVBRC.* SIF labels** — `stamp-labels.sh` writes provenance (predict-structure commit, App-PredictStructure commit, runtime_build commit, build date/user) to `/.singularity.d/labels.json` before repack so `apptainer inspect` shows what's actually in each image

## Sandbox State

| Field | Value |
|-------|-------|
| Path | `/scout/tmp/all-sandbox` |
| Source | Production base `cuda-12.2-025-base-gpu.2026-05-11.002.sif` |
| Squashfs offset | 61440 |

The sandbox persists between builds. To update just the app, modify the sandbox and repack.

## Build History

| Image | Date | Notes |
|-------|------|-------|
| folding_260622.1.sif | 2026-06-22 | Current prod. predict-structure 153439f — PredictStructureApp PRs #57–#68 merged (HF-offline, GPU preflight contract, chai 2048 guard, AF2 auto-multimer, openfold msa-url, esmfold2 tests, app_spec text_input, boltz-report cwl, CI). Validated on H200: 21/21 + real Boltz/ESMFold2/ESMFold folds. |
| folding_260610.1.sif | 2026-06-10 | Adds `/opt/conda-esmfold2` (Biohub esm 3.3.0). predict-structure 5795319 (post-PR-44 ESMFold2 integration), reinstalled in both predict + esmfold2 envs. 21/21 env checks. |
| folding_260602.1.sif | 2026-06-02 | Current prod. predict-structure 10c9c9c. |
| folding_260601.1.sif | 2026-06-01 | predict-structure c30a83e. First build with BVBRC.* labels. |
| folding_260522.1.sif | 2026-05-22 | Fixed empty `if` blocks in 90-environment.sh that broke env setup under apptainer 1.5.0+. |
| folding_260515.2.sif | 2026-05-15 | Force-reinstall fix for stale pip cache. |
| folding_260515.1.sif | 2026-05-15 | Had stale predict-structure code (pip cache issue). |
| folding_260514.2.sif | 2026-05-14 | Last working image before clean rebuild attempt. Based on production base. |
| folding_260514.3.sif | 2026-05-14 | Broken — missing /opt/p3/deployment. Deleted. |
| folding_260514.4.sif | 2026-05-14 | Broken — incomplete /opt/p3 mirror. Deleted. |
| folding_260513.1.sif | 2026-05-13 | App update (944a40f). |
| folding_260512.4.sif | 2026-05-12 | Added LD_LIBRARY_PATH glob fix for Boltz cu13. |
| base-gpu.2026-05-14.001.sif | 2026-05-14 | Clean from-scratch base via build-gpu-container. |
| base-gpu.2026-05-06.001.sif | 2026-05-06 | Previous from-scratch base. |

## Known Issues

- **protein_compare `__version__`**: `__init__.py` shows 0.2.0 but `setup.py` is 0.2.1. Fix needed in `wilke/protein_structure_analysis` repo.
- **OpenFold 3 evoformer_attn**: JIT kernel fails on H200 — needs CUDA 12.6+ for cuEquivariance. Currently disabled/fallback.
- **Boltz cu130**: Requires LD_LIBRARY_PATH glob to find `libnvrtc-builtins.so.13.0`. Applied as runtime fix.
