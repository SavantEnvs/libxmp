#!/usr/bin/env bash
#
# mayhem/build.sh — build libxmp's libFuzzer harness (upstream's test-dev/libxmp_fuzz.c), a
# standalone reproducer, and the upstream development test suite (the oracle for mayhem/test.sh).
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Offline and re-runnable:
# libxmp has no third-party dependencies and CMake fetches nothing.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The library, instrumented: sanitizers + DWARF 3 + SanCov (fuzzer-no-link) so the fuzzed code
#    itself reports edges to the engine linked into the harness.
rm -rf build-mayhem
cmake -S . -B build-mayhem -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED=OFF \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" >/dev/null
cmake --build build-mayhem --target xmp_static -j"$MAYHEM_JOBS"
LIBXMP_A="$(find build-mayhem -maxdepth 2 -name 'libxmp*.a' | head -n1)"
[ -f "$LIBXMP_A" ] || { echo "build.sh: libxmp static library not found" >&2; exit 1; }

# 2) Harness (upstream's own, unmodified) twice: libFuzzer + standalone run-once driver.
#    HAVE_FMEMOPEN enables the depacker (xmp_test_module_from_file) half of the harness.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-mayhem/lsan_off.o
HFLAGS=(-DLIBXMP_LIBFUZZER -DHAVE_FMEMOPEN -I"$SRC/include" -I"$SRC/src" -O1)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${HFLAGS[@]}" $LIB_FUZZING_ENGINE \
    "$SRC/test-dev/libxmp_fuzz.c" "$LIBXMP_A" build-mayhem/lsan_off.o -lm \
    -o /mayhem/libxmp_fuzz
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${HFLAGS[@]}" "$STANDALONE_FUZZ_MAIN" \
    "$SRC/test-dev/libxmp_fuzz.c" "$LIBXMP_A" build-mayhem/lsan_off.o -lm \
    -o /mayhem/libxmp_fuzz-standalone

# 3) Upstream's development test suite (test-dev/), normal flags, no sanitizers: a separate tree.
rm -rf build-tests
cmake -S . -B build-tests -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED=OFF -DWITH_UNIT_TESTS=ON \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" >/dev/null
cmake --build build-tests --target libxmp-tests-dev -j"$MAYHEM_JOBS"
