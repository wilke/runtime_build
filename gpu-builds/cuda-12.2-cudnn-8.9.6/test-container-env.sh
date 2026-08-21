#!/usr/bin/env bash
set -euo pipefail

SIF="${1:?Usage: $0 <sif-path>}"

if [[ ! -e "$SIF" ]]; then
    echo "FAIL: SIF/sandbox not found: $SIF" >&2
    exit 1
fi

PASS=0
FAIL=0

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label"
        FAIL=$((FAIL+1))
    fi
}

run() { apptainer exec "$SIF" "$@"; }

echo "Testing container: $SIF"
echo

echo "== Shell environment =="
check "90-environment.sh parses"      run bash -c 'source /.singularity.d/env/90-environment.sh'
check "KB_TOP is set"                 run bash -c 'test -n "$KB_TOP"'
check "PERL5LIB is set"              run bash -c 'test -n "$PERL5LIB"'
check "LD_LIBRARY_PATH is set"       run bash -c 'test -n "$LD_LIBRARY_PATH"'

echo
echo "== BV-BRC runtime =="
check "p3x-app-shepherd on PATH"     run which p3x-app-shepherd
check "App-PredictStructure.pl exists" run test -f /opt/p3/deployment/plbin/App-PredictStructure.pl
check "perl syntax OK"               run perl -c /opt/p3/deployment/plbin/App-PredictStructure.pl

echo
echo "== Python tools =="
check "predict-structure --version"   run bash -c '. /opt/miniforge/etc/profile.d/conda.sh && conda activate /opt/conda-predict && predict-structure --version'
check "protein_compare importable"    run bash -c '. /opt/miniforge/etc/profile.d/conda.sh && conda activate /opt/conda-predict && python -c "import protein_compare"'

echo
echo "== Conda envs exist =="
for env in predict alphafold boltz chai diffdock esmfold esmfold2 openfold stabilinnator; do
    check "/opt/conda-$env"           run test -d "/opt/conda-$env"
done

echo
echo "== ESMFold2 =="
check "esm importable in conda-esmfold2"   run /opt/conda-esmfold2/bin/python -c 'import esm'
# The runner is invoked by FILE PATH from the conda-predict install; the tool
# env deliberately has no predict_structure (PredictStructureApp#98), so the
# old `-m` form must NOT work — assert both directions.
# The glob must resolve to ONE path: conda ships a python3.1 -> python3.12
# symlink, so `python3.*` expands to two, and python would run the first script
# with the second as a stray positional arg -- argparse rejects it and the
# check fails on a perfectly good image.
check "esmfold2 runner file runs under tool env"  run bash -c '
    r=$(ls -d /opt/conda-predict/lib/python3.*/site-packages/predict_structure/runners/esmfold2.py \
        | xargs -r readlink -f | sort -u | head -1)
    test -n "$r" && /opt/conda-esmfold2/bin/python "$r" --help >/dev/null'
check "tool env has NO predict_structure (#98)"   run bash -c '! /opt/conda-esmfold2/bin/python -c "import predict_structure" 2>/dev/null'

echo
echo "== stabiliNNator =="
check "torch + PyG import in conda-stabilinnator" run /opt/conda-stabilinnator/bin/python -c 'import torch, torch_geometric, torch_scatter, torch_sparse'
check "model code present"           run test -f /opt/stabilinnator/proliNNator/proliNNator.py
check "disulfide code present"       run test -f /opt/stabilinnator/disulfiNNate/predict_cysteine_probabilities.py
# proline_gat ships in the pre-2.4 PyG layout and MUST have been converted at
# build time; cys_gat is GATv2Conv and is already current -- asserting lin_src
# on it would be wrong. See reqts-stabilinnator.def.
check "proline ckpt converted to PyG 2.4"  run /opt/conda-stabilinnator/bin/python -c '
import torch,sys
k=set(torch.load("/opt/stabilinnator/proliNNator/models/proline_gat.pt",map_location="cpu"))
sys.exit(0 if {"gat.lin_src.weight","gat.lin_dst.weight"}<=k and "gat.lin.weight" not in k else 1)'
check "disulfide ckpt intact (GATv2)"      run /opt/conda-stabilinnator/bin/python -c '
import torch,sys
k=set(torch.load("/opt/stabilinnator/disulfiNNate/models/cys_gat.pt",map_location="cpu"))
sys.exit(0 if {"gat.lin_l.weight","gat.lin_r.weight"}<=k else 1)'
check "stabilinnator wrapper on PATH" run which stabilinnator
# The wrappers must NOT call bare `python` -- in this image that resolves to
# conda-predict (3.12, no torch/PyG). They must name this env's interpreter.
check "wrappers pin the stabilinnator interpreter" run bash -c '
grep -q "/opt/conda-stabilinnator/bin/python" /usr/local/bin/prolinnator &&
grep -q "/opt/conda-stabilinnator/bin/python" /usr/local/bin/disulfinnate'
# ...and conversely the env must stay OFF the global PATH, or it shadows
# conda-predict'"'"'s python for every other tool in the image.
check "stabilinnator env NOT on global PATH" run bash -c '
case ":$PATH:" in *:/opt/conda-stabilinnator/bin:*) exit 1;; *) exit 0;; esac'
check "conda-stabilinnator has NO predict_structure" run bash -c '
! /opt/conda-stabilinnator/bin/python -c "import predict_structure" 2>/dev/null'

