#!/usr/bin/env bash
# Independently check pending labels; reuse saved exact checks after labels are deleted.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--help" ]]; then
    echo 'Usage: ./analyze_cuts.sh [work-directory]'
    echo 'Default: the most recent run.sh experiment. Outputs runs.csv, comparison.csv, categories.csv.'
    echo 'Pending labels are independently checked and deleted; saved checks are reused on later analyses.'
    exit 0
fi
export ACC_GP_ROOT="$ROOT"
python3 - "$@" <<'PY'
import csv, fcntl, hashlib, json, math, os, statistics, subprocess, sys
from pathlib import Path

root = Path(os.environ['ACC_GP_ROOT'])
args = sys.argv[1:]
latest = Path(os.environ.get('LATEST_FILE', str(root.parent / 'Acc-GP-archive/manual/LATEST')))
if not args:
    if not latest.is_file(): raise SystemExit('Run ./run.sh first, or provide its work-directory.')
    args = [latest.read_text().strip()]
out = Path(args[0]).resolve()
verify_only = args[2] if len(args) == 3 and args[1] == '--verify-only' else None
if len(args) != 1 and verify_only is None: raise SystemExit('Usage: ./analyze_cuts.sh [work-directory]')
if not (out / 'metadata.json').is_file(): raise SystemExit('Missing experiment metadata: ' + str(out))
run_lock = (out / '.run.lock').open('a')
if os.environ.get('ACC_GP_INTERNAL_ANALYSIS') != '1':
    try: fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('The experiment is still running. Analyze after run.sh finishes.')
lock = (out / '.analysis.lock').open('a')
try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit('Analysis is already running.')
meta = json.loads((out / 'metadata.json').read_text())
graphs = {g['name']: g for g in meta['graphs']}
runs = [json.loads(line) for line in (out / 'runs.jsonl').read_text().splitlines()] if (out / 'runs.jsonl').exists() else []
if len({r['id'] for r in runs}) != len(runs): raise SystemExit('Duplicate native run IDs; refusing to combine them.')
(out / 'checks').mkdir(exist_ok=True)

def save(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)

for run in runs:
    if verify_only is not None and run['graph'] != verify_only: continue
    check_path = out / 'checks' / (run['id'] + '.json')
    fingerprint = hashlib.sha256(json.dumps(run, sort_keys=True).encode()).hexdigest()
    label = Path(run['partition'])
    cached = json.loads(check_path.read_text()) if check_path.exists() else None
    if cached is not None and cached.get('native_record_sha256') != fingerprint:
        raise SystemExit('Native record changed after verification: ' + run['id'])
    if cached is None:
        cached = dict(native_record_sha256=fingerprint, status=run['status'], exact=None,
                      partition_bytes=label.stat().st_size if label.exists() else 0)
        if run['status'] == 'ok':
            if not label.is_file():
                cached.update(status='missing_labels', error='No saved oracle result and no labels; re-run this case.')
            else:
                g = graphs[run['graph']]
                command = [str(out / 'binaries/oracle'), g['indptr'], g['indices'], str(run['k']), str(label),
                           'text' if run['method'] == 'jet' else 'binary']
                result = subprocess.run(command, capture_output=True, text=True,
                                        env=dict(os.environ, OMP_NUM_THREADS='4'))
                try:
                    exact = json.loads(result.stdout)
                    well_formed = (result.returncode in [0, 1] and exact['vertices'] == g['vertices']
                                   and exact['capacity'] == 103 * g['vertices'] // (100 * run['k'])
                                   and len(exact['loads']) == run['k'] and sum(exact['loads']) == g['vertices'])
                    status = ('verified' if exact['capacity_ok'] else 'balance_exceeded') if well_formed else 'invalid_output'
                    if exact['cut'] != run['reported_cut']: status = 'cut_mismatch'
                    cached.update(status=status, exact=exact, oracle_returncode=result.returncode)
                except (ValueError, KeyError, TypeError):
                    cached.update(status='invalid_output', error=result.stdout + result.stderr)
        # The exact cut/loads or failure record is durable before labels are removed.
        save(check_path, cached)
    if label.exists():
        if label.suffix != '.part': raise SystemExit('Unexpected label suffix: ' + str(label))
        label.unlink()
    cached['partition_deleted'] = True
    save(check_path, cached)
