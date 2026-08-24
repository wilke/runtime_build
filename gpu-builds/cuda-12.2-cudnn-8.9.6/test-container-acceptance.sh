#!/bin/bash
# Local acceptance for a freshly built folding SIF.
# Exercises the SERVICE-SCRIPT path, not just the CLI — F01 passed every local
# CLI check and still died in production because App-PredictStructure.pl added
# a flag the subcommand did not define.
SIF="${1:?Usage: EXPECT=<short-commit> $0 <sif> <workdir>}"
WORK="${2:?Usage: EXPECT=<short-commit> $0 <sif> <workdir>}"
# An empty WORK makes every `--bind ":"` fail, and an unset EXPECT compares
# every commit against "" -- both produce a wall of confusing failures.
[ -d "$WORK" ] || { echo "FAIL: workdir not found: $WORK" >&2; exit 1; }
[ -n "${EXPECT:-}" ] || { echo "FAIL: set EXPECT=<short-commit> (the commit you meant to ship)" >&2; exit 1; }
pass=0; fail=0; skip=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; echo "        $2"; fail=$((fail+1)); }
run()  { apptainer exec --bind /local_databases --bind "$WORK:$WORK" "$SIF" "$@" 2>&1; }

echo "== 1. provenance =="
c=$(apptainer inspect "$SIF" | awk -F': ' '/predict_structure_commit/{print substr($2,1,7)}')
a=$(apptainer inspect "$SIF" | awk -F': ' '/app_predictstructure_commit/{print substr($2,1,7)}')
[ "$c" = "$EXPECT" ] && ok "predict_structure_commit=$c" || bad "predict_structure_commit" "got $c want $EXPECT"
[ "$a" = "$EXPECT" ] && ok "app_predictstructure_commit=$a" || bad "app_predictstructure_commit" "got $a want $EXPECT"

echo "== 1a. exactly ONE real install of predict_structure (#98) =="
n=$(apptainer exec "$SIF" /bin/bash -c 'ls -d /opt/conda-*/lib/python3.*/site-packages/predict_structure 2>/dev/null | xargs -r readlink -f | sort -u | wc -l')
[ "$n" = "1" ] && ok "single install" || bad "install count" "$n real copies — the stale-copy hazard is back (#98)"

echo "== 1a2. the esmfold2 command invokes the runner by path, not -m =="
c=$(apptainer exec "$SIF" /opt/conda-predict/bin/python -c "from predict_structure.config import get_command; print(' '.join(get_command('esmfold2')))")
case "$c" in
  *" -m "*) bad "esmfold2 invocation" "still uses -m: $c";;
  *runners/esmfold2.py*) ok "path invocation: ...$(echo $c | grep -o 'runners/esmfold2.py.*' | head -c 40)";;
  *) bad "esmfold2 invocation" "unexpected: $c";;
esac

