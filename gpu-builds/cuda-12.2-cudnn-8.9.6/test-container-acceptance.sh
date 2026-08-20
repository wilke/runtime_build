#!/bin/bash
# Local acceptance for a freshly built folding SIF.
# Exercises the SERVICE-SCRIPT path, not just the CLI — F01 passed every local
# CLI check and still died in production because App-PredictStructure.pl added
# a flag the subcommand did not define.
SIF="$1"; WORK="$2"
pass=0; fail=0
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
h=$(apptainer exec "$SIF" /opt/conda-esmfold2/bin/python -c "
import inspect
from predict_structure.runners import esmfold2 as r
print('_msa' in inspect.getsource(r._build_inputs))" 2>/dev/null)
[ "$h" = "True" ] && ok "esmfold2 env runner has _msa" || bad "esmfold2 env runner" "stale copy, _msa absent (#98)"

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

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = "0" ]
