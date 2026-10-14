"""Cross-check the C++ oracle and reject asymmetric parallel-edge inputs."""
from array import array
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from verify_partition import verify

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    ptr, idx, part = root/'ptr.bin', root/'idx.bin', root/'part.bin'
    rows = [[0, 4, 4], [2], [1], [], [0, 0], [6], [5], []]
    offsets, indices = array('q', [0]), array('q')
    for row in rows:
        indices.extend(row)
        offsets.append(len(indices))
    ptr.write_bytes(offsets.tobytes())
    idx.write_bytes(indices.tobytes())
    part.write_bytes(array('i', [0]*4+[1]*4).tobytes())
    command = [binary, str(ptr), str(idx), '2', str(part), 'binary']
    actual = json.loads(subprocess.check_output(command+['--symmetric'], text=True))
    expected = verify(ptr, idx, part, 2)
    assert actual == expected, (actual, expected)
    assert actual['cut'] == 2 and actual['undirected_edges'] == 4
    text = root/'part.txt'
    text.write_text('\n'.join(['0']*4+['1']*4)+'\n')
    text_command = [binary, str(ptr), str(idx), '2', str(text), 'text']
    assert json.loads(subprocess.check_output(text_command, text=True)) == expected

    # Even cut/edge counts alone cannot detect a missing reverse multiplicity.
    rows[4] = []
    offsets, indices = array('q', [0]), array('q')
    for row in rows:
        indices.extend(row)
        offsets.append(len(indices))
    ptr.write_bytes(offsets.tobytes());idx.write_bytes(indices.tobytes())
    failed = subprocess.run(command+['--symmetric'], capture_output=True, text=True)
    assert failed.returncode and 'asymmetric edge multiplicity' in failed.stderr
    part.write_bytes(array('i', [2]*8).tobytes())
    assert subprocess.run(command, capture_output=True).returncode
    part.write_bytes(array('i', [0]*8).tobytes())
    assert subprocess.run(command, capture_output=True).returncode
    part.write_bytes(array('i', [0]*7).tobytes())
    assert subprocess.run(command, capture_output=True).returncode
print('independent_cpp_oracle_ok=1')
