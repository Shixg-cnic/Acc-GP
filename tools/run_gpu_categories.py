#!/usr/bin/env python3
"""Resume a serial, isolated GPU dataset comparison with independent CSR checks.

No algorithm changes. Uses immutable inputs and snapshots binaries on first use.
Failed/overloaded outputs remain in the records and never count as speedups.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time
from datetime import datetime, timezone

from result_storage import discard_partition, experiment_path, publish_tables, write_run_table

PROJECT = Path(__file__).resolve().parents[1]


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def utc():
    return datetime.now(timezone.utc).isoformat()


def processes(uuid):
    output = subprocess.check_output([
        'nvidia-smi', '--query-compute-apps=gpu_uuid,pid', '--format=csv,noheader'], text=True)
    return {int(line.split(',')[1]) for line in output.splitlines()
            if line.split(',')[0].strip() == uuid}


def idle(uuid):
    stable = 0
    while stable < 3:
        stable = stable + 1 if not processes(uuid) else 0
        time.sleep(.1 if stable else 2)


def execute(command, env, log, uuid, timeout):
    for attempt in range(10):
        idle(uuid)
        # Jet appends its JSON, so remove only this invocation's prior metrics.
        if command[-1].endswith('.metrics.json'):
            metrics = Path(command[-1])
            if metrics.exists():
                metrics.rename(metrics.with_suffix(f'.previous-{time.time_ns()}.json'))
        contaminated = False
        started = time.monotonic()
        with log.open('w') as stream:
            proc = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
            timed_out = False
            while proc.poll() is None:
                contaminated |= bool(processes(uuid) - {proc.pid})
                if time.monotonic() - started > timeout:
                    proc.kill()
                    proc.wait()
                    timed_out = True
                    break
                time.sleep(.2)
        contaminated |= bool(processes(uuid))
        if contaminated:
            shutil.copy2(log, log.with_suffix(f'.overlap-{attempt}.log'))
            print(json.dumps(dict(event='discard_overlap', log=str(log))), flush=True)
            continue
        return dict(returncode=proc.returncode, timeout=timed_out,
                    process_wall_seconds=time.monotonic() - started,
                    overlap_attempts=attempt)
    raise RuntimeError('No uncontended GPU window: ' + str(log))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--names', nargs='+')
    parser.add_argument('--parts', nargs='+', type=int, default=[4, 8, 16, 32, 64, 128])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--gpu', default='1')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.repeats < 1 or any(k not in (4, 8, 16, 32, 64, 128) for k in args.parts):
        parser.error('primary performance parts must be 4/8/16/32/64/128')
    out = experiment_path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = PROJECT.parent / 'dataset_benchmark/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    selection = json.loads((PROJECT / 'tools/benchmark_selection.json').read_text())
    graphs = {g['name']: g for g in manifest['graphs']}
    names = args.names or [n for group in selection['categories'].values() for n in group]
    if len(set(names)) != len(names) or not set(names) <= graphs.keys():
        parser.error('duplicate or unknown graph name')
    excluded=set(selection.get('excluded_due_to_memory',[]))|set(selection.get('excluded_by_user',[]))
    if set(names)&excluded:
        parser.error('Excluded dataset requested: '+', '.join(sorted(set(names)&excluded)))
    names = [n for n in names if 2 * graphs[n]['undirected_edges'] < 2**31]
    device = subprocess.check_output([
        'nvidia-smi', '-i', args.gpu, '--query-gpu=uuid,name,memory.total',
        '--format=csv,noheader'], text=True).strip()
    uuid = device.split(',')[0].strip()
    sources = dict(ours=PROJECT / 'build/gpart_partition_standard',
                   jet=PROJECT.parent / 'sotas/.build-deps/jet-5090/build-jet/app/jet',
                   oracle=PROJECT / 'build/gpart_verify_csr')
    binaries = {}
    for name, source in sources.items():
        target = out / 'binaries' / name
        target.parent.mkdir(exist_ok=True)
        if not target.exists():
            shutil.copy2(source, target)
        if sha(target) != sha(source):
            raise RuntimeError('Binary identity changed: ' + name)
        binaries[name] = target
    metadata = dict(device=device, gpu_uuid=uuid, seed=0, omp_num_threads=4,
                    balance='1.03', strict_capacity='floor(103*N/(100*k))',
                    binaries={n: dict(path=str(p), sha256=sha(p)) for n, p in binaries.items()},
                    manifest_sha256=sha(manifest_path),
                    time_scope='complete native algorithm incl. final free/trim; excludes input load/upload, output download/write and oracle',
                    pipeline=dict(fine_factor=64, capacity_growth=8, small_k_legacy=True),
                    repeats_policy='per-configuration medians; geometric mean of equal-weight speed ratios',
                    selection=selection['categories'])
    identity = out / 'metadata.json'
    if identity.exists() and json.loads(identity.read_text()) != metadata:
        raise RuntimeError('Comparison identity changed')
    save(identity, metadata)
    driver = out / 'driver.py'
    if not driver.exists():
        shutil.copy2(Path(__file__), driver)
    (out / 'drivers').mkdir(exist_ok=True)
    shutil.copy2(Path(__file__), out / 'drivers' / (sha(Path(__file__)) + '.py'))
    plan = dict(started_utc=utc(), names=names, parts=args.parts, repeats=args.repeats,
                expected_runs=len(names) * len(args.parts) * args.repeats * 2,
                timeout_seconds=args.timeout, driver_sha256=sha(Path(__file__)))
    plans = json.loads((out / 'plans.json').read_text()) if (out / 'plans.json').exists() else []
    plans.append(plan)
    save(out / 'plans.json', plans)
    runs = json.loads((out / 'runs.json').read_text()) if (out / 'runs.json').exists() else []
    if args.repeats == 3 and len(args.parts) == 6 and runs and not (out / 'screen/runs.json').exists():
        screen = out / 'screen'
        screen.mkdir(exist_ok=True)
        save(screen / 'runs.json', runs)
        for filename in ['metadata.json', 'input-identities.json', 'duplicate-structures.json']:
            if (out / filename).exists():
                shutil.copy2(out / filename, screen / filename)
        # Preserve the historical screen records; no report generation.
    if args.repeats == 3 and len(args.parts) == 6:
        blocked = {}
        for name in names:
            evidence = [r for r in runs if r['graph'] == name and r['method'] == 'ours'
                        and r['repeat'] == 0 and r['k'] in (4, 32, 128)]
            if ({r['k'] for r in evidence} == {4, 32, 128}
                    and all(r['status'] == 'failed' and 'CUDA failure' in r.get('error_tail', '')
                            and 'out of memory' in r.get('error_tail', '') for r in evidence)):
                blocked[name] = dict(reason='CUDA out of memory at all three screening k; no repeat expansion',
                                     tested_parts=[4, 32, 128],
                                     untested_parts=[8, 16, 64],
                                     logs=[r['log'] for r in evidence])
        save(out / 'memory-blocked.json', blocked)
        names = [name for name in names if name not in blocked]
        plan.update(requested_expected_runs=plan['expected_runs'],
                    attempted_names=names, memory_blocked_names=list(blocked),
                    expected_runs=len(names) * len(args.parts) * args.repeats * 2
                    + sum(r['graph'] in blocked for r in runs))
        plans[-1] = plan
        save(out / 'plans.json', plans)
    # Optional conservative remeasurement after documented diagnostic activity.
    redo_file = out / 'remeasure-graphs.json'
    if redo_file.exists() and not (out / 'remeasure-applied.json').exists():
        redo = json.loads(redo_file.read_text())
        archived = [r for r in runs if r['graph'] in redo['names']]
        archive = out / 'superseded-screen'
        archive.mkdir(exist_ok=True)
        save(archive / 'runs.json', archived)
        for name in redo['names']:
            if (out / name).exists():
                shutil.copytree(out / name, archive / name, dirs_exist_ok=True)
        runs = [r for r in runs if r['graph'] not in redo['names']]
        save(out / 'runs.json', runs)
        save(out / 'remeasure-applied.json', dict(**redo, applied_utc=utc(), archived_runs=len(archived)))
    by_key = {(r['graph'], r['k'], r['repeat'], r['method']): r for r in runs}
    environment = {k: v for k, v in os.environ.items() if not k.startswith('GPART_')}
    environment.update(CUDA_VISIBLE_DEVICES=uuid, OMP_NUM_THREADS='4',
                       GPART_FINE_FACTOR='64', GPART_CAPACITY_GROWTH='8')
    warmups = json.loads((out / 'warmups.json').read_text()) if (out / 'warmups.json').exists() else {}

    def command(method, graph, k, partition):
        folder = PROJECT.parent / 'dataset_benchmark' / graph['folder']
        if method == 'ours':
            binary = binaries['ours']
            return [str(binary), str(folder / (graph['name'] + '_indptr.bin')),
                    str(folder / (graph['name'] + '_indices.bin')),
                    str(k), str(partition), '1.03', '0']
        nominal = (graph['vertices'] + k - 1) // k
        capacity = 103 * graph['vertices'] // (100 * k)
        alpha = '1.03' if int(1.03 * nominal) == capacity else repr((capacity + .5) / nominal)
        config = partition.with_suffix('.config')
        config.write_text(f'0\n{k}\n1\n{alpha}\n0\n')
        return [str(binaries['jet']), str(folder / (graph['name'] + '.metis')),
                str(config), str(partition), str(partition.with_suffix('.metrics.json'))]

    def state(event):
        save(out / 'state.json', dict(event=event, updated_utc=utc(), plan=plan,
                                     completed=len(runs), verified=sum(r.get('verified', False) for r in runs),
                                     failures=sum(r['status'] != 'ok' for r in runs)))

    def verify(row):
        if row.get('oracle_done') or row['status'] != 'ok':
            discard_partition(row)
            save(out / 'runs.json', runs)
            return
        graph = graphs[row['graph']]
        folder = PROJECT.parent / 'dataset_benchmark' / graph['folder']
        cmd = [str(binaries['oracle']), str(folder / (graph['name'] + '_indptr.bin')),
               str(folder / (graph['name'] + '_indices.bin')), str(row['k']), row['partition'],
               'binary' if row['method'] == 'ours' else 'text']
        result = subprocess.run(cmd, env=environment, capture_output=True, text=True, timeout=args.timeout)
        try:
            exact = json.loads(result.stdout)
        except ValueError:
            exact = dict(error=result.stderr, stdout=result.stdout)
        row.update(oracle_done=True, oracle_returncode=result.returncode, exact=exact)
        row['verified'] = (result.returncode == 0 and exact.get('cut') == row['reported_cut']
                           and exact.get('capacity_ok') is True)
        if not row['verified']:
            row['status'] = 'invalid_output'
        save(out / 'runs.json', runs)
        discard_partition(row)
        save(out / 'runs.json', runs)

    state('running')
    for name in names:
        graph = graphs[name]
        folder = out / name
        folder.mkdir(exist_ok=True)
        for method in ['ours', 'jet']:
            key = name + ':' + method
            if key not in warmups:
                log = folder / (method + '-warmup.log')
                result = execute(command(method, graph, 4, folder / (method + '-warmup.part')),
                                 environment, log, uuid, args.timeout)
                warmups[key] = dict(**result, log=str(log))
                save(out / 'warmups.json', warmups)
                discard_partition({'partition':str(folder / (method + '-warmup.part'))})
        for k in args.parts:
            for repeat in range(args.repeats):
                order = ['ours', 'jet'] if repeat % 2 == 0 else ['jet', 'ours']
                for method in order:
                    key = (name, k, repeat, method)
                    if key in by_key:
                        continue
                    stem = folder / f'{method}-k{k}-r{repeat}'
                    partition, log = stem.with_suffix('.part'), stem.with_suffix('.log')
                    cmd = command(method, graph, k, partition)
                    row = dict(graph=name, category=graph['category'], k=k, repeat=repeat,
                               method=method, started_utc=utc(), command=cmd, partition=str(partition),
                               log=str(log), verified=False)
                    result = execute(cmd, environment, log, uuid, args.timeout)
                    row.update(result, finished_utc=utc())
                    text = log.read_text(errors='replace')
                    row['status'] = ('timeout' if result['timeout'] else
                                     ('failed' if result['returncode'] else 'ok'))
                    if row['status'] == 'ok':
                        try:
                            if method == 'jet':
                                metrics = json.loads(partition.with_suffix('.metrics.json').read_text())
                                assert len(metrics) == 1
                                metrics = metrics[0]
                                row.update(reported_cut=int(metrics['edge-cut']),
                                           seconds=metrics['total-duration-seconds'],
                                           stage=metrics)
                            else:
                                timing = re.findall(r'^partition_timing (.*)$', text, re.M)[-1]
                                stage = {n: float(v) for n, v in re.findall(r'(\w+_seconds)=([0-9.e+-]+)', timing)}
                                row.update(reported_cut=int(re.findall(r'^final_edge_cut=(\d+)$', text, re.M)[-1]),
                                           seconds=stage['algorithm_total_seconds'], stage=stage)
                            assert row['seconds'] > 0
                        except (AssertionError, ValueError, KeyError, IndexError, OSError) as error:
                            row.update(status='parse_failed', error=str(error))
                    else:
                        row['error_tail'] = text[-3000:]
                    runs.append(row)
                    by_key[key] = row
                    save(out / 'runs.json', runs)
                    state(name + f':k{k}:r{repeat}:' + method)
                    print(json.dumps({n: row.get(n) for n in ['graph', 'k', 'repeat', 'method', 'status', 'seconds', 'reported_cut']}), flush=True)
        # CPU checks run only between graphs, outside all native timings.
        for row in runs:
            if row['graph'] == name:
                verify(row)
        write_run_table(out / 'runs.csv', runs)
        publish_tables(out)
        state('verified:' + name)
    state('complete')
    print('COMPLETE: ' + str(out), flush=True)


if __name__ == '__main__':
    main()