echo "== 1b. EVERY env carrying our package must report the same commit (#98) =="
commits=$(apptainer exec "$SIF" /bin/bash -c '
for e in /opt/conda-*/; do
  d=$(ls -d ${e}lib/python3.*/site-packages/predict_structure-*.dist-info 2>/dev/null | head -1)
  [ -n "$d" ] && echo "$(basename $e)=$(python3 -c "import json;print(json.load(open(\"$d/direct_url.json\"))[\"vcs_info\"][\"commit_id\"][:7])" 2>/dev/null)"
done')
uniq_c=$(echo "$commits" | cut -d= -f2 | sort -u | wc -l)
if [ "$uniq_c" = "1" ]; then ok "all copies agree: $(echo $commits | tr '\n' ' ')"
else bad "predict_structure copies DISAGREE" "$(echo $commits | tr '\n' ' ') -- see #98"; fi

echo "== 1c. the esmfold2 runner (which runs from its OWN env) has the MSA code =="
# Load the runner BY PATH from the conda-predict install, which is how the
# esmfold2 command actually invokes it. Importing `predict_structure` from the
# esmfold2 env would contradict the other half of the #98 contract (that env
# must NOT contain the package) and so would fail on a correct image.
h=$(apptainer exec "$SIF" /bin/bash -c '
  f=$(ls -d /opt/conda-predict/lib/python3.*/site-packages/predict_structure/runners/esmfold2.py \
      | xargs -r readlink -f | sort -u | head -1)
  /opt/conda-esmfold2/bin/python -c "
import importlib.util, inspect
spec = importlib.util.spec_from_file_location(\"esmfold2_runner\", \"$f\")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(\"_msa\" in inspect.getsource(m._build_inputs))"' 2>/dev/null | tail -1)
[ "$h" = "True" ] && ok "esmfold2 runner (loaded by path) has _msa" \
  || bad "esmfold2 runner" "_msa absent or runner failed to load: '$h' (#98)"

echo "== 2. baked-in code (no bind-mount shadowing) =="
out=$(apptainer exec "$SIF" /opt/conda-predict/bin/python -c "
from predict_structure.adapters import get_adapter
from predict_structure.msa_check import _TOOL_MSA_SPECS
a=get_adapter('esmfold2')
print(a.supports_msa, a.min_gpu_memory_mb, a.preflight()['policy_data']['constraint'], 'esmfold2' in _TOOL_MSA_SPECS)")
[ "$out" = "True 18000 H200 True" ] && ok "esmfold2 adapter: $out" || bad "esmfold2 adapter" "got '$out' want 'True 18000 H200 True'"

echo "== 3. #94: esmfold2 subcommand must NOT define --use-msa-server =="
n=$(run /opt/conda-predict/bin/predict-structure esmfold2 --help | grep -c "use-msa-server")
[ "$n" = "0" ] && ok "esmfold2 has no --use-msa-server" || bad "esmfold2 --use-msa-server" "found $n occurrences"

echo "== 4. #94: the Perl must not pass it either =="
n=$(apptainer exec "$SIF" grep -c 'esmfold|esmfold2|alphafold' /opt/p3/deployment/plbin/App-PredictStructure.pl)
[ "$n" -ge 1 ] && ok "plbin exclusion regex includes esmfold2" || bad "plbin exclusion" "regex not found in deployed Perl"

echo "== 5. #90: auto never resolves to alphafold; explicit still works =="
for args in "--has-protein" "--has-protein --use-msa-server" "--has-protein --device cpu"; do
  r=$(run /opt/conda-predict/bin/predict-structure preflight --tool auto $args | head -c 400)
  echo "$r" | grep -q '"resolved_tool": "alphafold"' && bad "auto $args" "resolved to alphafold" || ok "auto $args -> $(echo "$r" | sed 's/.*resolved_tool": "\([a-z0-9]*\)".*/\1/')"
done
run /opt/conda-predict/bin/predict-structure preflight --tool alphafold --has-protein | grep -q '"resolved_tool": "alphafold"' \
  && ok "explicit alphafold still works" || bad "explicit alphafold" "preflight did not resolve"

echo "== 6. THE F01 PATH: service-script preflight for esmfold2 =="
cat > "$WORK/p_esm2.json" <<JSON
{"tool":"esmfold2","input_file":"/awilke@bvbrc/home/AppTests/inputs/simple_protein.fasta",
 "output_path":"/awilke@bvbrc/home/AppTests","output_file":"local_acceptance"}
JSON
r=$(apptainer exec --bind /local_databases --bind "$WORK:$WORK" "$SIF" /bin/bash -lc \
  "rm -f $WORK/pf.json $WORK/err.txt; perl /opt/p3/deployment/plbin/App-PredictStructure.pl \
   --preflight $WORK/pf.json --user-error-file $WORK/err.txt \
   https://p3.theseed.org/services/app_service \
   /opt/p3/deployment/services/app_service/app_specs/PredictStructure.json $WORK/p_esm2.json; echo rc=\$?")
rc=$(echo "$r" | grep -o 'rc=[0-9]*' | tail -1)
if [ "$rc" = "rc=0" ] && [ -s "$WORK/pf.json" ]; then
  ok "esmfold2 service preflight rc=0, resources written: $(tr -d '\n ' < "$WORK/pf.json" | head -c 90)"
else
  bad "esmfold2 service preflight" "$rc; err=$(cat "$WORK/err.txt" 2>/dev/null | head -c 200)"
fi

echo "== 7. the command the service would actually run (F01's exact failure) =="
r=$(run /opt/conda-predict/bin/predict-structure esmfold2 --protein "$WORK/crambin.fasta" \
      -o "$WORK/out_dbg" --debug)
echo "$r" | grep -q "use-msa-server" && bad "esmfold2 debug cmd" "still contains --use-msa-server" \
  || ok "esmfold2 command line is clean"

echo "== 8. #97: MSA upload reaches the spec =="
r=$(run /opt/conda-predict/bin/predict-structure esmfold2 --protein "$WORK/crambin.fasta" \
      --msa /local_databases/../dev/null -o "$WORK/out_badmsa" --debug 2>&1 | tail -2)
run /opt/conda-predict/bin/predict-structure esmfold2 --protein "$WORK/crambin.fasta" \
      --msa "$WORK/crambin.a3m" -o "$WORK/out_msa" --debug >/dev/null 2>&1
if grep -q '"msa"' "$WORK/out_msa/input.json" 2>/dev/null; then
  ok "MSA recorded in spec: $(grep -o '"msa": "[^"]*"' "$WORK/out_msa/input.json")"
else
  bad "MSA upload" "no msa key in $WORK/out_msa/input.json"
fi

echo "== 9. #97: mismatched MSA rejected with a clear message =="
r=$(run /opt/conda-predict/bin/predict-structure esmfold2 --protein "$WORK/other.fasta" \
      --msa "$WORK/crambin.a3m" -o "$WORK/out_mm" --debug | tail -3)
echo "$r" | grep -q "does not match any protein chain" && ok "mismatch rejected clearly" \
  || bad "mismatch handling" "$(echo "$r" | head -c 200)"

echo "== 10. #106: raw_output pruned before upload, guarded on raw/ =="
n=$(apptainer exec "$SIF" grep -c "prune_raw_output" /opt/p3/deployment/plbin/App-PredictStructure.pl)
[ "$n" -ge 2 ] && ok "prune_raw_output present in deployed Perl ($n refs)" \
  || bad "prune_raw_output" "found $n refs in deployed Perl"
order=$(apptainer exec "$SIF" grep -n "prune_raw_output(\$output_dir)\|upload_results(\$app" /opt/p3/deployment/plbin/App-PredictStructure.pl | head -2 | cut -d: -f1 | tr '\n' ' ')
p1=$(echo $order | cut -d' ' -f1); p2=$(echo $order | cut -d' ' -f2)
[ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" -lt "$p2" ] && ok "prune runs before upload (lines $p1 < $p2)" \
  || bad "prune ordering" "prune=$p1 upload=$p2 -- prune must precede upload"

echo "== 11. #108: chain IDs refuse to wrap past Z =="
r=$(apptainer exec "$SIF" /opt/conda-predict/bin/python -c "
from predict_structure.entities import EntityList, EntityType
el = EntityList()
for i in range(26):
    el.add(EntityType.PROTEIN, 'ACDEFGHIKL', name='c%d' % i)
ids = [e.chain_id for e in el.entities]
assert len(set(ids)) == 26, 'duplicate chain IDs below the cap'
try:
    el.add(EntityType.PROTEIN, 'ACDEFGHIKL', name='overflow')
    print('NO_RAISE')
except ValueError as exc:
    print('RAISED' if 'force' in str(exc).lower() else 'RAISED_NO_FORCE_NOTE')
" 2>&1 | tail -1)
[ "$r" = "RAISED" ] && ok "27th entity refused, message mentions --force" \
  || bad "chain-ID exhaustion" "got '$r' (want RAISED)"

echo "== 12. #104: the duplicate CWL workflow is gone from the image =="
n=$(apptainer exec "$SIF" /bin/bash -c 'ls /opt/conda-predict/lib/python3.*/site-packages/predict_structure/cwl/workflows/boltz-report-msa.cwl 2>/dev/null | wc -l')
[ "$n" = "0" ] && ok "boltz-report-msa.cwl absent" || bad "boltz-report-msa.cwl" "still packaged ($n)"

echo "== 13. #79/#80: report fixes reached protein_compare in the image =="
r=$(apptainer exec "$SIF" /bin/bash -c 'cd /tmp && /opt/conda-predict/bin/python -c "
import inspect
from protein_compare.visualization import structure_report as sr
src = inspect.getsource(sr)
print(int(\"_mark_zero_count_bins\" in src), int(\"Contents\" in src))
"' 2>&1 | tail -1)
[ "$r" = "1 1" ] && ok "#79 sliver helper + #80 Contents nav present" \
  || bad "protein_compare report fixes" "markers=$r (want '1 1') -- stale protein_compare?"

echo "== 14. StabiliNNator: the interpreter contract =="
# App-StabiliNNator.pl calls bare `python` via system() at three sites and has
# no interpreter override. In this image bare `python` is conda-predict's 3.12,
# which has no torch and no PyG -- so the ONLY thing standing between a working
# job and an ImportError is the deploy wrapper's PATH. Assert it end to end,
# the same way the service will hit it.
# FIRST, not merely present: appending the tool env still leaves bare `python`
# resolving to conda-predict, and a plain grep would call that a pass.
w=/opt/p3/deployment/bin/App-StabiliNNator
r=$(apptainer exec "$SIF" /bin/bash -c "
    p=\$(grep -m1 '^export PATH=' $w | cut -d= -f2- | tr -d '\"')
    case \"\$p\" in /opt/conda-stabilinnator/bin:*) echo yes;; *) echo \"no: \$p\";; esac" 2>&1 | tail -1)
[ "$r" = "yes" ] && ok "wrapper puts the tool env FIRST on PATH" \
  || bad "wrapper PATH" "$w does not PREPEND /opt/conda-stabilinnator/bin ($r)"

# The real assertion: resolve `python` exactly as the wrapper leaves it, then
# import what the model code needs. This is the check that would have caught a
# wrapper regression before a user did.
r=$(apptainer exec "$SIF" /bin/bash -c '
    eval "$(grep "^export PATH=" /opt/p3/deployment/bin/App-StabiliNNator)"
    python -c "import torch, torch_geometric; print(\"OK\", torch.__version__)"' 2>&1 | tail -1)
case "$r" in
  OK*) ok "bare python under the wrapper has torch+PyG ($r)";;
  *)   bad "bare python under wrapper" "got: $r";;
esac

echo "== 15. StabiliNNator: checkpoints match their architectures =="
# proline_gat is GATConv and MUST have been converted to the PyG 2.4 layout;
# cys_gat is GATv2Conv and must NOT be (it has no lin_src and never will).
# One shared assertion over both is wrong -- that mistake fails the disulfide
# model, which is why these are separate.
r=$(apptainer exec "$SIF" /opt/conda-stabilinnator/bin/python -c "
import torch
p=set(torch.load('/opt/stabilinnator/proliNNator/models/proline_gat.pt',map_location='cpu'))
d=set(torch.load('/opt/stabilinnator/disulfiNNate/models/cys_gat.pt',map_location='cpu'))
print(int({'gat.lin_src.weight','gat.lin_dst.weight'}<=p and 'gat.lin.weight' not in p),
      int({'gat.lin_l.weight','gat.lin_r.weight'}<=d))" 2>&1 | tail -1)
[ "$r" = "1 1" ] && ok "proline converted, disulfide intact" \
  || bad "checkpoint layout" "markers=$r (want '1 1')"

echo "== 16. StabiliNNator: a real prediction through the wrappers =="
# The models are 14-22 KB and run on CPU in seconds, so unlike the folding
# tools this is cheap enough to actually run in acceptance. Uses the test PDB
# shipped with the app repo; skips (does not fail) if it is not staged.
# `--device cpu` is deliberate and mirrors production: the app spec ships
# accelerator=cpu / gpu_count:0, and the tool's own docs recommend CPU (the
# models are 14-22 KB; CUDA init costs more than the inference).
#
# It is also REQUIRED here. The upstream scripts default --device to "cuda", so
# without this flag torch tries to deserialize the checkpoint onto a CUDA
# device and dies with "Attempting to deserialize object on a CUDA device but
# torch.cuda.is_available() is False" whenever the container runs without --nv.
# The service path never hits that, because App-StabiliNNator.pl probes
# torch.cuda.is_available() and passes --device explicitly -- so passing it
# here is what actually reproduces production.
if [ -s "$WORK/1crn_small.pdb" ]; then
  r=$(run /bin/bash -c "cd $WORK && stabilinnator proline --pdb-path $WORK/1crn_small.pdb \
        --output-path $WORK/acc_proline.pdb --device cpu >/dev/null 2>&1; echo rc=\$?" 2>&1 | tail -1)
  if [ "$r" = "rc=0" ] && [ -s "$WORK/acc_proline.pdb" ]; then
    # probabilities live in the B-factor column; a file of all-zero B-factors
    # means the model loaded but predicted nothing useful.
    nz=$(awk '/^ATOM/{b=substr($0,61,6)+0; if(b>0) n++} END{print n+0}' "$WORK/acc_proline.pdb")
    [ "$nz" -gt 0 ] && ok "proline prediction wrote $nz non-zero B-factors" \
      || bad "proline prediction" "output has no non-zero B-factors"
  else
    bad "proline prediction" "$r (see $WORK/acc_proline.pdb)"
  fi
else
  # A silent SKIP on the ONLY end-to-end model invocation prints
  # "RESULT: N passed, 0 failed" while never running a prediction. Count it.
  echo "  SKIP  proline prediction — 1crn_small.pdb not staged in $WORK"
  skip=$((skip+1))
fi

echo "== 17. StabiliNNator: THE SERVICE PATH (preflight, not the CLI) =="
# Sections 14-16 exercise the wrappers and the model. None of them touch the
# Perl entrypoint the scheduler actually calls -- which is exactly the F01
# failure mode: every CLI check passed and the job still died because the
# service path differed. Mirror section 6, for the other app.
cat > "$WORK/p_stab.json" <<JSON
{"input_file":"/test/protein.pdb","analysis_type":"both","output_path":"/test/output"}
JSON
r=$(apptainer exec --bind "$WORK:$WORK" "$SIF" /bin/bash -lc \
  "rm -f $WORK/pf_stab.json $WORK/err_stab.txt; perl /opt/p3/deployment/plbin/App-StabiliNNator.pl \
   --preflight $WORK/pf_stab.json --user-error-file $WORK/err_stab.txt \
   https://p3.theseed.org/services/app_service \
   /opt/p3/deployment/services/app_service/app_specs/StabiliNNator.json $WORK/p_stab.json; echo rc=\$?")
rc=$(echo "$r" | grep -o 'rc=[0-9]*' | tail -1)
if [ "$rc" = "rc=0" ] && [ -s "$WORK/pf_stab.json" ]; then
  ok "StabiliNNator service preflight rc=0: $(tr -d '\n ' < "$WORK/pf_stab.json" | head -c 80)"
else
  bad "StabiliNNator service preflight" "$rc; err=$(cat "$WORK/err_stab.txt" 2>/dev/null | head -c 200)"
fi

# rc=0 and a non-empty file are NOT enough: StabiliNNator shipped
# partition => 'normal', preflight returned rc=0 with well-formed JSON, the
# scheduler logged "Submitted" and then silently refused to dispatch -- no
# task_status dir, no stdout/stderr, just status=failed (tasks 23450684,
# 23450690). So assert the CONTENT of the partition, for BOTH apps.
#
# The cluster has exactly two partitions: gpu2 and compute (per wilke,
# 2026-08-24). GPU work goes to gpu2; CPU-only work goes to compute.
# Omitting policy_data entirely is also fine -- 91 of 94 deployed BV-BRC
# apps do that and take the scheduler default. Anything else is a typo that
# fails silently at dispatch, which is the whole reason for this check.
check_partition() {
  # $1 = label, $2 = preflight json file
  local label="$1" f="$2"
  [ -s "$f" ] || { bad "$label partition" "no preflight file to check"; return; }
  local part
  part=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
pd=d.get('policy_data') or {}
print(pd.get('partition','<absent>'))
" "$f" 2>/dev/null)
  case "$part" in
    gpu2|compute|'<absent>')
      ok "$label partition is schedulable ($part)" ;;
    *)
      bad "$label partition" "requests '$part'; the cluster has only gpu2 and compute (or omit policy_data) -- anything else is refused at dispatch with no logs" ;;
  esac
}
check_partition "StabiliNNator" "$WORK/pf_stab.json"
check_partition "PredictStructure" "$WORK/pf.json"

# The partition lives in TWO places for StabiliNNator: the Perl preflight
# (checked above) and the app spec's static preflight.policy_data, which the
# scheduler falls back to. Before 353b6cb the spec had NO partition key at
# all, so a fallback would silently drop the constraint -- the same
# two-copies-drift shape as #98/#110. Assert the spec agrees with the Perl.
# Read the spec out and parse it HERE -- nested quoting inside
# `apptainer exec bash -lc python3 -c "..."` is a reliable way to get a shell
# error string back and mistake it for data.
spec_json=$(run cat /opt/p3/deployment/services/app_service/app_specs/StabiliNNator.json 2>/dev/null)
spec_part=$(printf '%s' "$spec_json" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print((d.get('preflight') or {}).get('policy_data', {}).get('partition', '<absent>'))
except Exception:
    print('<unreadable>')
")
perl_part=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print((d.get('policy_data') or {}).get('partition', '<absent>'))
except Exception:
    print('<none>')
" "$WORK/pf_stab.json" 2>/dev/null)
if [ "$spec_part" = "$perl_part" ]; then
  ok "StabiliNNator app spec partition agrees with preflight ($spec_part)"
else
  bad "StabiliNNator partition copies disagree" "app spec says '$spec_part', Perl preflight emits '$perl_part'"
fi

echo
echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$skip" = "0" ] || echo "NOTE: $skip check(s) skipped — coverage is incomplete."
[ "$fail" = "0" ]
