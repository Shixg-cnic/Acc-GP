#!/usr/bin/env python3
"""Audit a completed three-way experiment without repeating GPU/CSR runs."""
import argparse
from collections import defaultdict
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import statistics


from result_storage import artifact_path, experiment_path

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    root=experiment_path(parser.parse_args().output)
    meta=json.loads((root/'metadata.json').read_text())
    runs=json.loads((root/'runs.json').read_text())
    methods=['before','after','reference']
    expected={(g,k,r,m) for g in meta['names'] for k in meta['parts']
              for r in range(meta['repeats']) for m in methods}
    actual={(r['graph'],r['k'],r['repeat'],r['method']) for r in runs}
    assert actual==expected and len(runs)==len(expected), 'Incomplete or duplicate matrix'
    assert sha(root/'driver.py')==meta['driver_sha256']
    for m in methods:
        path=root/'candidate' if m=='after' else root/'binaries'/m
        assert sha(path)==meta['binaries'][m]
    assert sha(root/'binaries/oracle')==meta['oracle_sha256']
    if (root/'validation.json').exists():
        validation=json.loads((root/'validation.json').read_text())
        assert validation['binaries']['standard']==meta['binaries']['after']
        if 'big' in validation['binaries']: # Historical experiments only.
            assert sha(root/'binaries/after-big')==validation['binaries']['big']
    assignments=json.loads((root/'gpu-assignments.json').read_text())
    manifest_path=Path(__file__).resolve().parents[2]/'dataset_benchmark/manifest.json'
    assert sha(manifest_path)==meta['manifest_sha256']
    graphs={g['name']:g for g in json.loads(manifest_path.read_text())['graphs']}
    assert not set(meta['names'])&(set(meta['excluded_due_to_memory'])|set(meta.get('excluded_by_user',[])))
    by_trial=defaultdict(list);grouped=defaultdict(list)
    for row in runs:
        g,k,repeat,m=row['graph'],row['k'],row['repeat'],row['method']
        assert row['gpu_uuid']==assignments[g]
        assert row.get('verified') and row['exact']['capacity_ok']
        exact=row['exact'];n=graphs[g]['vertices'];capacity=103*n//(100*k)
        assert exact['vertices']==n and exact['cut']==row['reported_cut']
        assert len(exact['loads'])==k and sum(exact['loads'])==n
        assert min(exact['loads'])>=0 and max(exact['loads'])<=capacity
        assert exact['capacity']==capacity
        partition=artifact_path(row['partition'])
        assert partition.stat().st_size>0 if partition.exists() else (row.get('partition_deleted') is True and row.get('partition_bytes',0)>0)
        text=artifact_path(row['log']).read_text()
        assert 'contaminated-' not in row['log']
        if m=='before':
            metrics=json.loads(artifact_path(Path(row['partition']).with_suffix('.metrics.json')).read_text())
            assert len(metrics)==1 and int(metrics[0]['edge-cut'])==exact['cut']
            observed=metrics[0]['total-duration-seconds']
        else:
            assert int(re.findall(r'^final_edge_cut=(\d+)$',text,re.M)[-1])==exact['cut']
            stage=dict((key,float(value)) for key,value in re.findall(r'(\w+_seconds)=([0-9.e+-]+)',
                re.findall(r'^partition_timing (.*)$',text,re.M)[-1]))
            observed=stage['algorithm_total_seconds']
            for key,value in stage.items():assert row['timing'][key]==value
            assert (partition.stat().st_size if partition.exists() else row['partition_bytes'])==4*n
            if m=='after':
                assert (f"seed_matching={int(meta['hybrid_heavy_edge'])} "
                        f"heavy_edge_degree_limit={meta['heavy_edge_degree_limit']}") in text
        assert observed==row['timing']['algorithm_total_seconds'] and observed>0
        assert all(math.isfinite(v) and v>=0 for v in row['timing'].values())
        by_trial[g,k,repeat].append(m);grouped[g,k,m].append(row)
    for (g,k,repeat),order in by_trial.items():
        shift=repeat%3;assert order==methods[shift:]+methods[:shift]
    cases=list(csv.DictReader((root/'optimization-cases.csv').open()))
    assert len(cases)==len(meta['names'])*len(meta['parts'])
    for row in cases:
        g,k=row['graph'],int(row['k'])
        times={m:statistics.median(r['timing']['algorithm_total_seconds'] for r in grouped[g,k,m]) for m in methods}
        assert math.isclose(float(row['speedup_over_old']),times['reference']/times['after'],rel_tol=1e-12)
        assert math.isclose(float(row['new_speedup_over_jet']),times['before']/times['after'],rel_tol=1e-12)
        if 'cut_ratio_over_jet' in row:
            new_cut=statistics.median(r['exact']['cut'] for r in grouped[g,k,'after'])
            jet_cut=statistics.median(r['exact']['cut'] for r in grouped[g,k,'before'])
            edges=grouped[g,k,'after'][0]['exact']['undirected_edges']
            assert math.isclose(float(row['cut_ratio_over_jet']),new_cut/jet_cut,rel_tol=1e-12)
            assert math.isclose(float(row['new_cut_fraction']),new_cut/edges,rel_tol=1e-12)
            assert math.isclose(float(row['jet_cut_fraction']),jet_cut/edges,rel_tol=1e-12)
            speed=times['before']/times['after']
            assert row['target_status']==('below_minimum' if speed<1.15 else 'below_target' if speed<1.2 else 'target_met')
    geometric=lambda xs:math.exp(statistics.mean(map(math.log,xs)))
    summary=json.loads((root/'optimization-summary.json').read_text())
    total=summary['overall'];assert summary['complete'] and summary['formal']
    assert math.isclose(total['speedup_over_old'],geometric([float(r['speedup_over_old']) for r in cases]),rel_tol=1e-12)
    assert math.isclose(total['old_speedup_over_jet']*total['speedup_over_old'],total['new_speedup_over_jet'],rel_tol=1e-12)
    audit=dict(ok=True,records=len(runs),cases=len(cases),graphs=len(meta['names']),
               verified_records=len(runs),repeated_csr_oracle=False,
               coverage='all planned k/repeat/method combinations; binary/log/cut/capacity/medians/device/order audited',
               discarded_overlap_logs=len(list(root.glob('*.contaminated-*.log'))),
               binaries=meta['binaries'])
    (root/'checks.json').write_text(json.dumps(audit,indent=2)+'\n')
    print(json.dumps(audit,indent=2))


if __name__=='__main__':main()
