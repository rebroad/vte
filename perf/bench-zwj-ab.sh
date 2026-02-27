#!/usr/bin/env bash
set -euo pipefail

# End-to-end A/B benchmark for ZWJ/grapheme rendering changes.
# Usage:
#   perf/bench-zwj-ab.sh [OLD_REF] [NEW_REF]
# Example:
#   perf/bench-zwj-ab.sh 631e6cf86b05c61ca1792b1bba020f34f8d82dc2 HEAD
#
# Env knobs:
#   RUNS=12                 number of timed runs per revision
#   APP=gtk3|gtk4           which test app to benchmark (default: gtk3)
#   WIDTH=220 HEIGHT=70     terminal geometry in chars
#   LINES=8000              workload size (lines)
#   KEEP_WORKTREES=1        don't delete temp worktrees
#   FRAME_DEBUG=1           enable GDK frame debug logs
#   USE_LOCAL_SUBPROJECTS=1 copy local subprojects into worktrees to avoid re-cloning

OLD_REF="${1:-631e6cf86b05c61ca1792b1bba020f34f8d82dc2}"
NEW_REF="${2:-HEAD}"
RUNS="${RUNS:-12}"
APP="${APP:-gtk3}"
WIDTH="${WIDTH:-220}"
HEIGHT="${HEIGHT:-70}"
BENCH_LINES="${BENCH_LINES:-8000}"
KEEP_WORKTREES="${KEEP_WORKTREES:-0}"
FRAME_DEBUG="${FRAME_DEBUG:-0}"
USE_LOCAL_SUBPROJECTS="${USE_LOCAL_SUBPROJECTS:-1}"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi
if ! command -v meson >/dev/null 2>&1; then
  echo "meson is required" >&2
  exit 1
fi
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja is required" >&2
  exit 1
fi
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run is required (install xvfb)" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Refusing to run with staged/unstaged tracked changes." >&2
  echo "Commit or stash first." >&2
  exit 1
fi

tmp_base="$(mktemp -d "${TMPDIR:-/tmp}/vte-bench-ab.XXXXXX")"
out_dir="$repo_root/perf/out"
mkdir -p "$out_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
csv="$out_dir/zwj-ab-$stamp.csv"
summary="$out_dir/zwj-ab-$stamp.summary.txt"
workload="$tmp_base/workload.txt"

cleanup() {
  if [[ "$KEEP_WORKTREES" != "1" ]]; then
    git worktree remove -f "$tmp_base/old" >/dev/null 2>&1 || true
    git worktree remove -f "$tmp_base/new" >/dev/null 2>&1 || true
    rm -rf "$tmp_base"
  else
    echo "Keeping temp trees: $tmp_base"
  fi
}
trap cleanup EXIT

echo "Creating workload ($BENCH_LINES lines)..."
: > "$workload"
for _ in $(seq 1 "$BENCH_LINES"); do
  printf '👨‍👩‍👧‍👦 🇺🇸🏳️‍🌈 🧑🏽‍💻 café देवनागरी 한글\n' >> "$workload"
done

add_tree() {
  local ref="$1"
  local dir="$2"
  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    git worktree remove -f "$dir" >/dev/null 2>&1 || true
  fi
  git worktree add --detach "$dir" "$ref" >/dev/null
}

setup_build() {
  local tree="$1"
  local build="$tree/build-bench"
  if [[ ! -f "$build/build.ninja" ]]; then
    meson setup "$build" "$tree" >/dev/null
  fi
}

seed_subprojects() {
  local tree="$1"
  local name src dst
  [[ "$USE_LOCAL_SUBPROJECTS" == "1" ]] || return 0
  for name in simdutf fmt fast_float; do
    src="$repo_root/subprojects/$name"
    dst="$tree/subprojects/$name"
    if [[ -d "$src" && ! -e "$dst" ]]; then
      echo "  Seeding subproject $name from local checkout"
      cp -a "$src" "$dst"
    fi
  done
}