if verify_only is not None:
    print('Checked and removed temporary labels:', verify_only, flush=True)
    raise SystemExit(0)

published = Path(meta['results'])
published.mkdir(parents=True, exist_ok=True)

def write(name, rows, columns):
    target = published / name
    temporary = target.with_suffix('.csv.tmp')
    with temporary.open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader(); writer.writerows(rows)
    temporary.replace(target)

rows, groups = [], {}
for run in runs:
    check = json.loads((out / 'checks' / (run['id'] + '.json')).read_text())
    exact = check.get('exact') or {}
    binary = 'ours_' + graphs[run['graph']]['variant'] if run['method'] in ['ours', 'legacy'] else run['method']
    row = dict(category=run['category'], graph=run['graph'], k=run['k'], repeat=run['repeat'] + 1,
               method=run['method'], status=check['status'], seconds=run.get('seconds'),
               reported_cut=run.get('reported_cut'), cut=exact.get('cut'), cut_fraction=exact.get('cut_ratio'),
               max_load_ratio=exact.get('max_load_ratio'), capacity=exact.get('capacity'),
               capacity_ok=exact.get('capacity_ok'), gpu_uuid=run['gpu_uuid'],
               binary_sha256=meta['binaries'][binary]['sha256'],
               coarsen_mode=run.get('coarsen_mode'))
    stage = run.get('stage') or {}
    for field in ['coarsen_seconds', 'initial_partition_seconds', 'uncoarsen_seconds']:
        row[field] = stage.get(field) if run['method'] != 'jet' else None
    durations = [row[field] for field in ['coarsen_seconds', 'initial_partition_seconds', 'uncoarsen_seconds']]
    row['cleanup_and_boundary_seconds'] = (run['seconds'] - sum(durations)
        if run.get('seconds') is not None and all(x is not None for x in durations) else None)
    rows.append(row)
    groups.setdefault((run['graph'], run['k'], run['method']), []).append(row)
write('runs.csv', rows, ['category', 'graph', 'k', 'repeat', 'method', 'status', 'seconds',
                       'reported_cut', 'cut', 'cut_fraction', 'max_load_ratio', 'capacity',
                       'capacity_ok', 'gpu_uuid', 'binary_sha256', 'coarsen_mode', 'coarsen_seconds',
                       'initial_partition_seconds', 'uncoarsen_seconds', 'cleanup_and_boundary_seconds'])

columns = ['category', 'graph', 'k', 'status']
for method in meta['methods']:
    columns += [method + '_' + field for field in ['valid_repeats', 'seconds', 'cut', 'cut_fraction']]
columns += ['speedup_over_jet', 'time_reduction_vs_jet_percent', 'cut_ratio_over_jet',
            'cut_change_vs_jet_percent', 'speedup_over_reference', 'cut_ratio_over_reference', 'speedup_over_legacy',
            'time_reduction_vs_legacy_percent', 'cut_ratio_over_legacy', 'target_status']
