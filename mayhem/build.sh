#!/usr/bin/env bash
#
# trustfall/mayhem/build.sh — build obi1kenobi/trustfall's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (base-builder-rust `compile` + `cargo fuzz build -O`).
#
# trustfall is a datasource-agnostic query engine. The fuzzed code is its `trustfall_core` crate — the
# query FRONTEND (GraphQL-like query string -> parsed document -> compiled IR via
# trustfall_core::frontend::parse_doc) and the interpreter's adapter-batching path. Its UPSTREAM fuzz
# crate (trustfall_core-fuzz, libfuzzer-sys 0.4, path dep on ../=trustfall_core) is a clean, modern
# cargo-fuzz crate that builds directly under the image nightly, so we build it AS-IS and DO NOT touch
# it (the integration stays purely additive; everything we add lives under mayhem/). It ships three
# fuzzers:
#   frontend, frontend_numbers, adapter_batching
# The old fork shipped only frontend + frontend_numbers; we expose all three, each at /mayhem/<target>.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem runs
#     it directly via `libfuzzer: true`, and it also runs once on a single input file as a reproducer);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is what OSS-Fuzz's `compile`
#     sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Build upstream's own cargo-fuzz crate (lives under trustfall_core/). Discover every target from its
# fuzz_targets/ dir so the set stays in lock-step with upstream (a new upstream fuzzer is picked up
# automatically on sync). Targets can be a bare <name>.rs or a <name>/mod.rs subdir.
#
# DELIBERATELY DROPPED: adapter_batching. Its harness embeds a hand-written test fixture
# (fuzz_targets/adapter_batching/numbers_adapter.rs) that is INCOMPLETE — several edges/coercions are
# `unimplemented!()` (e.g. resolve_neighbors, resolve_coercion). The seeds it loads are upstream's own
# `test_data/tests/valid_queries` for the numbers schema, and those valid queries traverse the
# unimplemented edges, so the target panics deterministically within seconds on its own valid seed.
# The crash is in the fixture, NOT in trustfall_core, so it finds nothing real. Completing the fixture
# would mean editing upstream's fuzz file (breaks the clean-additive invariant) or reimplementing the
# full numbers adapter; not worth it for a target the old fork never shipped (parity only requires
# frontend + frontend-numbers). So we skip it here and ship no Mayhemfile for it.
FUZZ_DIR="trustfall_core/fuzz"
SKIP_TARGETS=" adapter_batching "
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  [ -e "$f" ] || continue
  name="$(basename "${f%.*}")"
  [[ "$SKIP_TARGETS" == *" $name "* ]] && { echo "skipping dropped target: $name"; continue; }
  FUZZ_TARGETS+=("$name")
done
for d in "$FUZZ_DIR"/fuzz_targets/*/; do
  [ -e "$d/mod.rs" ] || continue
  name="$(basename "$d")"
  [[ "$SKIP_TARGETS" == *" $name "* ]] && { echo "skipping dropped target: $name"; continue; }
  FUZZ_TARGETS+=("$name")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cdebuginfo=1 -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's Rust build (catches overflow/debug
# asserts during fuzzing). Use the image's DEFAULT toolchain (the Dockerfile pins it to the required
# nightly); a `+toolchain` override would make rustup try to install a different channel into the
# read-only shared /opt/rust. Build per-target so a single bad target doesn't mask the others.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_TARGETS[@]}" 2>&1 || true
