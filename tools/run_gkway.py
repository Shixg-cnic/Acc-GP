#!/usr/bin/env python3
"""Screen the selected graphs with the paper-threshold G-kway executable."""
import argparse
from collections import Counter
from contextlib import ExitStack
import csv
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
FROZEN = ROOT / 'Acc-GP-archive/experiments/gkway-paper-threshold-20261018'
PARTS = (2, 4, 8, 16, 32, 64)
COLUMNS = ('category', 'graph', 'k', 'status', 'seconds', 'cut', 'cut_ratio',
           'capacity_ok', 'max_load_ratio', 'reported_cut_matches',
           'coarsest_vertices', 'coarsen_seconds', 'initial_partition_seconds',
           'uncoarsen_seconds', 'returncode', 'error')


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def save(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    tmp.replace(path)


def write_csv(path, rows, fields):
    tmp = path.with_suffix('.tmp')
    with tmp.open('w', encoding='utf-8-sig', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)
    tmp.replace(path)


def parse_output(text):
    timing = dict((key, float(value)) for key, value in re.findall(
        r'(native_seconds|cleanup_seconds|algorithm_seconds)=([0-9.eE+-]+)', text))
    seconds = timing['algorithm_seconds']
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('Missing or invalid native algorithm time')
    result = dict(seconds=seconds, native_seconds=timing['native_seconds'],
                  cleanup_seconds=timing['cleanup_seconds'],
                  reported_cut=int(re.findall(r'\*+ h_cutsize (\d+)', text)[-1]),
                  coarsest_vertices=int(re.findall(
                      r'start init partition, num_vertices: (\d+)', text)[-1]))
    for field, tag in [('coarsen_seconds', 'Coarsen'),
                       ('initial_partition_seconds', 'Init partition'),
                       ('uncoarsen_seconds', 'Refinement')]:
        result[field] = float(re.findall('^' + tag + r' time: ([0-9.eE+-]+)s', text, re.M)[-1])
    return result


def gpu_processes(uuid):
    text = subprocess.check_output(['nvidia-smi', '--query-compute-apps=gpu_uuid,pid',
                                    '--format=csv,noheader'], text=True)
    return {int(line.split(',')[1]) for line in text.splitlines() if line.startswith(uuid)}


def wait_idle(uuid):
    stable = 0
    last = 0
    while stable < 3:
        busy = gpu_processes(uuid)
        stable = 0 if busy else stable + 1
        if busy and time.monotonic() - last > 30:
            print(f'等待 GPU 空闲：{sorted(busy)}', flush=True)
            last = time.monotonic()
        time.sleep(1 if busy else .2)


def measure(command, log, work, env, uuid, timeout):
    wait_idle(uuid)
    start = time.monotonic()
    overlap = False
    expired = False
    with log.open('w') as f:
        proc = subprocess.Popen(command, cwd=work, env=env, stdout=f, stderr=subprocess.STDOUT)
        try:
            while proc.poll() is None:
                overlap |= bool(gpu_processes(uuid) - {proc.pid})
                if time.monotonic() - start > timeout:
                    proc.kill()
                    expired = True
                    break
                time.sleep(.3)
            proc.wait()
            overlap |= bool(gpu_processes(uuid))
        except BaseException:
            proc.kill()
            proc.wait()
            raise
    return proc.returncode, expired, overlap


def publish(public, graphs, latest):
    rows = [latest.get((g['name'], k), dict(category=g['category'], graph=g['name'],
                                          k=k, status='pending'))
            for g in graphs for k in PARTS]
    write_csv(public / 'results.csv', rows, COLUMNS)
    failed = [r for r in rows if r['status'] not in ('ok', 'overloaded', 'pending')]
    write_csv(public / 'failed.csv', failed, COLUMNS)
    categories = []
    for category in dict.fromkeys(g['category'] for g in graphs):
        selected = [r for r in rows if r['category'] == category]
        counts = Counter(r['status'] for r in selected)
        categories.append(dict(category=category, configurations=len(selected),
                               available=counts['ok'] + counts['overloaded'],
                               overloaded=counts['overloaded'], pending=counts['pending'],
                               failed=len(selected)-counts['ok']-counts['overloaded']-counts['pending']))
    write_csv(public / 'categories.csv', categories, list(categories[0]))


def run_main(stack):
    parser = argparse.ArgumentParser(description='G-kway论文阈值：当前选集 × k=2/4/8/16/32/64；每配置一次，超载保留。')
    parser.add_argument('--output', type=Path, default=PROJECT / 'results/gkway-paper')
    parser.add_argument('--gpu', default='0', help='GPU index or UUID; wait for an idle window')
    parser.add_argument('--graphs', nargs='+', help='Default: all graphs in benchmark_selection.json')
    parser.add_argument('--timeout', type=float, default=600, help='Timeout per process, seconds')
    parser.add_argument('--retry-failed', action='store_true', help='Retry failed configurations once; keep attempt history')
    parser.add_argument('--dry-run', action='store_true', help='Validate inputs and binaries without running GPU jobs')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    selection_path = PROJECT / 'tools/benchmark_selection.json'
    selection = json.loads(selection_path.read_text())
    selected = [name for names in selection['categories'].values() for name in names]
    names = args.graphs or selected
    if len(set(names)) != len(names) or not set(names) <= set(selected):
        parser.error('--graphs must contain unique names from the current selection')
    manifest_path = ROOT / 'dataset_benchmark/manifest.json'
    manifest = {g['name']: g for g in json.loads(manifest_path.read_text())['graphs']}
    graphs = [manifest[name] for name in names]
    inputs = {}
    for g in graphs:
        folder = ROOT / 'dataset_benchmark' / g['folder']
        paths = [folder / (g['name'] + suffix) for suffix in ('.metis', '_indptr.bin', '_indices.bin')]
        inputs[g['name']] = [dict(path=str(p), size=p.stat().st_size, mtime_ns=p.stat().st_mtime_ns) for p in paths]
    frozen = FROZEN.resolve()
    binary = frozen / 'binaries/gkway'
    oracle = frozen / 'binaries/oracle'
    previous = json.loads((frozen / 'metadata.json').read_text())
    # Do not silently use the old executable installed under .build-deps.
    assert sha(binary) == previous['binaries']['gkway'], 'Frozen paper-threshold binary changed'
    assert sha(oracle) == previous['binaries']['oracle'], 'Frozen verifier changed'
    uuid = subprocess.check_output(['nvidia-smi', '-i', args.gpu, '--query-gpu=uuid',
                                    '--format=csv,noheader'], text=True).strip()
    if not uuid.startswith('GPU-') or '\n' in uuid:
        parser.error('Select exactly one GPU')
    public = args.output.resolve()
    relative = public.relative_to(PROJECT / 'results')
    work = ROOT / 'Acc-GP-archive/experiments' / relative
    identity = dict(graphs=names, parts=PARTS, gpu_uuid=uuid, timeout=args.timeout,
                    threshold='original_N/(20*log2(k))', binary_sha256=sha(binary),
                    oracle_sha256=sha(oracle), driver_sha256=sha(Path(__file__)),
                    selection_sha256=sha(selection_path), manifest_sha256=sha(manifest_path),
                    inputs=inputs, omp_num_threads=4, metis_options='upstream defaults',
                    timing=previous['timing'], timing_limit=previous['gkway_timing_limit'],
                    source_archive=str(frozen), sampling='one formal run per configuration; per-graph warmup')
    # JSON normalizes tuples before comparison on resume.
    identity = json.loads(json.dumps(identity))
    print(f'{len(graphs)} 图 × {len(PARTS)} k = {len(graphs)*len(PARTS)} 配置；GPU {uuid}', flush=True)
    if args.dry_run:
        print('输入、冻结程序及核验器已检查；未启动实验。')
        return 0
    public.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    for folder in ('logs', 'checks', 'labels', 'binaries'):
        (work / folder).mkdir(exist_ok=True)
    lock = stack.enter_context((work / 'runner.lock').open('w'))
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    gpu_lock = stack.enter_context((ROOT / 'Acc-GP-archive' / (uuid + '.lock')).open('w'))
    fcntl.flock(gpu_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    metadata = work / 'metadata.json'
    if metadata.exists():
        assert json.loads(metadata.read_text()) == identity, 'Resume identity differs; use a new output directory'
    else:
        save(metadata, identity)
    for src in (binary, oracle):
        target = work / 'binaries' / src.name
        if not target.exists():
            shutil.copy2(src, target)
        assert sha(src) == sha(target)
    binary, oracle = work / 'binaries/gkway', work / 'binaries/oracle'
    attempts_file = work / 'attempts.json'
    attempts = json.loads(attempts_file.read_text()) if attempts_file.exists() else []
    latest = {(r['graph'], r['k']): r for r in attempts if not r.get('warmup')}
    publish(public, graphs, latest)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('GPART_', 'SCLP_'))}
    env.update(CUDA_VISIBLE_DEVICES=uuid, OMP_NUM_THREADS='4', TMPDIR=str(ROOT / 'Acc-GP-archive/build-tmp'))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    def run(g, k, warmup=False):
        attempt = sum(r['graph'] == g['name'] and r['k'] == k and
                      bool(r.get('warmup')) == warmup for r in attempts) + 1
        stem = f'{g["name"]}-k{k}-a{attempt}' + ('-warmup' if warmup else '')
        label = work / 'labels' / (stem + '.out')
        log = work / 'logs' / (stem + '.log')
        command = [str(binary), inputs[g['name']][0]['path'], str(k), 'labels/' + stem]
        row = dict(category=g['category'], graph=g['name'], k=k, attempt=attempt,
                   warmup=warmup, command=command, log=str(log),
                   started_utc=datetime.now(timezone.utc).isoformat())
        try:
            code, expired, overlap = measure(command, log, work, env, uuid, args.timeout)
            row['returncode'] = code
            text = log.read_text(errors='replace')
            if expired:
                row.update(status='timeout', error=f'Exceeded {args.timeout:g}s')
            elif code:
                oom = bool(re.search(r'out of memory|cudaErrorMemoryAllocation|bad_alloc', text, re.I))
                row.update(status='out_of_memory' if oom else 'runtime_error', error=text[-2000:])
            elif overlap:
                row.update(status='overlap_discarded', error='Other GPU compute process overlapped; not a timing sample')
            else:
                parsed = parse_output(text)
                check = subprocess.run([str(oracle), inputs[g['name']][1]['path'],
                                        inputs[g['name']][2]['path'], str(k), str(label), 'text'],
                                       env=env, capture_output=True, text=True, timeout=args.timeout)
                save(work / 'checks' / (stem + '.json'), dict(returncode=check.returncode,
                                                           stdout=check.stdout, stderr=check.stderr))
                exact = json.loads(check.stdout)
                if check.returncode not in (0, 1) or len(exact['loads']) != k or sum(exact['loads']) != g['vertices']:
                    raise ValueError('Independent label verification failed')
                row.update(parsed, cut=exact['cut'], cut_ratio=exact['cut_ratio'],
                           capacity_ok=exact['capacity_ok'], max_load_ratio=exact['max_load_ratio'],
                           reported_cut_matches=parsed['reported_cut'] == exact['cut'], exact=exact,
                           status='ok' if exact['capacity_ok'] else 'overloaded')
        except (ValueError, KeyError, IndexError, subprocess.TimeoutExpired) as exc:
            row.update(status='verification_failed', error=str(exc))
        except BaseException:
            row.update(status='interrupted', error='Run interrupted; resume will retry')
            raise
        finally:
            # Persist a status/check before removing labels, including interrupted runs.
            attempts.append(row)
            save(attempts_file, attempts)
            label.unlink(missing_ok=True)
            row['partition_deleted'] = True
            save(attempts_file, attempts)
            if not warmup:
                latest[g['name'], k] = row
                publish(public, graphs, latest)
        print(f'{g["name"]} k={k} {"warmup " if warmup else ""}{row["status"]}'
              f' time={row.get("seconds", "-")} cut={row.get("cut", "-")}', flush=True)
        return row

    for g in graphs:
        pending = [k for k in PARTS if (g['name'], k) not in latest or
                   latest[g['name'], k]['status'] in ('interrupted', 'overlap_discarded') or
                   (args.retry_failed and latest[g['name'], k]['status'] not in ('ok', 'overloaded'))]
        if not pending:
            continue
        memory_blocked = any(r['graph'] == g['name'] and r['status'] == 'out_of_memory' for r in attempts)
        if not memory_blocked or args.retry_failed:
            warm = run(g, pending[0], True)
            memory_blocked = warm['status'] == 'out_of_memory'
        for k in pending:
            if memory_blocked:
                row = dict(category=g['category'], graph=g['name'], k=k,
                           status='skipped_after_oom', error='Dataset excluded after an out-of-memory failure')
                attempts.append(row)
                save(attempts_file, attempts)
                latest[g['name'], k] = row
                publish(public, graphs, latest)
                continue
            row = run(g, k)
            # Keep every discarded attempt, then wait for a clean GPU window.
            for _ in range(2):
                if row['status'] != 'overlap_discarded':
                    break
                row = run(g, k)
            memory_blocked = row['status'] == 'out_of_memory'
    counts = Counter(r['status'] for r in latest.values())
    save(work / 'completion.json', dict(status='complete', counts=dict(counts),
                                      configurations=len(latest), public=str(public)))
    print('完成：' + json.dumps(dict(counts), ensure_ascii=False), flush=True)
    print(f'结果：{public / "results.csv"}\n失败：{public / "failed.csv"}', flush=True)
    return 1 if any(r['status'] not in ('ok', 'overloaded') for r in latest.values()) else 0


def main():
    with ExitStack() as stack:
        return run_main(stack)


if __name__ == '__main__':
    raise SystemExit(main())