comparison = []
for name, graph in graphs.items():
    for k in meta['parts']:
        row = dict(category=graph['category'], graph=name, k=k, status='complete')
        for method in meta['methods']:
            measured = groups.get((name, k, method), [])
            valid = [r for r in measured if r['status'] == 'verified']
            row[method + '_valid_repeats'] = len(valid)
            if len(measured) != meta['repeats'] or len(valid) != meta['repeats']:
                row['status'] = 'incomplete_or_invalid'
                continue
            for field in ['seconds', 'cut', 'cut_fraction']:
                row[method + '_' + field] = statistics.median(r[field] for r in valid)
        if row['status'] == 'complete':
            if 'jet' in meta['methods']:
                speed = row['jet_seconds'] / row['ours_seconds']
                cut, jet_cut = row['ours_cut'], row['jet_cut']
                ratio = cut / jet_cut if jet_cut else (1.0 if cut == 0 else None)
                row.update(speedup_over_jet=speed, time_reduction_vs_jet_percent=100 * (1 - 1 / speed),
                           cut_ratio_over_jet=ratio, cut_change_vs_jet_percent=100 * (ratio - 1) if ratio is not None else None,
                           target_status='below_1.15' if speed < 1.15 else 'below_1.2' if speed < 1.2 else 'at_least_1.2')
            if 'legacy' in meta['methods']:
                speed = row['legacy_seconds'] / row['ours_seconds']
                cut, old_cut = row['ours_cut'], row['legacy_cut']
                row.update(speedup_over_legacy=speed, time_reduction_vs_legacy_percent=100 * (1 - 1 / speed),
                           cut_ratio_over_legacy=cut / old_cut if old_cut else (1.0 if cut == 0 else None))
            if 'reference' in meta['methods']:
                row['speedup_over_reference'] = row['reference_seconds'] / row['ours_seconds']
                cut, ref_cut = row['ours_cut'], row['reference_cut']
                row['cut_ratio_over_reference'] = cut / ref_cut if ref_cut else (1.0 if cut == 0 else None)
        comparison.append(row)
write('comparison.csv', comparison, columns)

categories = []
for category in dict.fromkeys(g['category'] for g in graphs.values()):
    planned = [r for r in comparison if r['category'] == category]
    complete = [r for r in planned if r['status'] == 'complete']
    speeds = [r['speedup_over_jet'] for r in complete if r.get('speedup_over_jet') is not None]
    ratios = [r['cut_ratio_over_jet'] for r in complete if r.get('cut_ratio_over_jet') is not None]
    old_speeds = [r['speedup_over_legacy'] for r in complete if r.get('speedup_over_legacy') is not None]
    old_ratios = [r['cut_ratio_over_legacy'] for r in complete if r.get('cut_ratio_over_legacy') is not None]
    ref_speeds = [r['speedup_over_reference'] for r in complete if r.get('speedup_over_reference') is not None]
    ref_ratios = [r['cut_ratio_over_reference'] for r in complete if r.get('cut_ratio_over_reference') is not None]
    row = dict(category=category, planned_configs=len(planned), complete_configs=len(complete),
               speedup_over_jet_geomean=math.exp(statistics.mean(map(math.log, speeds))) if speeds else None,
               mean_cut_ratio_over_jet=statistics.mean(ratios) if ratios else None,
               speedup_over_legacy_geomean=math.exp(statistics.mean(map(math.log, old_speeds))) if old_speeds else None,
               mean_cut_ratio_over_legacy=statistics.mean(old_ratios) if old_ratios else None,
               speedup_over_reference_geomean=math.exp(statistics.mean(map(math.log, ref_speeds))) if ref_speeds else None,
               mean_cut_ratio_over_reference=statistics.mean(ref_ratios) if ref_ratios else None,
               mean_ours_cut_fraction=statistics.mean(r['ours_cut_fraction'] for r in complete) if complete else None,
               mean_jet_cut_fraction=statistics.mean(r['jet_cut_fraction'] for r in complete) if complete and 'jet' in meta['methods'] else None,
               below_1_15=sum(s < 1.15 for s in speeds), below_1_2=sum(s < 1.2 for s in speeds))
    categories.append(row)
write('categories.csv', categories, ['category', 'planned_configs', 'complete_configs', 'speedup_over_jet_geomean',
                                   'mean_cut_ratio_over_jet', 'speedup_over_legacy_geomean', 'mean_cut_ratio_over_legacy', 'speedup_over_reference_geomean', 'mean_cut_ratio_over_reference', 'mean_ours_cut_fraction', 'mean_jet_cut_fraction', 'below_1_15', 'below_1_2'])
bad = sum(row['status'] != 'verified' for row in rows)
print(f'Analysis complete: {len(rows)} native records; {bad} failed/invalid records retained. CSV: {published}', flush=True)
PY
