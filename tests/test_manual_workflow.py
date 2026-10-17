#!/usr/bin/env python3
"""CPU-only integration: simulated timings, real independent CSR cut checks."""
from array import array
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ManualWorkflow(unittest.TestCase):
    def test_modes_stages_resume_and_invalid_cut(self):
        with tempfile.TemporaryDirectory(prefix='acc-gp-workflow-') as directory:
            base = Path(directory)
            build, data = base / 'build', base / 'data'
            build.mkdir(); data.mkdir()
            def executable(name, body):
                path = build / name
                path.write_text('#!' + sys.executable + '\n' + body)
                path.chmod(0o755)
                return path
            # Real symmetric cycle input; fixture labels cut exactly four edges.
            n = 32
            (data / 'grid_indptr.bin').write_bytes(array('q', range(0, 2 * n + 1, 2)).tobytes())
            (data / 'grid_indices.bin').write_bytes(array('q', [u for v in range(n) for u in sorted([(v - 1) % n, (v + 1) % n])]).tobytes())
            (data / 'grid.metis').write_text('fixture (simulator ignores this file)\n')
            (data / 'manifest.json').write_text(json.dumps({'graphs': [dict(name='grid', folder='.', vertices=n, undirected_edges=n)]}))
            executable('nvidia-smi', "import sys\nif any(x.startswith('--query-gpu=') for x in sys.argv): print('GPU-test, Test, 1000 MiB')\n")
            executable('gpart_partition_standard', r'''
from array import array
import os, sys
from pathlib import Path
assert 'GPART_JOINT_DIAGNOSTICS' not in os.environ
mode = os.environ['GPART_COARSEN_MODE']
assert mode in ['residual', 'legacy', 'regret']
k = int(sys.argv[3])
Path(sys.argv[4]).write_bytes(array('i', [v // (32 // k) for v in range(32)]).tobytes())
print('coarsen_mode=' + mode)
print('partition_timing algorithm_total_seconds=' + ({'regret': '1', 'residual': '2', 'legacy': '3'}[mode]) + ' coarsen_seconds=0.25 initial_partition_seconds=0.25 uncoarsen_seconds=0.25')
print('final_edge_cut=' + str(k + (1 if os.environ.get('TEST_BAD_CUT') and mode == 'regret' else 0)))
''')
            jet = executable('jet', r'''
import json, sys
from pathlib import Path
k = int(Path(sys.argv[2]).read_text().splitlines()[1])
Path(sys.argv[3]).write_text('\n'.join(str(v // (32 // k)) for v in range(32)))
Path(sys.argv[4]).write_text(json.dumps([{'total-duration-seconds': 4, 'edge-cut': k}]))
''')
            executable('gpart_verify_csr', 'import sys, json\nfrom pathlib import Path\nsys.path.insert(0, ' + repr(str(ROOT / 'tools')) + ')\nfrom verify_partition import verify\nprint(json.dumps(verify(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[4]), int(sys.argv[3]), partition_format=sys.argv[5])))\n')
            env = {k: v for k, v in os.environ.items() if not k.startswith('GPART_')}
            env.update(PATH=str(build) + os.pathsep + env.get('PATH', ''),
                       BUILD_DIR=str(build), DATA_DIR=str(data), JET_BIN=str(jet),
                       GPU='auto', GRAPHS='grid', PARTS='4', REPEATS='2', TIMEOUT='10',
                       COMPARE_JET='1', COMPARE_LEGACY='0', GPART_JOINT_DIAGNOSTICS='1',
                       LATEST_FILE=str(base / 'LATEST'), RESULTS_DIR=str(base / 'csv'))
            env.pop('REFERENCE_BIN', None)
            env.pop('REFERENCE_COARSEN_MODE', None)
            def run_script(name, *args, environment=env):
                result = subprocess.run([str(ROOT / name), *map(str, args)], env=environment, cwd=base,
                                        text=True, capture_output=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result
            def read(name):
                with (Path(env['RESULTS_DIR']) / name).open(encoding='utf-8-sig') as stream:
                    return list(csv.DictReader(stream))
            work = base / 'work'
            run_script('run.sh', work)
            records = read('runs.csv')
            self.assertEqual(len(records), 4)
            self.assertTrue(all(r['status'] == 'verified' for r in records))
            self.assertEqual({r['coarsen_mode'] for r in records if r['method'] == 'ours'}, {'regret'})
            for row in records:
                if row['method'] == 'ours':
                    self.assertEqual(float(row['cleanup_and_boundary_seconds']), .25)
            comparison = read('comparison.csv')[0]
            self.assertEqual(float(comparison['speedup_over_jet']), 4)
            self.assertEqual(comparison['speedup_over_legacy'], '')
            self.assertEqual(float(comparison['cut_ratio_over_jet']), 1)
            self.assertFalse(list((work / 'labels').glob('*.part')))
            saved = (work / 'runs.jsonl').read_bytes()
            run_script('run.sh', work)
            self.assertEqual(saved, (work / 'runs.jsonl').read_bytes())
            run_script('analyze_cuts.sh')
            self.assertEqual(comparison, read('comparison.csv')[0])
            for overrides in [dict(GPART_COARSEN_MODE='residual'), dict(COMPARE_LEGACY='1')]:
                rejected = subprocess.run([str(ROOT / 'run.sh'), str(base / 'rejected')],
                    env=dict(env, **overrides), capture_output=True, text=True, timeout=60)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('archived', rejected.stdout + rejected.stderr)
            # Wrong reported cuts must survive as failures, never as speedups.
            bad_env = dict(env, TEST_BAD_CUT='1', RESULTS_DIR=str(base / 'bad-csv'))
            run_script('run.sh', base / 'bad-work', environment=bad_env)
            with (base / 'bad-csv/comparison.csv').open(encoding='utf-8-sig') as stream:
                bad = next(csv.DictReader(stream))
            self.assertEqual(bad['status'], 'incomplete_or_invalid')
            self.assertEqual(bad['speedup_over_legacy'], '')
            self.assertFalse(list((base / 'bad-work/labels').glob('*.part')))

            ablation_env = dict(env, GPART_COARSEN_MODE='regret',
                                REFERENCE_BIN=str(build / 'gpart_partition_standard'),
                                REFERENCE_COARSEN_MODE='residual', COMPARE_LEGACY='0',
                                RESULTS_DIR=str(base / 'ablation-csv'))
            run_script('run.sh', base / 'ablation', environment=ablation_env)
            with (base / 'ablation-csv/comparison.csv').open() as stream:
                row = next(csv.DictReader(stream))
            self.assertEqual(float(row['speedup_over_reference']), 2)
            self.assertEqual(float(row['cut_ratio_over_reference']), 1)
            with (base / 'ablation-csv/runs.csv').open() as stream:
                records = list(csv.DictReader(stream))
            self.assertEqual({r['coarsen_mode'] for r in records if r['method']=='reference'}, {'residual'})
            self.assertEqual({r['coarsen_mode'] for r in records if r['method']=='ours'}, {'regret'})
            self.assertFalse(list((base / 'ablation/labels').glob('*.part')))


if __name__ == '__main__':
    unittest.main()
