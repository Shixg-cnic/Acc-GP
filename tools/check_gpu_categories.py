#!/usr/bin/env python3
"""Check experiment coverage and traceability, without rerunning partitioning."""
from result_storage import artifact_path, experiment_path, publish_tables
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
p.add_argument('--parts', nargs='+', type=int, default=[4, 8, 16, 32, 64, 128])
p.add_argument('--repeats', type=int, default=3)
a = p.parse_args()
root = experiment_path(a.output)
meta = json.loads((root / 'metadata.json').read_text())
runs = json.loads((root / 'runs.json').read_text())
inputs = {r['name']: r for r in json.loads((root / 'input-identities.json').read_text())}
names = [n for group in meta['selection'].values() for n in group]
expected = {(n, k, r, m) for n in names for k in a.parts for r in range(a.repeats)
            for m in ['ours', 'jet']}
blocked = json.loads((root / 'memory-blocked.json').read_text()) if (root / 'memory-blocked.json').exists() else {}
if blocked:
    expected = {key for key in expected if key[0] not in blocked}
    expected |= {(n, k, 0, m) for n in blocked for k in (4, 32, 128) for m in ['ours', 'jet']}
    for name in blocked:
        evidence = [r for r in runs if r['graph'] == name and r['method'] == 'ours']
        assert len(evidence) == 3 and {r['k'] for r in evidence} == {4, 32, 128}
        assert all(r['status'] == 'failed' and 'CUDA failure' in r.get('error_tail', '')
                   and 'out of memory' in r.get('error_tail', '') for r in evidence)
observed = {(r['graph'], r['k'], r['repeat'], r['method']) for r in runs}
unverified = []
errors = []
for r in runs:
    if r['status'] == 'ok':
        if not r.get('verified'):
            unverified.append([r['graph'], r['k'], r['repeat'], r['method']])
            continue
        exact = r['exact']
        n = inputs[r['graph']]['vertices']
        if (exact['cut'] != r['reported_cut'] or not exact['capacity_ok']
                or exact['capacity'] != 103 * n // (100 * r['k'])
                or r.get('oracle_returncode') != 0):
            errors.append(r['log'])
    if not Path(r['log']).is_file():
        errors.append('missing log: ' + r['log'])
hashes = {}
for name, binary in meta['binaries'].items():
    hashes[name] = hashlib.sha256(artifact_path(binary['path']).read_bytes()).hexdigest() == binary['sha256']
result = dict(runs=len(runs), expected_runs=len(expected),
              requested_full_matrix_runs=len(names) * len(a.parts) * a.repeats * 2,
              memory_blocked_graphs=list(blocked),
              complete_matrix=observed == expected and len(runs) == len(expected),
              unique_keys=len(observed) == len(runs),
              missing=sorted(expected - observed), unexpected=sorted(observed - expected),
              status_counts=dict(Counter(r['status'] for r in runs)),
              verified=sum(r.get('verified', False) for r in runs),
              unverified_successes=unverified, audit_errors=errors,
              immutable_binary_hashes_match=hashes,
              discarded_overlap_attempts=sum(r.get('overlap_attempts', 0) for r in runs))
ok = (result['complete_matrix'] and result['unique_keys'] and not unverified
      and not errors and all(hashes.values()))
result['audit_passed'] = ok
(root / 'checks.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: v for k, v in result.items() if k not in ['missing', 'unexpected']}))
raise SystemExit(0 if ok else 1)
