#!/usr/bin/env bash
# Stamp BVBRC.* metadata into the sandbox's labels.json before repacking.
# These labels are preserved by `apptainer build` and visible via `apptainer inspect`.
set -euo pipefail

SANDBOX="${1:?Usage: $0 <sandbox-path> <target-sif-name> [base-sif-path]}"
SIF_NAME="${2:?Usage: $0 <sandbox-path> <target-sif-name> [base-sif-path]}"
BASE_SIF="${3:-/vol/patric3/production/containers/cuda-12.2-025-base-gpu.2026-05-11.002.sif}"

LABELS="$SANDBOX/.singularity.d/labels.json"
[[ -f "$LABELS" ]] || { echo "FAIL: labels.json not found at $LABELS" >&2; exit 1; }

# --- Gather metadata from sandbox ---

# predict-structure: read version from dist-info dir name, commit from direct_url.json
PS_DIST=$(find "$SANDBOX/opt/conda-predict/lib/python3.12/site-packages" \
    -maxdepth 1 -name 'predict_structure-*.dist-info' -type d 2>/dev/null | head -1)
if [[ -n "$PS_DIST" ]]; then
    PS_VERSION=$(basename "$PS_DIST" | sed 's/^predict_structure-//; s/.dist-info$//')
    PS_COMMIT=$(python3 -c "import json; print(json.load(open('$PS_DIST/direct_url.json'))['vcs_info']['commit_id'])" 2>/dev/null || echo "unknown")
else
    PS_VERSION="unknown"
    PS_COMMIT="unknown"
fi

# protein_compare (report tool): commit from direct_url.json in conda-predict
PC_DIST=$(find "$SANDBOX/opt/conda-predict/lib/python3.12/site-packages" \
    -maxdepth 1 -name 'protein_compare-*.dist-info' -type d 2>/dev/null | head -1)
if [[ -n "$PC_DIST" ]]; then
    PC_COMMIT=$(python3 -c "import json; print(json.load(open('$PC_DIST/direct_url.json'))['vcs_info']['commit_id'])" 2>/dev/null || echo "unknown")
else
    PC_COMMIT="unknown"
fi

# App-PredictStructure: read HEAD from the deployed git repo
APP_REPO="$SANDBOX/build/dev_container/modules/PredictStructureApp"
if [[ -d "$APP_REPO/.git" ]]; then
    APP_HEAD=$(cat "$APP_REPO/.git/HEAD")
    if [[ "$APP_HEAD" =~ ^ref:\ (.+)$ ]]; then
        APP_COMMIT=$(cat "$APP_REPO/.git/${BASH_REMATCH[1]}" 2>/dev/null || echo "unknown")
    else
        APP_COMMIT="$APP_HEAD"
    fi
else
    APP_COMMIT="unknown"
fi

# runtime_build: this repo's commit (script directory's repo)
RB_COMMIT=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse HEAD 2>/dev/null || echo "unknown")

BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_USER="${USER:-unknown}"

echo "Stamping labels:"
echo "  BVBRC.sif_name                    = $SIF_NAME"
echo "  BVBRC.build_date                  = $BUILD_DATE"
echo "  BVBRC.build_user                  = $BUILD_USER"
echo "  BVBRC.base_sif                    = $BASE_SIF"
echo "  BVBRC.runtime_build_commit        = $RB_COMMIT"
echo "  BVBRC.predict_structure_version   = $PS_VERSION"
echo "  BVBRC.predict_structure_commit    = $PS_COMMIT"
echo "  BVBRC.protein_compare_commit      = $PC_COMMIT"
echo "  BVBRC.app_predictstructure_commit = $APP_COMMIT"

# --- Merge into labels.json ---
python3 <<PYEOF
import json
with open("$LABELS") as f:
    labels = json.load(f)
labels.update({
    "BVBRC.sif_name":                    "$SIF_NAME",
    "BVBRC.build_date":                  "$BUILD_DATE",
    "BVBRC.build_user":                  "$BUILD_USER",
    "BVBRC.base_sif":                    "$BASE_SIF",
    "BVBRC.runtime_build_commit":        "$RB_COMMIT",
    "BVBRC.predict_structure_version":   "$PS_VERSION",
    "BVBRC.predict_structure_commit":    "$PS_COMMIT",
    "BVBRC.protein_compare_commit":      "$PC_COMMIT",
    "BVBRC.app_predictstructure_commit": "$APP_COMMIT",
})
with open("$LABELS", "w") as f:
    json.dump(labels, f, indent="\t")
    f.write("\n")
PYEOF

echo
echo "Labels stamped. Now repack with: apptainer build --fakeroot <target.sif> $SANDBOX"
