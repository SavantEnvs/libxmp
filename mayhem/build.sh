#!/usr/bin/env bash
#
# mayhem/build.sh — build libxmp (autotools-era tree, no CMake) with a libFuzzer harness over the
# public API, a standalone reproducer, and upstream's development test suite (test-dev/, the oracle
# for mayhem/test.sh). Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
# Offline and re-runnable: libxmp has no third-party dependencies and nothing is fetched.
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
#    itself reports edges to the engine linked into the harness. Compiled directly (the tree ships

rm -rf build-mayhem
mkdir -p build-mayhem/obj
export LIBFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -w -Iinclude -Isrc \
  -DBUILDING_STATIC -D_REENTRANT -DHAVE_ALLOCA_H -DHAVE_DIRENT_H -DHAVE_POPEN -DHAVE_MKSTEMP \
  -DHAVE_FNMATCH -DHAVE_UMASK -DHAVE_ROUND -DHAVE_POWF"
make -s -f - print <<'MK' | tr ' ' '\n' | sed 's/\.o$/.c/' | grep . \
  | xargs -P"$MAYHEM_JOBS" -I{} sh -c 'o=build-mayhem/obj/$(echo "{}" | sed "s|/|_|g; s|\.c\$|.o|"); $CC $LIBFLAGS -c "{}" -o "$o"'
OBJS :=
include src/Makefile
include src/loaders/Makefile
include src/loaders/prowizard/Makefile
include src/depackers/Makefile
print: ; @echo $(OBJS) $(PROWIZARD_OBJS) $(DEPACKER_OBJS)
MK
LIBXMP_A="$SRC/build-mayhem/libxmp.a"
ar rcs "$LIBXMP_A" build-mayhem/obj/*.o

# 2) Harness twice: libFuzzer + standalone run-once driver.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-mayhem/lsan_off.o
HFLAGS=(-I"$SRC/include" -O1)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${HFLAGS[@]}" $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/libxmp_fuzz.c" "$LIBXMP_A" build-mayhem/lsan_off.o -lm \
    -o /mayhem/libxmp_fuzz
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${HFLAGS[@]}" "$STANDALONE_FUZZ_MAIN" \
    "$SRC/mayhem/libxmp_fuzz.c" "$LIBXMP_A" build-mayhem/lsan_off.o -lm \
    -o /mayhem/libxmp_fuzz-standalone

# 3) Upstream's development test suite (test-dev/), the project's normal flags, no sanitizers.
#    Both configure runs and the objects stay in the (gitignored) autotools outputs.
rm -f lib/libxmp.a
autoconf -Wnone
CFLAGS="$COVERAGE_FLAGS" ./configure --enable-static --disable-shared >/dev/null
make -j"$MAYHEM_JOBS" static >/dev/null
cd test-dev
autoconf -Wnone
CFLAGS="$COVERAGE_FLAGS" ./configure >/dev/null
make -j"$MAYHEM_JOBS" libxmp-tests >/dev/null