build_app() {
  local tree="$1"
  local target="$2"
  echo "  Building $target in $tree/build-bench ..."
  # Some older revisions may miss explicit deps from vte.cc to generated parser headers.
  # Build parser custom targets first so vte.cc can include parser-cmd.hh reliably.
  CCACHE_DISABLE=1 ninja -C "$tree/build-bench" \
    src/parser-c01.hh \
    src/parser-cmd.hh \
    src/parser-cmd-handlers.hh \
    src/parser-csi.hh \
    src/parser-dcs.hh \
    src/parser-esc.hh \
    src/parser-reply.hh \
    src/parser-sci.hh
  CCACHE_DISABLE=1 ninja -C "$tree/build-bench" "$target"
}

bench_revision() {
  local label="$1"
  local tree="$2"
  local app_bin="$3"
  local frame_env=""
  local frame_log=""
  local i elapsed rc

  for i in $(seq 1 "$RUNS"); do
    frame_env=""
    frame_log="/dev/null"
    if [[ "$FRAME_DEBUG" == "1" ]]; then
      frame_log="$out_dir/zwj-ab-$stamp.$label.run$i.frames.log"
      frame_env="GDK_DEBUG=frames"
    fi

    rm -f "$tmp_base/time.txt"
    set +e
    /usr/bin/time -f '%e' -o "$tmp_base/time.txt" \
      xvfb-run -a -s "-screen 0 1920x1080x24" \
      env $frame_env GDK_BACKEND=x11 \
      "$app_bin" \
      --geometry="${WIDTH}x${HEIGHT}" \
      -- bash -lc "cat '$workload'" \
      >/dev/null 2>"$frame_log"
    rc=$?
    set -e

    if [[ ! -s "$tmp_base/time.txt" ]]; then
      echo "Benchmark run failed to produce timing output: label=$label run=$i rc=$rc" >&2
      echo "See frame log: $frame_log" >&2
      exit 1
    fi

    elapsed="$(tr -d '\r' < "$tmp_base/time.txt" | awk 'NF { last=$0 } END { print last }')"
    if [[ ! "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "Invalid elapsed value: '$elapsed' (label=$label run=$i rc=$rc)" >&2
      echo "See frame log: $frame_log" >&2
      exit 1
    fi

    printf '%s,%s,%s\n' "$label" "$i" "$elapsed" >> "$csv"
  done
}

if [[ "$APP" == "gtk4" ]]; then
  app_rel="src/app/vte-2.91-gtk4"
else
  app_rel="src/app/vte-2.91"
fi

echo "Preparing worktrees..."
add_tree "$OLD_REF" "$tmp_base/old"
add_tree "$NEW_REF" "$tmp_base/new"
seed_subprojects "$tmp_base/old"
seed_subprojects "$tmp_base/new"

echo "Configuring builds..."
setup_build "$tmp_base/old"
setup_build "$tmp_base/new"

echo "Building benchmark app ($APP)..."
build_app "$tmp_base/old" "$app_rel"
build_app "$tmp_base/new" "$app_rel"

old_sha="$(git -C "$tmp_base/old" rev-parse --short HEAD)"
new_sha="$(git -C "$tmp_base/new" rev-parse --short HEAD)"

echo "label,run,elapsed_s" > "$csv"
echo "Running OLD ($old_sha)..."
bench_revision "old-$old_sha" "$tmp_base/old" "$tmp_base/old/build-bench/$app_rel"
echo "Running NEW ($new_sha)..."
bench_revision "new-$new_sha" "$tmp_base/new" "$tmp_base/new/build-bench/$app_rel"

awk -F, '
NR==1 { next }
{
  if (NF < 3)
    next
  key=$1
  if (key !~ /^(old|new)-/)
    next
  if ($3 !~ /^[0-9]+([.][0-9]+)?$/)
    next
  n[key]++
  sum[key]+=$3
  sumsq[key]+=$3*$3
}
END {
  for (k in n) {
    mean = sum[k]/n[k]
    var = (n[k] > 1) ? (sumsq[k] - (sum[k]*sum[k]/n[k]))/(n[k]-1) : 0
    sd = (var > 0) ? sqrt(var) : 0
    printf("%s runs=%d mean=%.4fs sd=%.4fs\n", k, n[k], mean, sd)
  }
}
' "$csv" | sort > "$summary"

echo
echo "Results:"
cat "$summary"
echo
echo "CSV:     $csv"
echo "Summary: $summary"
if [[ "$FRAME_DEBUG" == "1" ]]; then
  echo "Frame logs: $out_dir/zwj-ab-$stamp.*.frames.log"
fi
