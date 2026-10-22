#!/usr/bin/env bash
# Run from any directory. Build the project yourself with cmake -B build first.
# Optional examples: GPU=1 ./run.sh; GRAPHS="grid soc-Pokec" REPEATS=1 ./run.sh
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: ./run.sh [work-directory]
Defaults: 51 selected datasets, k=4/8/16/32/64/128, 3 repeats, regret Acc-GP + Jet.
Compile yourself in build/. The script never compiles anything.
Settings: GPU=auto|index|UUID, GRAPHS="grid soc-Pokec", PARTS="4 8", REPEATS=3,
          BUILD_DIR, DATA_DIR, JET_BIN, COMPARE_JET=0,
          GPART_COARSEN_MODE=regret, REFERENCE_BIN (archived algorithm comparison),
          REFERENCE_REFINE_MODE=legacy|joint|joint-polish (archived executable only),
          REFERENCE_COARSEN_MODE (optional, for Acc-GP reference binaries), TIMEOUT=600.
Results: results/manual/<run-name>/*.csv; raw logs outside the source repository.
Re-run with the same work-directory to resume an interrupted experiment.
HELP
    exit 0
fi
[[ $# -le 1 ]] || { echo 'Usage: ./run.sh [work-directory]' >&2; exit 2; }
export ACC_GP_ROOT="$ROOT"
export BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
export DATA_DIR="${DATA_DIR:-$ROOT/../dataset_benchmark}"
export GPU="${GPU:-auto}" PARTS="${PARTS:-4 8 16 32 64 128}" REPEATS="${REPEATS:-3}"
export TIMEOUT="${TIMEOUT:-600}" COMPARE_JET="${COMPARE_JET:-1}"
export COMPARE_LEGACY="${COMPARE_LEGACY:-0}"
export RUN_DIR="${1:-${OUT_DIR:-$ROOT/../Acc-GP-archive/manual/$(date +%Y%m%d-%H%M%S)}}"
python3 - <<'PY'
import fcntl, hashlib, json, math, os, re, shutil, subprocess, time
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ['ACC_GP_ROOT'])
out = Path(os.environ['RUN_DIR']).resolve()
build = Path(os.environ['BUILD_DIR']).resolve()
data = Path(os.environ['DATA_DIR']).resolve()
parts = [int(k) for k in os.environ['PARTS'].split()]
repeats, timeout = int(os.environ['REPEATS']), int(os.environ['TIMEOUT'])
if not parts or len(parts) != len(set(parts)) or any(k not in [4, 8, 16, 32, 64, 128] for k in parts) or repeats < 1 or timeout < 1:
    raise SystemExit('PARTS must be unique values in 4/8/16/32/64/128; REPEATS and TIMEOUT must be positive.')
selection = json.loads((root / 'tools/benchmark_selection.json').read_text())
categories = {name: category for category, names in selection['categories'].items() for name in names}
names = os.environ.get('GRAPHS', '').split() or list(categories)
excluded = set(selection['excluded_by_user']) | set(selection['excluded_due_to_memory'])
if len(names) != len(set(names)) or not set(names) <= categories.keys() or set(names) & excluded:
    raise SystemExit('GRAPHS contains duplicate, unknown or excluded datasets.')
manifest = json.loads((data / 'manifest.json').read_text())
graphs = {g['name']: g for g in manifest['graphs']}
chosen = []
for name in names:
    g = dict(graphs[name], category=categories[name])
    folder = data / g['folder']
    g.update(indptr=str(folder / (name + '_indptr.bin')), indices=str(folder / (name + '_indices.bin')),
             metis=str(folder / (name + '.metis')))
    for key in ['indptr', 'indices'] + (['metis'] if os.environ['COMPARE_JET'] != '0' else []):
        if not Path(g[key]).is_file(): raise SystemExit('Missing input: ' + g[key])
    if 2 * g['undirected_edges'] >= 2**31:
        print('Skipping unsupported 32-bit CSR dataset:', name, flush=True)
        continue
    g['variant'] = 'standard'
    chosen.append(g)
if not chosen: raise SystemExit('No datasets fit the supported 32-bit CSR representation.')
sources = {'ours_' + v: build / ('gpart_partition_' + v) for v in {g['variant'] for g in chosen}}
sources['oracle'] = build / 'gpart_verify_csr'
methods = ['ours']
if os.environ['COMPARE_LEGACY'] != '0':
    raise SystemExit('Legacy coarsening was removed. Use REFERENCE_BIN with an archived executable.')
if os.environ['COMPARE_JET'] != '0':
    default_jets = [root.parent / 'sotas/Jet-Partitioner/build/app/jet',
                    root.parent / 'sotas/.build-deps/jet-5090/build-jet/app/jet']
    jet = Path(os.environ['JET_BIN']).resolve() if os.environ.get('JET_BIN') else next((p for p in default_jets if p.is_file()), default_jets[0])
    sources['jet'] = jet
    methods.append('jet')
if os.environ.get('REFERENCE_BIN'):
    sources['reference'] = Path(os.environ['REFERENCE_BIN']).resolve()
    methods.append('reference')
for name, path in sources.items():
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SystemExit('Missing executable: ' + str(path) + '\nCompile in build/ yourself; set JET_BIN if Jet is installed elsewhere.')

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)
def utc(): return datetime.now(timezone.utc).isoformat()
inventory = [line.split(', ', 2) for line in subprocess.check_output(
    ['nvidia-smi', '--query-gpu=uuid,name,memory.total', '--format=csv,noheader'], text=True).strip().splitlines()]
if os.environ['GPU'] == 'auto' and len({tuple(g[1:]) for g in inventory}) != 1:
    raise SystemExit('Automatic selection requires identical GPUs; set GPU to one index or UUID.')
out.mkdir(parents=True, exist_ok=True)
lock = (out / '.run.lock').open('w')
try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit('This experiment is already running.')
published = Path(os.environ.get('RESULTS_DIR', str(root / 'results/manual' / out.name))).resolve()
env = dict(os.environ, OMP_NUM_THREADS='4')
for key in ['GPART_GPU_TIMINGS', 'SCLP_DIAGNOSTICS']: env.pop(key, None)
retired_refine = ['GPART_REFINE_MODE', 'GPART_JOINT_ROUNDS', 'GPART_JOINT_CONFLICT_ROUNDS',
                  'GPART_JOINT_DEDUPLICATE', 'GPART_JOINT_COMPLEMENT', 'GPART_JOINT_DIAGNOSTICS',
                  'GPART_SPARSE_DELTA', 'GPART_REPAIR_ENUMERATION', 'GPART_SPARSE_CUT_BOUND']
stale = [key for key in retired_refine if key in env]
if stale: raise SystemExit('Retired production controls; unset: ' + ', '.join(stale) + '. Use REFERENCE_* for archived binaries.')
ours_mode = env.get('GPART_COARSEN_MODE', 'regret')
if ours_mode != 'regret': raise SystemExit('Only regret coarsening is maintained; use REFERENCE_BIN for archived modes.')
method_overrides = {method: {} for method in methods}
method_overrides['ours'] = {'GPART_COARSEN_MODE': ours_mode}
if os.environ.get('REFERENCE_COARSEN_MODE'):
    reference_mode = os.environ['REFERENCE_COARSEN_MODE']
    if 'reference' not in methods or reference_mode not in ['regret', 'residual', 'legacy', 'sclp']:
        raise SystemExit('REFERENCE_COARSEN_MODE requires REFERENCE_BIN and a valid mode.')
    method_overrides['reference'] = {'GPART_COARSEN_MODE': reference_mode}
if os.environ.get('REFERENCE_REPAIR_ENUMERATION') is not None:
    repair_mode = os.environ['REFERENCE_REPAIR_ENUMERATION']
    if 'reference' not in methods or repair_mode not in ['0', '1']:
        raise SystemExit('REFERENCE_REPAIR_ENUMERATION requires REFERENCE_BIN and 0 or 1.')
    method_overrides['reference']['GPART_REPAIR_ENUMERATION'] = repair_mode
if os.environ.get('REFERENCE_SPARSE_CUT_BOUND') is not None:
    sparse_mode = os.environ['REFERENCE_SPARSE_CUT_BOUND']
    if 'reference' not in methods or sparse_mode not in ['0', '1']:
        raise SystemExit('REFERENCE_SPARSE_CUT_BOUND requires REFERENCE_BIN and 0 or 1.')
    method_overrides['reference']['GPART_SPARSE_CUT_BOUND'] = sparse_mode
for name, allowed in [('REFERENCE_REFINE_MODE', ['legacy', 'joint', 'joint-polish']),
                      ('REFERENCE_JOINT_COMPLEMENT', ['0', '1']),
                      ('REFERENCE_SPARSE_DELTA', ['0', '1'])]:
    if name in os.environ:
        if 'reference' not in methods or os.environ[name] not in allowed:
            raise SystemExit(name + ' requires REFERENCE_BIN and one of: ' + ', '.join(allowed))
        method_overrides['reference']['GPART_' + name[len('REFERENCE_'):]] = os.environ[name]
identity = dict(graphs=chosen, parts=parts, repeats=repeats, methods=methods,
                gpu=os.environ['GPU'], gpu_inventory=inventory, seed=0, imbalance='1.03',
                capacity='floor(103*N/(100*k))', omp_num_threads=4, timeout_seconds=timeout, results=str(published),
                binaries={n: dict(source=str(p), sha256=sha(p)) for n, p in sources.items()},
                overrides={k: v for k, v in env.items() if k.startswith('GPART_')},
                method_overrides=method_overrides,
                time_scope='native algorithm incl. internal transfer, repair and cleanup; excludes load/upload/final output',
                runner_sha256=sha(root / 'run.sh'), analyzer_sha256=sha(root / 'analyze_cuts.sh'))
meta = out / 'metadata.json'
if meta.exists() and json.loads(meta.read_text()) != identity:
    raise SystemExit('Configuration or executable changed. Use a new work-directory.')
save(meta, identity)
(out / 'binaries').mkdir(exist_ok=True)
for name, source in sources.items():
    frozen = out / 'binaries' / name
    if not frozen.exists(): shutil.copy2(source, frozen)
    if sha(frozen) != identity['binaries'][name]['sha256']: raise SystemExit('Frozen executable differs: ' + name)
latest = Path(os.environ.get('LATEST_FILE', str(root.parent / 'Acc-GP-archive/manual/LATEST')))
latest.parent.mkdir(parents=True, exist_ok=True)
latest.write_text(str(out) + '\n')
(out / 'logs').mkdir(exist_ok=True)
(out / 'labels').mkdir(exist_ok=True)
rows = [json.loads(line) for line in (out / 'runs.jsonl').read_text().splitlines()] if (out / 'runs.jsonl').exists() else []
done = {(r['graph'], r['k'], r['repeat'], r['method']) for r in rows}
assignments = json.loads((out / 'gpu-assignments.json').read_text()) if (out / 'gpu-assignments.json').exists() else {}
blocked = json.loads((out / 'memory-blocked.json').read_text()) if (out / 'memory-blocked.json').exists() else {}

def processes():
    result = {}
    text = subprocess.check_output(['nvidia-smi', '--query-compute-apps=gpu_uuid,pid', '--format=csv,noheader'], text=True)
    for line in text.splitlines():
        uuid, pid = (x.strip() for x in line.split(',', 1))
        result.setdefault(uuid, set()).add(int(pid))
    return result

def wait_idle(uuid):
    stable, announced = 0, False
    while stable < 3:
        busy = processes().get(uuid, set())
        if busy and not announced: print('Waiting for an idle GPU:', uuid, flush=True); announced = True
        stable = 0 if busy else stable + 1
        time.sleep(1 if busy else .1)

def measure(command, log, metrics, uuid, method):
    for attempt in range(10):
        wait_idle(uuid)
        metrics.unlink(missing_ok=True)
        with log.open('w') as stream:
            process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                       env=dict(env, CUDA_VISIBLE_DEVICES=uuid, **method_overrides[method]))
            start, overlap, timed_out = time.monotonic(), False, False
            try:
                while process.poll() is None:
                    overlap |= bool(processes().get(uuid, set()) - {process.pid})
                    if time.monotonic() - start > timeout:
                        process.kill(); process.wait(); timed_out = True; break
                    time.sleep(.2)
            except BaseException:
                if process.poll() is None: process.terminate(); process.wait()
                raise
        overlap |= bool(processes().get(uuid, set()))
        if not overlap: return process.returncode, timed_out
        shutil.copy2(log, log.with_suffix('.overlap-' + str(attempt) + '.log'))
        print('GPU overlap detected; repeating:', log.name, flush=True)
    raise RuntimeError('No uncontended GPU window after 10 attempts.')

def command(g, k, method, label, metrics):
    if method != 'jet':
        binary = 'ours_' + g['variant'] if method in ['ours', 'legacy'] else 'reference'
        return [str(out / 'binaries' / binary), g['indptr'], g['indices'], str(k), str(label), '1.03', '0']
    nominal, capacity = (g['vertices'] + k - 1) // k, 103 * g['vertices'] // (100 * k)
    alpha = '1.03' if int(1.03 * nominal) == capacity else repr((capacity + .5) / nominal)
    config = out / (g['name'] + '-k' + str(k) + '.config')
    config.write_text('0\n' + str(k) + '\n1\n' + alpha + '\n0\n')
    return [str(out / 'binaries/jet'), g['metis'], str(config), str(label), str(metrics)]

def analyze(*extra):
    subprocess.run([str(root / 'analyze_cuts.sh'), str(out), *extra], check=True,
                   env=dict(os.environ, ACC_GP_INTERNAL_ANALYSIS='1'))

print('Work directory:', out, '\nCSV directory:', published, flush=True)
for g in chosen:
    name = g['name']
    if name in blocked: continue
    if name not in assignments:
        if os.environ['GPU'] == 'auto':
            while True:
                occupied = processes()
                free = [gpu[0] for gpu in reversed(inventory) if not occupied.get(gpu[0])]
                if free: uuid = free[0]; break
                print('Waiting for an idle GPU...', flush=True); time.sleep(5)
        else:
            uuid = subprocess.check_output(['nvidia-smi', '-i', os.environ['GPU'], '--query-gpu=uuid', '--format=csv,noheader'], text=True).strip()
        assignments[name] = uuid
        save(out / 'gpu-assignments.json', assignments)
    uuid = assignments[name]
    for method in methods:
        stem = name + '-' + method + '-warmup'
        marker, label = out / (stem + '.done'), out / 'labels' / (stem + '.part')
        if marker.exists(): continue
        metrics = out / 'logs' / (stem + '.metrics.json')
        code, expired = measure(command(g, parts[0], method, label, metrics), out / 'logs' / (stem + '.log'), metrics, uuid, method)
        label.unlink(missing_ok=True)
        if not code and 'GPART_COARSEN_MODE' in method_overrides[method]:
            warmup_text = (out / 'logs' / (stem + '.log')).read_text(errors='replace')
            if not re.search(r'\bcoarsen_mode=' + re.escape(method_overrides[method]['GPART_COARSEN_MODE']) + r'\b', warmup_text):
                raise SystemExit('Executable does not confirm the requested coarsening mode. Rebuild current sources and use a new work-directory.')
        if code: print('Warmup failed; timed attempt will record the failure:', stem, flush=True)
        marker.touch()
    oom = False
    for k in parts:
        if oom: break
        for repeat in range(repeats):
            if oom: break
            shift = repeat % len(methods)
            for method in methods[shift:] + methods[:shift]:
                if (name, k, repeat, method) in done: continue
                stem = name + '-k' + str(k) + '-r' + str(repeat) + '-' + method
                label, log = out / 'labels' / (stem + '.part'), out / 'logs' / (stem + '.log')
                metrics = log.with_suffix('.metrics.json')
                cmd = command(g, k, method, label, metrics)
                started = utc()
                code, expired = measure(cmd, log, metrics, uuid, method)
                row = dict(id=stem, graph=name, category=g['category'], k=k, repeat=repeat, method=method,
                           gpu_uuid=uuid, started_utc=started, finished_utc=utc(), command=cmd,
                           partition=str(label), log=str(log), returncode=code,
                           coarsen_mode=method_overrides[method].get('GPART_COARSEN_MODE'),
                           status='timeout' if expired else 'failed' if code else 'ok')
                text = log.read_text(errors='replace')
                if row['status'] == 'ok':
                    try:
                        if method == 'jet':
                            stage = json.loads(metrics.read_text())
                            if len(stage) != 1: raise ValueError('Expected one Jet metrics record')
                            stage = stage[0]
                            row.update(seconds=float(stage['total-duration-seconds']), reported_cut=int(stage['edge-cut']), stage=stage)
                        else:
                            if 'GPART_COARSEN_MODE' in method_overrides[method] and not re.search(r'\bcoarsen_mode=' + re.escape(method_overrides[method]['GPART_COARSEN_MODE']) + r'\b', text):
                                raise ValueError('Binary did not confirm requested coarsening mode; rebuild the current sources.')
                            timing = re.findall(r'^partition_timing (.*)$', text, re.M)[-1]
                            stage = {key: float(value) for key, value in re.findall(r'(\w+_seconds)=([0-9.eE+-]+)', timing)}
                            row.update(seconds=stage['algorithm_total_seconds'], reported_cut=int(re.findall(r'^final_edge_cut=(\d+)$', text, re.M)[-1]), stage=stage)
                        if not math.isfinite(row['seconds']) or row['seconds'] <= 0 or row['reported_cut'] < 0: raise ValueError('Invalid algorithm time or cut')
                    except (ValueError, KeyError, IndexError, OSError) as error:
                        row.update(status='parse_failed', error=str(error))
                if row['status'] != 'ok': row['error_tail'] = text[-2000:]
                with (out / 'runs.jsonl').open('a') as stream: stream.write(json.dumps(row) + '\n')
                done.add((name, k, repeat, method))
                print(f'{name} k={k} repeat={repeat + 1} {method}: {row["status"]}', flush=True)
                if code and re.search(r'out of memory|cudaErrorMemoryAllocation|bad_alloc', text, re.I):
                    blocked[name] = dict(id=stem, method=method, reason='runtime_oom')
                    save(out / 'memory-blocked.json', blocked)
                    oom = True; break
    # All timed methods/k/repeats for this graph have ended. Verify, then delete labels.
    analyze('--verify-only', name)
analyze()
print('Finished. Send the CSV files from:', published, flush=True)
PY
