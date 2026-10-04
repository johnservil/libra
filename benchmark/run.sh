#!/usr/bin/env bash

# End-to-end CLI benchmark runner. The measured command always uses a binary
# built from the selected Libra revision; fixture construction and builds are
# deliberately outside the timing boundary.
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
readonly DEFAULT_SCENARIOS=(status_clean status_dirty log_history rev_list_refs fsck_history add_all)

revision="HEAD"
binary_override=""
control_binary_override="${LIBRA_BENCHMARK_CONTROL_BINARY:-}"
output=""
runs=10
warmup=3
file_count=5000
history_count=1000
ref_count=10000
keep_workspace=false
object_format=""
declare -a selected_scenarios=()

usage() {
    cat <<'EOF'
Usage: benchmark/run.sh [options]

Build the selected Libra revision in an isolated directory, create matching
fixtures with that binary, and write a JSON result file.

Options:
  --revision <rev>       Libra revision to benchmark (default: HEAD).
  --binary <path>        Measure an existing binary; skips source export/build.
  --control-binary <p>   Compatible Libra used to resolve/export --revision.
  --scenario <name>      Run one scenario (repeatable). Defaults to all.
                         status_clean, status_dirty, log_history,
                         rev_list_refs, fsck_history, add_all
  --runs <n>             Recorded runs per scenario (default: 10).
  --warmup <n>           Unrecorded runs per scenario (default: 3).
  --file-count <n>       Files in each status and add fixture (default: 5000).
  --object-format <f>    Object format of every fixture: sha1, sha256, or
                         blake3 (default: libra init's).
  --history-count <n>    Commits in history fixtures (default: 1000).
  --ref-count <n>        Refs in the rev-list fixture (default: 10000).
  --output <path>        Result JSON path (default: benchmark/results/...).
  --keep-workspace       Keep the isolated source, binary, and fixtures.
  -h, --help             Show this help.

Examples:
  benchmark/run.sh
  benchmark/run.sh --revision a0567ce --runs 20 --warmup 5
  benchmark/run.sh --scenario log_history --revision v0.18.84
EOF
}

die() {
    printf 'benchmark: %s\n' "$*" >&2
    exit 1
}

require_value() {
    [[ $# -eq 2 && -n "$2" ]] || die "$1 requires a value"
}

require_positive_integer() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer"
}

require_nonnegative_integer() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer"
}

json_escape() {
    perl -pe 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g; s/\n/\\\\n/g'
}

now_ms() {
    perl -MTime::HiRes=time -e 'printf "%.3f", time() * 1000'
}

median() {
    sort -n "$1" | awk '
        { values[NR] = $1 }
        END {
            if (NR == 0) exit 1
            if (NR % 2) printf "%.3f", values[(NR + 1) / 2]
            else printf "%.3f", (values[NR / 2] + values[(NR / 2) + 1]) / 2
        }'
}

mean() {
    awk '{ sum += $1 } END { if (NR == 0) exit 1; printf "%.3f", sum / NR }' "$1"
}

minimum() {
    sort -n "$1" | head -n 1
}

maximum() {
    sort -n "$1" | tail -n 1
}

parse_rss_bytes() {
    local timing_file="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        awk '/maximum resident set size/ { print $1; exit }' "$timing_file"
    else
        awk -F: '/Maximum resident set size/ { gsub(/^[[:space:]]+/, "", $2); print $2 * 1024; exit }' "$timing_file"
    fi
}

run_in_repository() {
    local repository="$1"
    shift
    (
        cd "$repository"
        "$benchmark_binary" --no-pager "$@"
    )
}

run_setup_in_repository() {
    run_in_repository "$@" >/dev/null
}

create_base_repository() {
    local repository="$1"
    "$benchmark_binary" init --quiet --vault false ${object_format:+--object-format "$object_format"} "$repository"
    run_setup_in_repository "$repository" config set user.name "Libra Benchmark"
    run_setup_in_repository "$repository" config set user.email "benchmark@libra.local"
}

create_status_fixture() {
    local repository="$1"
    local state="$2"
    local index dirty_count file
    create_base_repository "$repository"
    mkdir -p "$repository/files"
    for ((index = 1; index <= file_count; index += 1)); do
        printf -v file 'files/file-%05d.txt' "$index"
        printf 'fixture file %s\n' "$index" > "$repository/$file"
    done
    run_setup_in_repository "$repository" add files
    run_setup_in_repository "$repository" commit --no-gpg-sign -m "benchmark status fixture"

    if [[ "$state" == "dirty" ]]; then
        dirty_count=$file_count
        ((dirty_count > 10)) && dirty_count=10
        for ((index = 1; index <= dirty_count; index += 1)); do
            printf -v file 'files/file-%05d.txt' "$index"
            printf 'dirty fixture change %s\n' "$index" >> "$repository/$file"
        done
    fi
}

# A fresh repository with --file-count untracked files of a source tree's
# sizes: lengths cycle through 512 B to 64 KiB (mean about 10 KB, as git's
# own tree), so `libra add .` hashes and stores each one.
create_add_fixture() {
    local repository="$1"
    local index file size
    local -a sizes=(512 1500 3000 6000 12000 24000 3000 1500 6000 48000 700 9000 65536 2000 4000 16000)
    create_base_repository "$repository"
    mkdir -p "$repository/files"
    for ((index = 1; index <= file_count; index += 1)); do
        printf -v file 'files/file-%05d.txt' "$index"
        size=${sizes[$((index % ${#sizes[@]}))]}
        yes "add fixture line of file $index" | head -c "$size" > "$repository/$file"
    done
}

create_history_fixture() {
    local repository="$1"
    local index
    create_base_repository "$repository"
    for ((index = 1; index <= history_count; index += 1)); do
        printf 'history revision %s\n' "$index" > "$repository/history.txt"
        run_setup_in_repository "$repository" add history.txt
        run_setup_in_repository "$repository" commit --no-gpg-sign -m "benchmark history $index"
    done
}

create_refs_fixture() {
    local repository="$1"
    local index head
    create_base_repository "$repository"
    printf 'reference fixture\n' > "$repository/refs.txt"
    run_setup_in_repository "$repository" add refs.txt
    run_setup_in_repository "$repository" commit --no-gpg-sign -m "benchmark refs fixture"
    head="$(run_in_repository "$repository" rev-parse HEAD)"
    for ((index = 1; index <= ref_count; index += 1)); do
        run_setup_in_repository "$repository" update-ref "refs/heads/benchmark/ref-$index" "$head"
    done
}

fixture_for() {
    local scenario="$1"
    local fixture="$workspace/fixtures/$scenario"
    if [[ -d "$fixture" ]]; then
        printf '%s\n' "$fixture"
        return
    fi
    mkdir -p "$(dirname "$fixture")"
    case "$scenario" in
        status_clean) create_status_fixture "$fixture" clean ;;
        status_dirty) create_status_fixture "$fixture" dirty ;;
        log_history | fsck_history) create_history_fixture "$fixture" ;;
        rev_list_refs) create_refs_fixture "$fixture" ;;
        add_all) create_add_fixture "$fixture" ;;
        *) die "unknown scenario: $scenario" ;;
    esac
    printf '%s\n' "$fixture"
}

