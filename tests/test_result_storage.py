"""Host-only checks for verified measurements surviving label-file deletion."""
from array import array
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / 'tools'))
import result_storage as storage


class ResultStorageTests(unittest.TestCase):
    def test_cleanup_keeps_exact_measurement_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            partition = Path(directory) / 'result.part'
            partition.write_bytes(b'12345678')
            row = dict(partition=str(partition), verified=True,
                       exact=dict(cut=3, capacity_ok=True), method='ours')
            storage.discard_partition(row)
            storage.discard_partition(row)
            self.assertFalse(partition.exists())
            self.assertEqual(row['partition_bytes'], 8)
            self.assertEqual(row['exact']['cut'], 3)
            storage.write_run_table(Path(directory) / 'runs.csv', [row])
            with (Path(directory) / 'runs.csv').open() as stream:
                result = list(csv.DictReader(stream))[0]
            self.assertEqual(result['cut'], '3')
            self.assertEqual(result['partition_deleted'], 'True')

    def test_rejects_non_label_file(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / 'input.bin'
            data.write_bytes(b'input')
            with self.assertRaises(ValueError):
                storage.discard_partition({'partition': str(data)})
            self.assertEqual(data.read_bytes(), b'input')

    def test_work_directory_and_table_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'project'
            archive = Path(directory) / 'archive'
            with patch.object(storage, 'PROJECT', root), patch.object(storage, 'ARCHIVE', archive):
                work = storage.experiment_path(root / 'results/test')
                self.assertEqual(work, archive / 'test')
                work.mkdir(parents=True)
                (work / 'runs.csv').write_text('cut\n1\n')
                (work / 'candidate').write_bytes(b'binary')
                (work / 'result.part').write_bytes(b'labels')
                (work / 'source').mkdir()
                (work / 'source/input.csv').write_text('not a result')
                storage.publish_tables(work)
                published = sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
                self.assertEqual(published, ['results/test/runs.csv'])
                self.assertEqual(storage.artifact_path(root / 'results/test/candidate'), work / 'candidate')

    def test_cli_verifies_real_csr_before_deleting_labels(self):
        # CPU stubs stand in for the timed programs; the CSR oracle is real.
        oracle = PROJECT / 'build/gpart_verify_csr'
        if not oracle.exists():
            self.skipTest('Build the independent C++ CSR oracle for the CLI integration check')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            offsets = array('q', [2 * i for i in range(17)])
            neighbors = array('q', [u for v in range(16) for u in [(v - 1) % 16, (v + 1) % 16]])
            (root / 'indptr.bin').write_bytes(offsets.tobytes())
            (root / 'indices.bin').write_bytes(neighbors.tobytes())
            (root / 'graph.metis').write_text('16 16\n')
            smi = root / 'nvidia-smi'
            smi.write_text('#!/usr/bin/env python3\nimport sys\nif any("query-gpu=" in x for x in sys.argv): print("0, TEST-GPU, test, 32768")\n')
            ours = root / 'ours'
            ours.write_text('#!/usr/bin/env python3\nfrom array import array\nfrom pathlib import Path\nimport sys\nk=int(sys.argv[3]);Path(sys.argv[4]).write_bytes(array("i",[i%k for i in range(16)]).tobytes())\nprint("partition_timing algorithm_total_seconds=0.25 coarsen_seconds=0.1 initial_partition_seconds=0.05 uncoarsen_seconds=0.1")\nprint("final_edge_cut=16")\n')
            jet = root / 'jet'
            jet.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\nimport sys,json\nk=int(Path(sys.argv[2]).read_text().splitlines()[1]);Path(sys.argv[3]).write_text("".join(str(i%k)+"\\n" for i in range(16)))\nPath(sys.argv[4]).write_text(json.dumps([{"total-duration-seconds":0.5,"edge-cut":16}]))\n')
            for program in [smi, ours, jet]:
                program.chmod(0o755)
            output = root / 'run'
            command = [sys.executable, str(PROJECT / 'tools/compare_jet.py'),
                       '--indptr', str(root / 'indptr.bin'), '--indices', str(root / 'indices.bin'),
                       '--jet-graph', str(root / 'graph.metis'), '--jet', str(jet),
                       '--ours', str(ours), '--reference', str(ours), '--oracle', str(oracle),
                       '--output', str(output), '--parts', '4', '8', '--repeats', '1']
            subprocess.run(command, check=True, capture_output=True, text=True,
                           env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH']))
            rows = json.loads((output / 'runs.json').read_text())
            self.assertEqual(len(rows), 6)
            self.assertFalse(list(output.glob('*.part')))
            self.assertTrue(all(r['verified'] and r['exact']['cut'] == 16 and
                                r['exact']['capacity_ok'] and r['partition_deleted'] for r in rows))
            with (output / 'runs.csv').open() as stream:
                self.assertEqual(len(list(csv.DictReader(stream))), 6)


if __name__ == '__main__':
    unittest.main()
