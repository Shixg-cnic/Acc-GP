#!/usr/bin/env bash
# Official CPU baselines; independently verify and delete labels.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: ./run_cpu_baselines.sh [output-directory]
Defaults: current 51 graphs, k=64/128, 3 repeats, both CPU methods,
          32 physical cores, NUMA interleave over their nodes, seed 0.
Outputs: results/cpu-baselines/k64-k128/ (CSV/tables); raw data in sibling archive.
Run again with the same directory to resume. Verified outputs, including
balance violations, are reused; unverified failures retry once per invocation.
All attempts remain recorded. A nonzero final exit reports unverified slots.
Settings: GRAPHS="grid soc-Pokec", PARTS="64 128", THREADS=32, REPEATS=3,
          TIMEOUT=3600, OUT_DIR, MANIFEST, MTMETIS_BIN, KAMINPAR_BIN, ORACLE_BIN.
Optional: REUSE_RESULTS=/path/to/compatible/previous/results
          METHODS="mtmetis" MTMETIS_REFINEMENT=greedy (official default)
          METHODS="mtkahip" MTKAHIP_PRESET=multitrysocialparallel MTKAHIP_BIN=/path/to/mtkahip
          PARTITION_DIR=/dev/shm/accgp-cpu-labels (temporary labels only)
          REPORT_ONLY=1 (rebuild tables without launching CPU programs).
The script uses installed binaries and does not compile. Runs are sequential;
use a CPU-idle window for comparable timings.
HELP
    exit 0
fi
[[ $# -le 1 ]] || { echo 'Usage: ./run_cpu_baselines.sh [output-directory]' >&2; exit 2; }
read -r -a parts <<< "${PARTS:-64 128}"
args=(--output "${1:-${OUT_DIR:-$ROOT/results/cpu-baselines/k64-k128}}"
      --parts "${parts[@]}" --threads "${THREADS:-32}" --repeats "${REPEATS:-3}"
      --timeout "${TIMEOUT:-3600}" --retry-failed)
if [[ -n "${METHODS:-}" ]]; then
    read -r -a methods <<< "$METHODS"
    args+=(--methods "${methods[@]}")
fi
[[ -z "${MTMETIS_REFINEMENT:-}" ]] || args+=(--mtmetis-refinement "$MTMETIS_REFINEMENT")
[[ -z "${MTKAHIP_PRESET:-}" ]] || args+=(--mtkahip-preset "$MTKAHIP_PRESET")
[[ -z "${MTKAHIP_BIN:-}" ]] || args+=(--mtkahip "$MTKAHIP_BIN")
[[ -z "${PARTITION_DIR:-}" ]] || args+=(--partition-dir "$PARTITION_DIR")
if [[ -n "${GRAPHS:-}" ]]; then
    read -r -a graphs <<< "$GRAPHS"
    args+=(--names "${graphs[@]}")
else
    args+=(--all)
fi
[[ -z "${MANIFEST:-}" ]] || args+=(--manifest "$MANIFEST")
[[ -z "${MTMETIS_BIN:-}" ]] || args+=(--mtmetis "$MTMETIS_BIN")
[[ -z "${KAMINPAR_BIN:-}" ]] || args+=(--kaminpar "$KAMINPAR_BIN")
[[ -z "${ORACLE_BIN:-}" ]] || args+=(--oracle "$ORACLE_BIN")
[[ -z "${REUSE_RESULTS:-}" ]] || args+=(--reuse-results "$REUSE_RESULTS")
if [[ "${REPORT_ONLY:-0}" == 1 ]]; then
    # Without explicit overrides, the Python driver reads the saved selection.
    args=(--output "${1:-${OUT_DIR:-$ROOT/results/cpu-baselines/k64-k128}}" --report-only)
    [[ -z "${MANIFEST:-}" ]] || args+=(--manifest "$MANIFEST")
fi
exec python3 "$ROOT/tools/run_cpu_baselines.py" "${args[@]}"