scenario_command() {
    case "$1" in
        status_clean | status_dirty) printf '%s\n' 'status --short' ;;
        log_history) printf '%s\n' 'log --oneline' ;;
        rev_list_refs) printf '%s\n' 'rev-list --all --count' ;;
        fsck_history) printf '%s\n' 'fsck' ;;
        add_all) printf '%s\n' 'add .' ;;
        *) die "unknown scenario: $1" ;;
    esac
}

measure_once() {
    local repository="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    shift 3
    local started ended elapsed exit_code rss
    started="$(now_ms)"
    set +e
    (
        cd "$repository"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            /usr/bin/time -l "$benchmark_binary" --no-pager "$@" >"$stdout_file" 2>"$stderr_file"
        else
            /usr/bin/time -v "$benchmark_binary" --no-pager "$@" >"$stdout_file" 2>"$stderr_file"
        fi
    )
    exit_code=$?
    set -e
    ended="$(now_ms)"
    elapsed="$(awk -v start="$started" -v end="$ended" 'BEGIN { printf "%.3f", end - start }')"
    rss="$(parse_rss_bytes "$stderr_file")"
    [[ -n "$rss" ]] || rss=0
    printf '%s,%s,%s\n' "$elapsed" "$rss" "$exit_code"
}

run_scenario() {
    local scenario="$1"
    local repository command stdout_file stderr_file sample elapsed rss exit_code
    local timing_file="$workspace/$scenario.elapsed-ms"
    local rss_file="$workspace/$scenario.rss-bytes"
    repository="$(fixture_for "$scenario")"
    command="$(scenario_command "$scenario")"
    read -r -a command_parts <<< "$command"
    : > "$timing_file"
    : > "$rss_file"

    printf 'benchmark: %s (%s)\n' "$scenario" "$command" >&2
    for ((sample = 1; sample <= warmup + runs; sample += 1)); do
        stdout_file="$workspace/$scenario-$sample.stdout"
        stderr_file="$workspace/$scenario-$sample.stderr"
        run_repository="$repository"
        if [[ "$scenario" == add_all ]]; then
            # `add` changes the repository: each sample starts from a fresh copy, made untimed.
            run_repository="$workspace/add-run"
            rm -rf "$run_repository"
            cp -a "$repository" "$run_repository"
        fi
        IFS=, read -r elapsed rss exit_code < <(measure_once "$run_repository" "$stdout_file" "$stderr_file" "${command_parts[@]}")
        if [[ "$exit_code" != "0" ]]; then
            cat "$stderr_file" >&2
            die "$scenario failed on sample $sample with exit code $exit_code"
        fi
        if ((sample > warmup)); then
            printf '%s\n' "$elapsed" >> "$timing_file"
            printf '%s\n' "$rss" >> "$rss_file"
        fi
    done

    cat > "$scenario_results/$scenario.json" <<EOF
    {
      "scenario":"$(printf '%s' "$scenario" | json_escape)",
      "command":"$(printf '%s' "$command" | json_escape)",
      "samples":$runs,
      "elapsed_ms":{"min":$(minimum "$timing_file"),"median":$(median "$timing_file"),"mean":$(mean "$timing_file"),"max":$(maximum "$timing_file")},
      "max_rss_bytes":{"min":$(minimum "$rss_file"),"median":$(median "$rss_file"),"mean":$(mean "$rss_file"),"max":$(maximum "$rss_file")}
    }
EOF
}

