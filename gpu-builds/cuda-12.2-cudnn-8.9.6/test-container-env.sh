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
for env in predict alphafold boltz chai diffdock esmfold esmfold2 openfold; do
    check "/opt/conda-$env"           run test -d "/opt/conda-$env"
done

echo
echo "== ESMFold2 =="
check "esm importable in conda-esmfold2"   run /opt/conda-esmfold2/bin/python -c 'import esm'
# The runner is invoked by FILE PATH from the conda-predict install; the tool
# env deliberately has no predict_structure (PredictStructureApp#98), so the
# old `-m` form must NOT work — assert both directions.
check "esmfold2 runner file runs under tool env"  run bash -c '/opt/conda-esmfold2/bin/python /opt/conda-predict/lib/python3.*/site-packages/predict_structure/runners/esmfold2.py --help >/dev/null'
check "tool env has NO predict_structure (#98)"   run bash -c '! /opt/conda-esmfold2/bin/python -c "import predict_structure" 2>/dev/null'

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
        for p in "$@"; do
            [ -e "$p" ] || continue
            [ "$(md5sum "$p" | cut -d" " -f1)" = "$want" ] || exit 1
        done
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
