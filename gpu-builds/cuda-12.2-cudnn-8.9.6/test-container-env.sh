#!/usr/bin/env bash
set -euo pipefail

SIF="${1:?Usage: $0 <sif-path>}"

if [[ ! -f "$SIF" ]]; then
    echo "FAIL: SIF not found: $SIF" >&2
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
for env in predict alphafold boltz chai diffdock esmfold openfold; do
    check "/opt/conda-$env"           run test -d "/opt/conda-$env"
done

echo
echo "== CUDA =="
check "nvidia-smi accessible"        run bash -c 'nvidia-smi >/dev/null 2>&1 || test -f /usr/local/cuda-12.2/version.json'
check "CUDA_HOME set"                run bash -c 'test -n "$CUDA_HOME"'

echo
echo "---"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