cleanup() {
    if [[ "${keep_workspace:-false}" == false && -n "${workspace:-}" && -d "$workspace" ]]; then
        rm -rf "$workspace"
    elif [[ -n "${workspace:-}" && -d "$workspace" ]]; then
        printf 'benchmark: preserved workspace: %s\n' "$workspace" >&2
    fi
}

while (($#)); do
    case "$1" in
        --revision)
            require_value "$1" "${2:-}"
            revision="$2"
            shift 2
            ;;
        --binary)
            require_value "$1" "${2:-}"
            binary_override="$2"
            shift 2
            ;;
        --control-binary)
            require_value "$1" "${2:-}"
            control_binary_override="$2"
            shift 2
            ;;
        --scenario)
            require_value "$1" "${2:-}"
            selected_scenarios+=("$2")
            shift 2
            ;;
        --output)
            require_value "$1" "${2:-}"
            output="$2"
            shift 2
            ;;
        --runs)
            require_value "$1" "${2:-}"
            require_positive_integer "$1" "$2"
            runs="$2"
            shift 2
            ;;
        --warmup)
            require_value "$1" "${2:-}"
            require_nonnegative_integer "$1" "$2"
            warmup="$2"
            shift 2
            ;;
        --file-count)
            require_value "$1" "${2:-}"
            require_positive_integer "$1" "$2"
            file_count="$2"
            shift 2
            ;;
        --history-count)
            require_value "$1" "${2:-}"
            require_positive_integer "$1" "$2"
            history_count="$2"
            shift 2
            ;;
        --ref-count)
            require_value "$1" "${2:-}"
            require_positive_integer "$1" "$2"
            ref_count="$2"
            shift 2
            ;;
        --object-format)
            require_value "$1" "${2:-}"
            object_format="$2"
            shift 2
            ;;
        --keep-workspace)
            keep_workspace=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

