#!/usr/bin/env python3
"""Alternate complete GPU partitioning runs with Jet at identical integer caps.

Graphs are uploaded by each driver before its algorithm timer starts. Validation
against the original CSR runs separately, after every timed process has exited.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
from decimal import Decimal
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

from verify_partition import verify
from result_storage import discard_partition, experiment_path, publish_tables, write_run_table


def gpu_info(selection):
    output = subprocess.check_output(
        ['nvidia-smi', '-i', selection, '--query-gpu=index,uuid,name,memory.total',
         '--format=csv,noheader,nounits'], text=True)
    rows = [line.split(',') for line in output.strip().splitlines()]
    if len(rows) != 1:
        raise ValueError('select exactly one GPU')
    index, uuid, name, memory = [value.strip() for value in rows[0]]
    return dict(index=index, uuid=uuid, name=name, memory_mib=int(memory))


def require_idle_gpu(uuid):
    output = subprocess.check_output(
        ['nvidia-smi', '--query-compute-apps=gpu_uuid,pid', '--format=csv,noheader'], text=True)
    occupied = [line for line in output.splitlines() if line.split(',')[0].strip() == uuid]
    if occupied:
        raise RuntimeError(f'GPU {uuid} has another compute process; timed comparison stopped')


def wait_idle_gpu(uuid, wait):
    announced = False
    while True:
        try:
            require_idle_gpu(uuid)
            if announced:
                print('Selected GPU is idle; resuming timed comparison.', flush=True)
            return
        except RuntimeError:
            if not wait:
                raise
            if not announced:
                print('Waiting for other compute processes on the selected GPU.', flush=True)
                announced = True
            time.sleep(10)


def check(run):
    fmt = 'text' if run['method'] == 'jet' else 'binary'
    if run.get('oracle'):
        command = [run['oracle'], run['indptr'], run['indices'], str(run['parts']),
                   run['partition'], fmt]
        output = subprocess.check_output(command, text=True,
                                        env=dict(os.environ, OMP_NUM_THREADS='4'))
        result = json.loads(output)
    else:
        result = verify(Path(run['indptr']), Path(run['indices']), Path(run['partition']),
                        run['parts'], '1.03', fmt)
    if result['cut'] != run['cut'] or not result['capacity_ok']:
        raise AssertionError((run, result))
    return dict(method=run['method'], parts=run['parts'], repeat=run['repeat'], **result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--indptr', type=Path, required=True)
    parser.add_argument('--indices', type=Path, required=True)
    parser.add_argument('--jet-graph', type=Path, required=True)
    parser.add_argument('--jet', type=Path, required=True)
    parser.add_argument('--ours', type=Path, default=Path('build/gpart_partition_standard'))
    parser.add_argument('--reference', type=Path,
                        help='optional saved production binary, timed under identical conditions')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--parts', nargs='+', type=int, default=[4, 8])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--gpu', default='0')
    parser.add_argument('--wait-idle', action='store_true',
                        help='wait for an idle GPU before starting each timed process')
    parser.add_argument('--oracle', type=Path,
                        help='optional independent CPU CSR oracle (gpart_verify_csr)')
    args = parser.parse_args()
    if args.repeats < 1 or any(k < 2 or k > 128 for k in args.parts):
        parser.error('repeats must be positive and 2 <= k <= 128')
    args.output = experiment_path(args.output)
    args.output.mkdir(parents=True, exist_ok=True)
    n = args.indptr.stat().st_size // 8 - 1
    edges = args.indices.stat().st_size // 8
    with args.jet_graph.open() as graph:
        header = next(line for line in graph if line.strip() and not line.lstrip().startswith('%'))
    dimensions = header.split()
    if len(dimensions) < 2 or not all(value.isdigit() for value in dimensions[:2]):
        raise ValueError('Jet input is not a METIS graph (possibly a Git LFS pointer)')
    if (int(dimensions[0]), int(dimensions[1])*2) != (n, edges):
        raise ValueError('Jet and CSR input dimensions differ')
    device = gpu_info(args.gpu)
    wait_idle_gpu(device['uuid'], args.wait_idle)
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=args.gpu, OMP_NUM_THREADS='8', OMP_PROC_BIND='false')
    binaries = {'ours': args.ours.resolve(), 'jet': args.jet.resolve()}
    if args.reference:
        binaries['reference']=args.reference.resolve()
    metadata = dict(vertices=n, edge_entries=edges, seed=0, balance='1.03', gpu=args.gpu,
                    device=device, started_utc=datetime.now(timezone.utc).isoformat(),
                    binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                              for name, path in binaries.items()})
    if args.oracle:
        metadata['verification_oracle'] = dict(path=str(args.oracle.resolve()),
            sha256=hashlib.sha256(args.oracle.read_bytes()).hexdigest())
    (args.output/'metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
    runs = []
    for k in args.parts:
        capacity = int(Decimal('1.03') * n / k)
        nominal_jet_cap = int(Decimal('1.03') * ((n+k-1)//k))
        alpha = '1.03' if nominal_jet_cap == capacity else repr((capacity+0.5)/((n+k-1)//k))
        config = args.output/f'jet-k{k}.config'
        config.write_text(f'0\n{k}\n1\n{alpha}\n0\n')
        for repeat in range(args.repeats):
            # Rotate the first method to reduce ordering bias.
            methods = list(binaries)
            shift=repeat%len(methods)
            methods=methods[shift:]+methods[:shift]
            for method in methods:
                wait_idle_gpu(device['uuid'], args.wait_idle)
                started = datetime.now(timezone.utc).isoformat()
                name = f'{method}-k{k}-r{repeat}'
                part, log = args.output/f'{name}.part', args.output/f'{name}.log'
                metrics = args.output/f'{name}.metrics.json'
                if method == 'jet':
                    # Jet appends metrics. Preserve a previous invocation so
                    # reusing an output directory still produces one JSON run.
                    if metrics.exists():
                        metrics.rename(metrics.with_name(
                            f'{name}.previous-{time.time_ns()}.metrics.json'))
                    command = [str(binaries[method]), str(args.jet_graph.resolve()), str(config.resolve()),
                               str(part.resolve()), str(metrics.resolve())]
                else:
                    command = [str(binaries[method]), str(args.indptr.resolve()), str(args.indices.resolve()),
                               str(k), str(part.resolve()), '1.03', '0']
                with log.open('w') as stream:
                    subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
                require_idle_gpu(device['uuid'])
                if method == 'jet':
                    data = json.loads(metrics.read_text())
                    if len(data) != 1:
                        raise AssertionError('Jet must use one attempt')
                    timing, cut = data[0]['total-duration-seconds'], data[0]['edge-cut']
                    stage = data[0]
                else:
                    output = log.read_text()
                    timing = float(re.findall(r'algorithm_total_seconds=([0-9.e+-]+)', output)[-1])
                    cut = int(re.findall(r'^final_edge_cut=(\d+)$', output, re.M)[-1])
                    stage = {a: float(b) for a, b in re.findall(r'(\w+_seconds)=([0-9.e+-]+)',
                              next(x for x in output.splitlines() if x.startswith('partition_timing ')))}
                run = dict(method=method, parts=k, repeat=repeat, cut=cut, seconds=timing,
                           started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat(),
                           integer_capacity=capacity, configured_jet_alpha=alpha, stage=stage,
                           indptr=str(args.indptr.resolve()), indices=str(args.indices.resolve()),
                           partition=str(part.resolve()), log=str(log.resolve()), command=command,
                           oracle=str(args.oracle.resolve()) if args.oracle else None,
                           sha256=hashlib.sha256(part.read_bytes()).hexdigest())
                runs.append(run)
                (args.output/'runs.json').write_text(json.dumps(runs, indent=2)+'\n')
                print(json.dumps(dict(method=method, parts=k, repeat=repeat, cut=cut, seconds=timing)), flush=True)
    print('Timed runs complete; independently verifying cut and capacity.', flush=True)
    # Identical binary outputs need only one CSR scan; retain verification for
    # every run and preserve its method/repeat metadata.
    identity = lambda run: (run['sha256'], run['parts'], run['method'] == 'jet')
    unique = {identity(run): run for run in runs}
    with ProcessPoolExecutor(max_workers=min(6, len(unique))) as pool:
        checked = dict(zip(unique, pool.map(check, unique.values())))
    verified = [dict(checked[identity(run)], method=run['method'], repeat=run['repeat']) for run in runs]
    (args.output/'verified.json').write_text(json.dumps(verified, indent=2)+'\n')
    for run, exact in zip(runs, verified):
        run.update(verified=True, exact=exact)
    (args.output/'runs.json').write_text(json.dumps(runs, indent=2)+'\n')
    for run in runs:
        discard_partition(run)
    (args.output/'runs.json').write_text(json.dumps(runs, indent=2)+'\n')
    write_run_table(args.output/'runs.csv',runs)
    publish_tables(args.output)
    summary = []
    for k in args.parts:
        row = dict(parts=k)
        for method in binaries:
            selected = [r for r in runs if r['parts'] == k and r['method'] == method]
            row[method] = dict(cut=statistics.median(r['cut'] for r in selected),
                               seconds=statistics.median(r['seconds'] for r in selected),
                               cut_range=[min(r['cut'] for r in selected), max(r['cut'] for r in selected)],
                               time_range=[min(r['seconds'] for r in selected), max(r['seconds'] for r in selected)])
        row['cut_increase_percent'] = (row['ours']['cut']/row['jet']['cut']-1)*100
        row['speedup_over_jet'] = row['jet']['seconds']/row['ours']['seconds']
        if args.reference:
            row['cut_change_vs_reference_percent']=(row['ours']['cut']/row['reference']['cut']-1)*100
            row['time_change_vs_reference_percent']=(row['ours']['seconds']/row['reference']['seconds']-1)*100
        summary.append(row)
    (args.output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
