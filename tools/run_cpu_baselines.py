#!/usr/bin/env python3
"""Run official Mt-METIS / KaMinPar CLIs on the common verified benchmark inputs."""
import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import time

from result_storage import discard_partition, experiment_path, publish_tables, write_run_table

PROJECT = Path(__file__).resolve().parents[1]
INSTALL = PROJECT.parent / 'sotas/.build-deps/cpu-baselines/install'
METHODS = ('mtmetis', 'kaminpar')
METHOD_LABELS = {'mtmetis': 'Mt-METIS HS', 'kaminpar': 'KaMinPar'}
CATEGORY_LABELS = {
    'Web Crawl': '网页图', 'Social Network': '社交网络',
    'Semiconductor': '半导体电路', 'Road Network': '路网',
    'Optimization': '优化问题', 'Finite Element': '有限元',
    'Biology': '生物图', 'Artificial Mesh': '人工网格',
    'Artificial Complex': '人工复杂图',
}
TABLE_COLUMNS = ['图的类型', '数据集', 'k', '节点平衡比例', '切边数', '切边比例', '划分时间（秒）']
DRIVER_SOURCE = Path(__file__).read_bytes()
DRIVER_SHA256 = hashlib.sha256(DRIVER_SOURCE).hexdigest()


def read(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def save(path, value):
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def utc():
    return datetime.now(timezone.utc).isoformat()


def cpu_binding(threads):
    topology = subprocess.check_output(['lscpu', '-p=CPU,CORE,SOCKET,NODE'], text=True)
    allowed, cores = os.sched_getaffinity(0), {}
    for line in topology.splitlines():
        if line.startswith('#'):
            continue
        cpu, core, socket, node = map(int, line.split(','))
        if cpu in allowed:
            cores.setdefault((socket, core), (cpu, node))
    selected = sorted(cores.values())[:threads]
    if len(selected) != threads:
        raise ValueError('Requested more threads than available physical cores')
    cpus = ','.join(str(cpu) for cpu, _ in selected)
    nodes = ','.join(str(node) for node in sorted({node for _, node in selected if node >= 0}))
    command = ['numactl', '--physcpubind=' + cpus, '--interleave=' + nodes]
    subprocess.run(command + ['/bin/true'], check=True, capture_output=True)
    return command, [cpu for cpu, _ in selected], nodes


def metrics(method, text):
    if method == 'mtmetis':
        seconds = float(re.search(r'^Total Time:\s*([0-9.eE+-]+)s', text, re.M)[1])
        cut = int(re.search(r'^Best Objective:\s*(\d+)', text, re.M)[1])
    else:
        cut = int(re.search(r'^RESULT cut=(\d+)', text, re.M)[1])
        line = re.search(r'^TIME (.*)$', text, re.M)[1]
        seconds = float(re.search(r'(?:^| )partitioning=([0-9.eE+-]+)', line)[1])
    if seconds < 0 or cut < 0:
        raise ValueError('Invalid native metrics')
    return seconds, cut


def invoke(command, log, timeout, env):
    with log.open('w') as output:
        proc = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            return 'timeout'


def export_tables(output, targets, runs, parts, repeats, summaries):
    """Keep exactly seven columns; method and repetition belong in filenames."""
    index = {(r['graph'], r['parts'], r['method'], r['repeat']): r for r in runs}
    medians = {(r['graph'], r['parts']): r for r in summaries}
    category_order = {name: i for i, name in enumerate(CATEGORY_LABELS)}
    graphs = sorted(targets, key=lambda g: (category_order[g['category']], g['name'].lower()))
    median_tables = {}
    for method in METHODS:
        folder = output / 'tables' / method
        folder.mkdir(parents=True, exist_ok=True)
        for repeat in [None, *range(repeats)]:
            stem = 'median' if repeat is None else f'run{repeat + 1}'
            title = f'{METHOD_LABELS[method]}：' + (f'{repeats} 次中位数' if repeat is None else f'第 {repeat + 1} 次')
            rows = []
            for graph in graphs:
                for k in parts:
                    if repeat is None:
                        result = medians[(graph['name'], k)][method]
                        # Balance failures remain included. Only missing/malformed outputs
                        # prevent the complete-repeat median from being published.
                        if result['verified_repeats'] != repeats:
                            result = {}
                        ratio, cut, fraction, seconds = [result.get(key) for key in
                            ['max_load_ratio_median', 'cut', 'cut_ratio', 'seconds']]
                    else:
                        result = index.get((graph['name'], k, method, repeat), {})
                        exact = result.get('exact', {}) if result.get('output_verified') else {}
                        ratio, cut = exact.get('max_load_ratio'), exact.get('cut')
                        fraction = cut / graph['undirected_edges'] if cut is not None and graph['undirected_edges'] else (0.0 if cut == 0 else None)
                        seconds = result.get('native_algorithm_seconds')
                    rows.append([CATEGORY_LABELS[graph['category']], graph['name'], str(k),
                                 f'{ratio:.9f}' if ratio is not None else '',
                                 str(cut) if cut is not None else '',
                                 f'{fraction:.9f}' if fraction is not None else '',
                                 f'{seconds:.6f}' if seconds is not None else ''])
            stream = io.StringIO(newline='')
            writer = csv.writer(stream)
            writer.writerow(TABLE_COLUMNS)
            writer.writerows(rows)
            (folder / (stem + '.csv')).write_text(stream.getvalue(), encoding='utf-8-sig')
            table = ['| ' + ' | '.join(TABLE_COLUMNS) + ' |',
                     '| --- | --- | ---: | ---: | ---: | ---: | ---: |']
            table.extend('| ' + ' | '.join(value or '—' for value in row) + ' |' for row in rows)
            (folder / (stem + '.md')).write_text('# ' + title + '\n\n' + '\n'.join(table) + '\n')
            if repeat is None:
                median_tables[method] = table
    notes = ['# CPU baseline 七列结果表', '',
             '两个方法分别存表；每个表覆盖所有选定图和 k。CSV 使用 UTF-8 BOM，可直接用 Excel 打开。', '',
             '- `median.csv` / `median.md`：各指标分别取全部重复的中位数；只有重复输出均完成结构核验后才填写。超出平衡约束的输出仍参与统计。',
             '- `run1.csv` / `run1.md` 等：逐次原始结果，运行编号在文件名中。',
             '- 节点平衡比例 = 最大分区节点数 / (总节点数 / k)；配置上限为 1.03，表内填写实际测量值。',
             '- 切边数按无向边计一次；切边比例 = 切边数 / 无向边总数，以小数表示。',
             '- 划分时间单位为秒，排除输入加载、输出写盘与独立核验，采用原生完整划分时间。',
             '- 空白表示尚未测得或未通过结构核验，具体运行/平衡状态见 `../runs.json` 和 `../summary.json`。',
             '- 线程、CPU 绑定、NUMA、版本、种子和二进制哈希见 `../metadata.json`。', '',
             '## 中位数表', '']
    notes.extend(f'- [{METHOD_LABELS[m]} CSV]({m}/median.csv) / [Markdown]({m}/median.md)' for m in METHODS)
    (output / 'tables' / 'README.md').write_text('\n'.join(notes) + '\n')
    return median_tables


def summarize(output, targets, runs, parts, repeats):
    summaries = []
    for graph in targets:
        for k in parts:
            row = {'graph': graph['name'], 'category': graph['category'], 'parts': k}
            for method in METHODS:
                own = [r for r in runs if (r['graph'], r['parts'], r['method']) == (graph['name'], k, method)]
                # A correctly computed partition may violate balance: retain its measurements.
                verified = [r for r in own if r.get('output_verified', bool(
                    r.get('exact') and sum(r['exact'].get('loads', [])) == r['exact'].get('vertices') and
                    r.get('integer_capacity') == r['exact'].get('capacity')))]
                balanced = [r for r in verified if r['exact']['capacity_ok']]
                result = {'verified_repeats': len(verified), 'balance_compliant_repeats': len(balanced),
                          'all_repeats_meet_capacity': len(balanced) == repeats,
                          'status_counts': dict(Counter(r['status'] for r in own))}
                if verified:
                    ratios = [r['exact']['max_load_ratio'] for r in verified]
                    result.update(seconds=statistics.median(r['native_algorithm_seconds'] for r in verified),
                                  cut=statistics.median(r['exact']['cut'] for r in verified),
                                  cut_ratio=statistics.median(r['exact']['cut'] / graph['undirected_edges'] if graph['undirected_edges'] else 0.0 for r in verified),
                                  max_load_ratio_median=statistics.median(ratios),
                                  max_load_ratio_range=[min(ratios), max(ratios)],
                                  seconds_range=[min(r['native_algorithm_seconds'] for r in verified), max(r['native_algorithm_seconds'] for r in verified)],
                                  cut_range=[min(r['exact']['cut'] for r in verified), max(r['exact']['cut'] for r in verified)],
                                  native_cut_mismatches=sum(r['reported_cut'] != r['exact']['cut'] for r in verified))
                row[method] = result
            summaries.append(row)
    save(output / 'summary.json', summaries)
    median_tables = export_tables(output, targets, runs, parts, repeats, summaries)
    valid_count = sum(bool(r.get('valid')) for r in runs)
    lines = ['# CPU baseline 实验', '',
             f'计划 {len(targets)} 张图 × {len(parts)} 种 k × {repeats} 次 × 2 个方法；已记录 {len(runs)} 次，其中 {valid_count} 次同时通过独立 cut 与严格容量核验。', '',
             '完整原生划分时间排除文件读取、标签文件写出和独立核验。Mt-METIS HS 使用 Total Time（含内部分发、粗化、初始化、细化与回收）；KaMinPar 使用 TIME partitioning（含图重排与划分器回收）。进程墙钟另存，不混入算法时间。', '',
             '线程、物理核、NUMA 策略、源码版本、可执行文件/动态库哈希见 metadata.json；逐次命令、输入哈希、原生日志、容量与核验见 runs.json。无预热；每次使用独立进程，重复间交替方法顺序。缺失输入与运行/核验失败均保留。', '',
             '节点平衡比例为最大分区节点数 / (N/k)，切边比例为 cut / 无向边总数，均填写实际数值。下表在每组重复输出均完成结构核验后，对各指标分别取中位数，包含超出 1.03 的输出。逐次七列表与 CSV 见 [tables/README.md](tables/README.md)。平衡达标次数、负载范围及失败状态另存 summary.json；约束未全部满足时，不能单凭 cut 宣称同约束下更优。', '']
    for method in METHODS:
        own = [r for r in runs if r['method'] == method]
        checked = sum(bool(r.get('output_verified')) for r in own)
        balanced = sum(bool(r.get('output_verified') and r['exact']['capacity_ok']) for r in own)
        lines += ['## ' + METHOD_LABELS[method], '',
                  f'已记录 {len(own)} 次；{checked} 次输出完成结构核验，其中 {balanced} 次满足严格 1.03 容量。', '',
                  *median_tables[method], '']
    discrepancies = [r for r in runs if r.get('exact') and r.get('reported_cut') != r['exact']['cut']]
    if discrepancies:
        lines += ['', '## 原生cut统计差异', '']
        lines += [f"- {r['graph']} / {r['method']} / k={r['parts']} / repeat={r['repeat']}：原生 {r['reported_cut']}，独立复算 {r['exact']['cut']}；报表采用后者，原始统计保留。" for r in discrepancies]
    (output / 'REPORT.md').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=PROJECT.parent / 'dataset_benchmark/manifest.json')
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--all', action='store_true')
    selection.add_argument('--names', nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mtmetis', type=Path, default=INSTALL / 'bin/mtmetis')
    parser.add_argument('--kaminpar', type=Path, default=INSTALL / 'bin/KaMinPar')
    parser.add_argument('--oracle', type=Path, default=PROJECT / 'build/gpart_verify_csr')
    parser.add_argument('--parts', type=int, nargs='+', default=[2, 4, 8, 16, 32])
    parser.add_argument('--threads', type=int, default=32)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--timeout', type=float, default=3600)
    parser.add_argument('--after-gpu-suite', type=Path, help='wait until this existing continuation-state.json reports completion')
    parser.add_argument('--report-only', action='store_true', help='rebuild tables from saved runs without launching experiments')
    args = parser.parse_args()
    if args.threads < 1 or args.repeats < 1 or args.timeout <= 0 or any(k not in [2, 4, 8, 16, 32] for k in args.parts):
        parser.error('require positive threads/repeats/timeout and k in {2,4,8,16,32}')
    if len(set(args.parts)) != len(args.parts):
        parser.error('duplicate k values')
    output = experiment_path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    manifest = read(args.manifest, {})
    requested = args.names or ([g['name'] for g in manifest['graphs']] if args.all else ['products'])
    if len(set(requested)) != len(requested):
        raise ValueError('Duplicate graph names')
    targets = [next(g for g in manifest['graphs'] if g['name'] == name) for name in requested]
    targets.sort(key=lambda g: g['name'] != 'products')
    planned = len(targets) * len(args.parts) * args.repeats * len(METHODS)
    with (output / '.runner.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.report_only:
            summarize(output, targets, read(output / 'runs.json', []), args.parts, args.repeats)
            publish_tables(output)
            save(output / 'reporting.json', {'driver_sha256': DRIVER_SHA256, 'utc': utc(),
                                             'columns': TABLE_COLUMNS, 'repeats': args.repeats})
            return
        save(output / 'selected-inputs.json', {'manifest': str(args.manifest.resolve()), 'graphs': targets,
                                              'parts': args.parts, 'repeats': args.repeats,
                                              'threads': args.threads, 'planned_runs': planned})
        if not (output / 'metadata.json').exists():
            summarize(output, targets, read(output / 'runs.json', []), args.parts, args.repeats)
        while args.after_gpu_suite:
            state = read(args.after_gpu_suite, {})
            if state.get('stage') == 'finished_all_selected_inputs':
                break
            if state.get('stage') == 'failed':
                raise RuntimeError('GPU continuation failed; inspect it before running CPU timing')
            save(output / 'state.json', {'stage': 'waiting_gpu_suite', 'gpu_stage': state.get('stage'),
                                        'planned_runs': planned, 'threads': args.threads,
                                        'pid': os.getpid(), 'utc': utc()})
            time.sleep(30)
        binding, cpus, nodes = cpu_binding(args.threads)
        archive = output / 'binaries'
        archive.mkdir(exist_ok=True)
        binaries = {}
        for name, path in [('mtmetis', args.mtmetis), ('kaminpar', args.kaminpar), ('oracle', args.oracle)]:
            path = path.resolve()
            target = archive / name
            digest = sha(path)
            if target.exists() and sha(target) != digest:
                raise ValueError('Frozen executable changed; choose a new output directory')
            if not target.exists():
                shutil.copy2(path, target)
            binaries[name] = {'path': str(target), 'source': str(path), 'sha256': digest}
        libraries = {}
        for method in METHODS:
            text = subprocess.check_output(['ldd', binaries[method]['path']], text=True)
            for match in re.finditer(r'=>\s+(/\S+)\s+\(', text):
                path = Path(match[1]).resolve()
                libraries[str(path)] = sha(path)
        identity = {'graphs': requested, 'parts': args.parts, 'repeats': args.repeats, 'seed': 0,
                    'threads': args.threads, 'physical_cpus': cpus, 'interleave_numa_nodes': nodes,
                    'binaries': {name: row['sha256'] for name, row in binaries.items()}, 'libraries': libraries,
                    'capacity': 'floor(103*N/(100*k))', 'manifest': str(args.manifest.resolve()),
                    'mtmetis_refinement': 'hs', 'kaminpar_preset': 'default', 'driver_sha256': DRIVER_SHA256}
        metadata = {'identity': identity, 'binaries': binaries, 'started_utc': utc(),
                    'build_info': read(INSTALL.parent / 'builds.json', {}),
                    'cpu': subprocess.check_output(['lscpu'], text=True)}
        previous = read(output / 'metadata.json', {})
        if previous and previous['identity'] != identity:
            raise ValueError('Resume identity differs; use a new output directory')
        save(output / 'metadata.json', previous or metadata)
        (output / ('driver-' + DRIVER_SHA256 + '.py')).write_bytes(DRIVER_SOURCE)
        runs = [r for r in read(output / 'runs.json', []) if r['status'] != 'input_not_ready']
        done = {(r['graph'], r['parts'], r['repeat'], r['method']) for r in runs}
        env = dict(os.environ, OMP_NUM_THREADS=str(args.threads), OMP_PROC_BIND='close', OMP_PLACES='cores')
        for graph in targets:
            name = graph['name']
            save(output / 'state.json', {'stage': 'checking_inputs', 'graph': name, 'recorded': len(runs),
                                        'planned_runs': planned, 'utc': utc(), 'pid': os.getpid()})
            directory = output / name
            directory.mkdir(exist_ok=True)
            inputs = None
            if graph['status'] == 'ready':
                folder = args.manifest.resolve().parent / graph['folder']
                meta = read(folder / 'metadata.json', {})
                inputs = {role: folder / (name + suffix) for role, suffix in [('indptr', '_indptr.bin'), ('indices', '_indices.bin'), ('metis', '.metis')]}
                input_hashes = {role: sha(path) for role, path in inputs.items()}
                if any(r['graph'] == name and r.get('input_sha256', input_hashes) != input_hashes for r in runs):
                    raise ValueError('Input changed while resuming: ' + name)
                with inputs['metis'].open() as stream:
                    dimensions = list(map(int, stream.readline().split()))
                if dimensions != [graph['vertices'], graph['undirected_edges']]:
                    raise ValueError('Manifest and METIS dimensions disagree: ' + name)
                if inputs['indptr'].stat().st_size != 8 * (graph['vertices'] + 1) or inputs['indices'].stat().st_size != 16 * graph['undirected_edges']:
                    raise ValueError('Manifest and CSR dimensions disagree: ' + name)
                for role, path in inputs.items():
                    if input_hashes[role] != meta['files'][path.name]['sha256']:
                        raise ValueError('Input hash changed: ' + str(path))
            for k in args.parts:
                for repeat in range(args.repeats):
                    for method in METHODS if repeat % 2 == 0 else METHODS[::-1]:
                        key = name, k, repeat, method
                        if key in done:
                            continue
                        row = {'graph': name, 'parts': k, 'repeat': repeat, 'method': method, 'valid': False}
                        if inputs is None:
                            row.update(status='input_not_ready', preparation_status=graph['status'])
                        else:
                            capacity = 103 * graph['vertices'] // (100 * k)
                            stem = f'{method}-k{k}-r{repeat}'
                            partition, log = directory / (stem + '.part'), directory / (stem + '.log')
                            if method == 'mtmetis':
                                command = [binaries[method]['path'], '-rhs', '-T' + str(args.threads), '-b1.03', '-s0', '-n1', '-N1', '-vnone', '-t', '-C', str(inputs['metis']), str(k), str(partition)]
                            else:
                                average = (graph['vertices'] + k - 1) // k
                                epsilon = (capacity + 0.5) / average - 1.0
                                row['configured_kaminpar_epsilon'] = epsilon
                                command = [binaries[method]['path'], str(inputs['metis']), '-k', str(k), '-P', 'default', '-t', str(args.threads), '-s', '0', '-v', '--disable-colors', '-o', str(partition), '-e', repr(epsilon)]
                            command = binding + command
                            row.update(command=command, partition=str(partition), log=str(log), integer_capacity=capacity,
                                       input_sha256=input_hashes, started_utc=utc())
                            save(output / 'state.json', {'stage': 'running', 'graph': name, 'parts': k,
                                                        'repeat': repeat, 'method': method, 'recorded': len(runs),
                                                        'planned_runs': planned, 'utc': utc(), 'pid': os.getpid()})
                            start = time.monotonic()
                            exit_code = invoke(command, log, args.timeout, env)
                            row.update(exit_code=exit_code, process_wall_seconds=time.monotonic() - start, finished_utc=utc(), status='runtime_error')
                            if exit_code == 0:
                                try:
                                    native_text = log.read_text()
                                    seconds, cut = metrics(method, native_text)
                                    if method == 'kaminpar':
                                        configured = int(re.search(r'Maximum block weight:\s+(\d+)', native_text)[1])
                                        if configured != capacity:
                                            raise ValueError('KaMinPar native capacity differs from strict integer capacity')
                                    row.update(native_algorithm_seconds=seconds, reported_cut=cut, partition_sha256=sha(partition))
                                    oracle_command = [binaries['oracle']['path'], str(inputs['indptr']), str(inputs['indices']), str(k), str(partition), 'text']
                                    check = subprocess.run(oracle_command, capture_output=True, text=True, env=dict(env, OMP_NUM_THREADS='4'), timeout=args.timeout)
                                    check_path = directory / (stem + '.verification.json')
                                    exact = json.loads(check.stdout)
                                    save(check_path, {'exit_code': check.returncode, 'command': oracle_command, 'result': exact, 'stderr': check.stderr})
                                    verified = check.returncode in [0, 1] and exact['capacity'] == capacity and exact['vertices'] == graph['vertices'] and sum(exact['loads']) == graph['vertices']
                                    balanced = bool(exact['capacity_ok'])
                                    valid = verified and balanced
                                    status = 'success' if valid else ('balance_exceeded' if verified else 'verification_error')
                                    row.update(output_verified=bool(verified), capacity_ok=balanced, valid=bool(valid), status=status, verification=str(check_path), exact=exact, verified_cut=exact['cut'], cut_matches_reported=exact['cut']==cut)
                                except Exception as error:
                                    row.update(status='verification_error', error=str(error))
                            elif exit_code == 'timeout':
                                row['status'] = 'timeout'
                        runs.append(row)
                        done.add(key)
                        save(output / 'runs.json', runs)
                        discard_partition(row)
                        save(output / 'runs.json', runs)
                        write_run_table(output / 'runs.csv', runs)
                        summarize(output, targets, runs, args.parts, args.repeats)
                        publish_tables(output)
                        save(output / 'state.json', {'stage': 'running', 'recorded': len(runs), 'planned_runs': planned,
                                                    'valid': sum(bool(r.get('valid')) for r in runs), 'utc': utc(), 'pid': os.getpid()})
                        print(json.dumps({key: row[key] for key in ['graph', 'parts', 'repeat', 'method', 'status', 'valid']}), flush=True)
        save(output / 'state.json', {'stage': 'complete', 'recorded': len(runs), 'planned_runs': planned,
                                    'valid': sum(bool(r.get('valid')) for r in runs), 'utc': utc()})


if __name__ == '__main__':
    main()