if ((${#selected_scenarios[@]} == 0)); then
    selected_scenarios=("${DEFAULT_SCENARIOS[@]}")
fi
for scenario in "${selected_scenarios[@]}"; do
    scenario_command "$scenario" >/dev/null
done

workspace="$(mktemp -d "${TMPDIR:-/tmp}/libra-benchmark.XXXXXX")"
trap cleanup EXIT
scenario_results="$workspace/scenarios"
mkdir -p "$scenario_results"
build_elapsed_ms=0
control_build_elapsed_ms=0

if [[ -n "$binary_override" ]]; then
    benchmark_binary="$(cd "$(dirname "$binary_override")" && pwd)/$(basename "$binary_override")"
    [[ -x "$benchmark_binary" ]] || die "--binary is not executable: $benchmark_binary"
    benchmark_revision="external-binary"
    binary_origin="override"
else
    control_binary=""
    if [[ -n "$control_binary_override" ]]; then
        control_binary="$(cd "$(dirname "$control_binary_override")" && pwd)/$(basename "$control_binary_override")"
        [[ -x "$control_binary" ]] || die "--control-binary is not executable: $control_binary"
        benchmark_revision="$(cd "$REPOSITORY_ROOT" && "$control_binary" rev-parse "$revision")" \
            || die "--control-binary could not resolve revision: $revision"
        control_binary_origin="override"
    elif command -v libra >/dev/null; then
        candidate_control_binary="$(command -v libra)"
        if benchmark_revision="$(cd "$REPOSITORY_ROOT" && "$candidate_control_binary" rev-parse "$revision" 2>/dev/null)"; then
            control_binary="$candidate_control_binary"
            control_binary_origin="path"
        fi
    fi
    if [[ -z "$control_binary" ]]; then
        control_build_started="$(now_ms)"
        (
            cd "$REPOSITORY_ROOT"
            CARGO_TARGET_DIR="$workspace/control-target" LIBRA_SKIP_WEB_BUILD=1 cargo build --release --locked
        )
        control_build_finished="$(now_ms)"
        control_build_elapsed_ms="$(awk -v start="$control_build_started" -v end="$control_build_finished" 'BEGIN { printf "%.3f", end - start }')"
        control_binary="$workspace/control-target/release/libra"
        [[ -x "$control_binary" ]] || die "control build did not produce a Libra binary"
        benchmark_revision="$(cd "$REPOSITORY_ROOT" && "$control_binary" rev-parse "$revision")" \
            || die "control build could not resolve revision: $revision"
        control_binary_origin="workspace-build"
    fi
    archive="$workspace/source.zip"
    source_dir="$workspace/source"
    mkdir -p "$source_dir"
    (
        cd "$REPOSITORY_ROOT"
        "$control_binary" archive --format zip --output "$archive" "$benchmark_revision"
    )
    command -v unzip >/dev/null || die "unzip is required to unpack the selected source revision"
    unzip -q "$archive" -d "$source_dir"
    build_started="$(now_ms)"
    (
        cd "$source_dir"
        CARGO_TARGET_DIR="$workspace/target" LIBRA_SKIP_WEB_BUILD=1 cargo build --release --locked
    )
    build_finished="$(now_ms)"
    build_elapsed_ms="$(awk -v start="$build_started" -v end="$build_finished" 'BEGIN { printf "%.3f", end - start }')"
    benchmark_binary="$workspace/target/release/libra"
    [[ -x "$benchmark_binary" ]] || die "release build did not produce a Libra binary"
    binary_origin="revision-build"
fi

if [[ -z "$output" ]]; then
    output="$REPOSITORY_ROOT/benchmark/results/${benchmark_revision:0:12}-$(date -u +%Y%m%dT%H%M%SZ).json"
fi
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"

for scenario in "${selected_scenarios[@]}"; do
    run_scenario "$scenario"
done

result_tmp="$output.tmp.$$"
{
    printf '{\n'
    printf '  "schema_version":1,\n'
    printf '  "revision":"%s",\n' "$(printf '%s' "$benchmark_revision" | json_escape)"
    printf '  "binary_origin":"%s",\n' "$binary_origin"
    printf '  "control_binary_origin":"%s",\n' "${control_binary_origin:-not-needed}"
    printf '  "control_build_elapsed_ms":%s,\n' "$control_build_elapsed_ms"
    printf '  "build_elapsed_ms":%s,\n' "$build_elapsed_ms"
    printf '  "runs":%s,\n' "$runs"
    printf '  "warmup_runs":%s,\n' "$warmup"
    printf '  "fixture_scale":{"files":%s,"history_commits":%s,"refs":%s},\n' "$file_count" "$history_count" "$ref_count"
    printf '  "object_format":"%s",\n' "${object_format:-default}"
    platform="$(uname -srm)"
    printf '  "platform":"%s",\n' "$(printf '%s' "$platform" | json_escape)"
    printf '  "scenarios":[\n'
    for scenario in "${selected_scenarios[@]}"; do
        [[ "$scenario" == "${selected_scenarios[0]}" ]] || printf ',\n'
        cat "$scenario_results/$scenario.json"
    done
    printf '\n  ]\n}\n'
} > "$result_tmp"
mv "$result_tmp" "$output"

printf 'benchmark result: %s\n' "$output"