echo
echo "== StabiliNNator BV-BRC app =="
check "App-StabiliNNator.pl exists"  run test -f /opt/p3/deployment/plbin/App-StabiliNNator.pl
check "App-StabiliNNator perl syntax OK" run perl -c /opt/p3/deployment/plbin/App-StabiliNNator.pl
check "StabiliNNator.json deployed"  run test -f /opt/p3/deployment/services/app_service/app_specs/StabiliNNator.json
check "report generator deployed"    run test -f /kb/module/StabiliNNatorApp/report/generate_report.py
check "3Dmol viewer lib deployed"    run test -s /kb/module/StabiliNNatorApp/report/vendor/3Dmol-min.js
# The Perl calls bare `python` via system(); the wrapper is the only thing that
# makes that resolve to the torch env. If the wrapper stops doing this, every
# StabiliNNator job dies at model import.
#
# Assert the tool env is FIRST, not merely mentioned: appending it instead of
# prepending leaves bare `python` resolving to conda-predict while a plain
# grep still passes.
check "App wrapper puts the tool env FIRST on PATH" run bash -c '
    p=$(grep -m1 "^export PATH=" /opt/p3/deployment/bin/App-StabiliNNator | cut -d= -f2- | tr -d \")
    case "$p" in /opt/conda-stabilinnator/bin:*) exit 0;; *) exit 1;; esac'
# Resolve `python` through the WRAPPER''s own PATH line rather than a
# hand-built one -- otherwise the check passes even if the wrapper is deleted.
check "bare python under the wrapper has torch+PyG" run bash -c '
    eval "$(grep -m1 "^export PATH=" /opt/p3/deployment/bin/App-StabiliNNator)"
    python -c "import torch, torch_geometric"'

echo
echo "== Duplicated copies agree (#110) =="
# The container carries the Perl app and the app spec in up to three places:
# the deployed copy the AppService actually reads, the dev_container checkout,
# and the /kb/module fallback. Only the deployed copies run, so a stale one is
# invisible until a user hits it -- the #98 and #110 failure mode. Assert every
# present copy is byte-identical to the deployed one.
agree() {
    # $1 = deployed path, $2..= other paths that must match if they exist
    local deployed="$1"; shift
    run bash -c '
        set -e
        d="$1"; shift
        test -f "$d" || exit 1
        want=$(md5sum "$d" | cut -d" " -f1)
        seen=0
        for p in "$@"; do
            [ -e "$p" ] || continue
            seen=$((seen+1))
            [ "$(md5sum "$p" | cut -d" " -f1)" = "$want" ] || exit 1
        done
        # If NO comparand exists there is nothing to agree with, and skipping
        # them all silently reports green on a deploy that wrote nothing.
        [ "$seen" -gt 0 ]
    ' _ "$deployed" "$@"
}
check "App-PredictStructure.pl copies agree" agree \
    /opt/p3/deployment/plbin/App-PredictStructure.pl \
    /build/dev_container/modules/PredictStructureApp/service-scripts/App-PredictStructure.pl \
    /kb/module/service-scripts/App-PredictStructure.pl
check "PredictStructure.json copies agree"   agree \
    /opt/p3/deployment/services/app_service/app_specs/PredictStructure.json \
    /build/dev_container/modules/PredictStructureApp/app_specs/PredictStructure.json \
    /kb/module/app_specs/PredictStructure.json

echo
echo "== CUDA =="
check "nvidia-smi accessible"        run bash -c 'nvidia-smi >/dev/null 2>&1 || test -f /usr/local/cuda-12.2/version.json'
check "CUDA_HOME set"                run bash -c 'test -n "$CUDA_HOME"'

echo
echo "---"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
