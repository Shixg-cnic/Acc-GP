"""Keep verified measurements in tables; discard temporary vertex labels."""
import csv
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
ARCHIVE = PROJECT.parent / 'Acc-GP-archive' / 'experiments'


def experiment_path(value):
    """A results/ name selects an external work directory and public tables."""
    path = Path(value).resolve()
    try:
        return ARCHIVE / path.relative_to(PROJECT / 'results')
    except ValueError:
        return path


def discard_partition(row):
    """Call only after persisting the oracle result or the failure record."""
    value = row.get('partition')
    if not value:
        return
    path = Path(value)
    if path.suffix != '.part':
        raise ValueError('Expected a temporary .part label file: ' + str(path))
    if path.exists():
        row['partition_bytes'] = path.stat().st_size
        path.unlink()
    row['partition_deleted'] = True


def artifact_path(value):
    """Resolve old absolute result paths after moving raw records outside repo."""
    path = Path(value)
    if path.exists():
        return path
    try:
        return ARCHIVE / path.relative_to(PROJECT / 'results')
    except ValueError:
        return path


def write_run_table(path, runs):
    """One row per measurement, including failed and unverified attempts."""
    columns = ['graph', 'k', 'repeat', 'method', 'status', 'verified', 'seconds',
               'cut', 'reported_cut', 'vertices', 'undirected_edges', 'capacity',
               'capacity_ok', 'max_load_ratio', 'cut_fraction', 'coarsen_seconds',
               'initial_partition_seconds', 'uncoarsen_seconds', 'gpu_uuid',
               'partition_deleted']
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for run in runs:
            exact = run.get('exact') or {}
            timing = run.get('timing') or run.get('stage') or {}
            verified = run.get('verified', run.get('output_verified', False))
            cut = exact.get('cut', run.get('verified_cut'))
            edges = exact.get('undirected_edges')
            row = dict(graph=run.get('graph', ''), k=run.get('k', run.get('parts')),
                       repeat=run.get('repeat'), method=run.get('method'),
                       status=run.get('status', 'verified' if verified else 'unverified'),
                       verified=verified,
                       seconds=timing.get('algorithm_total_seconds', run.get('native_algorithm_seconds', run.get('seconds'))),
                       cut=cut, reported_cut=run.get('reported_cut', run.get('cut')),
                       vertices=exact.get('vertices'), undirected_edges=edges,
                       capacity=exact.get('capacity', run.get('integer_capacity')),
                       capacity_ok=exact.get('capacity_ok'), max_load_ratio=exact.get('max_load_ratio'),
                       cut_fraction=cut / edges if cut is not None and edges else (0 if cut == 0 else None),
                       gpu_uuid=run.get('gpu_uuid'), partition_deleted=run.get('partition_deleted', False))
            row.update({key: timing.get(key) for key in
                        ['coarsen_seconds', 'initial_partition_seconds', 'uncoarsen_seconds']})
            writer.writerow(row)
    temporary.replace(path)


def publish_tables(workspace):
    """Publish numeric CSVs separately when the workspace is in the archive."""
    workspace = Path(workspace).resolve()
    try:
        relative = workspace.relative_to(ARCHIVE)
    except ValueError:
        return
    import shutil
    for source in workspace.rglob('*'):
        if not source.is_file():
            continue
        if any(part in {'source', 'Testing', '__pycache__'} for part in source.relative_to(workspace).parts):
            continue
        if source.suffix != '.csv' and not (source.suffix == '.md' and
                (source.name in {'REPORT.md', 'OPTIMIZATION.md', 'SPEEDUP.md', 'CUT_RATIOS.md'} or
                 'tables' in source.relative_to(workspace).parts)):
            continue
        target = PROJECT / 'results' / relative / source.relative_to(workspace)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
