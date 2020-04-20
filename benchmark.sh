#! /bin/bash

# Produce a compilable C source file with xxd
# containing the data from stdin
just_xxd() {
  echo '#include <stdint.h>'
  echo '#include <stdlib.h>'
  echo 'const uint8_t myfile[] = {'
  xxd -i
  echo '};'
  echo 'const size_t myfile_len = sizeof(myfile) - 1;';
}

# Produce a compilable C source file with bin2c
# containing the data from stdin
just_bin2c() {
  build/bin2c myfile
}

# Used in the benchmarks to test compilation times.
compile_from() {
  # compile_from C...
  "$@" | "$CC" -std=c89 -x c -c - -o /dev/stdout
}

# Run a benchmark; store the measurements in the
# benchmark file and print info to stderr.
#
# Because this uses perf internally, we need to fork
# a new process. The trick we use is to just recursively
# call this shell script, injecting the command to execute…
bench() {
  local impl="$1"; shift

  echo -n >&2 "Benchmark $impl..."

  perf stat -o "$tmpdir/stat" bash "$exe" "$@"
  local tim="$(< "$tmpdir/stat" awk '/seconds time elapsed/ { print($1); }')"

  echo >&2 "$tim"

  if test -n "$bench_results_file"; then
    echo "$impl" "$bench_len" "$tim" >> "$bench_results_file"
  fi
}

# Run the benchmarks. Runs until you quit this manually.
#
# SYNOPSIS: bash ./benchmark.sh [benchmark [results_file]]
benchmark() {
  bench_len=100000000 # 100MB – Length of random file to encode
  bench_results_file="$1"
  test -n "$1" || bench_results_file="${tmpdir}/results"

  local tmp_entropy="${tmpdir}/dummy_entropy"
  local tmp_out="${tmpdir}/dummy" # Temp files
  local tmp_xxd="${tmpdir}/dummy_xxd.c"
  local tmp_bin2c="${tmpdir}/dummy_bin2c.c"

  while true; do
    dd if=/dev/urandom of="$tmp_entropy" bs="$bench_len" count=1 2>/dev/null

    ##################
    # Benchmark raw processing speed (data -> c source code)

    bench bin2c \
      <"$tmp_entropy" just_bin2c > "$tmp_bin2c"
    bench xxd \
      <"$tmp_entropy" just_xxd > "$tmp_xxd"

    ###################
    # Benchmark compilation speed (data -> object file)

    # Using ld to produce the object
    bench compile_ld \
      ld -r -b binary "$tmp_entropy" -o "$tmp_out"

    # Using a C compiler to produce the object
    local CC
    for CC in gcc clang; do
      export CC

      bench "bin2c_${CC}_baseline" \
        <"$tmp_bin2c" compile_from cat >/dev/null
      bench "xxd_${CC}_baseline" \
        <"$tmp_xxd" compile_from cat >/dev/null
      bench "bin2c_${CC}" \
        <"$tmp_entropy" compile_from just_bin2c >/dev/null
      bench "xxd_${CC}" \
        <"$tmp_entropy" compile_from just_xxd  >/dev/null
    done
  done
}

# Evaluate the benchmark results
#
# SYNOPSIS: bash ./benchmark.sh [benchmark [results_file]]
evaluate() {
  local sorted="${tmpdir}/results_sorted"

  awk '
    {
      mb[$1] += $2/1e6;
      time[$1] += $3;
    }
    END {
      for (topic in mb)
        print(topic, mb[topic] / time[topic], "Mb/s");
    }' > "$sorted"

  {
    grep -vP 'ld|gcc|clang' < "$sorted" | sort -k2n
    echo
    grep gcc < "$sorted" | sort -k2n
    echo
    grep clang < "$sorted" | sort -k2n
    echo
    grep ld < "$sorted" | sort -k2n
  } | column -tLR 2
}

bin2c_clean() {
  if test -n "$bench_results_file"; then
    echo >&2
    echo >&2
    evaluate < "$bench_results_file" >&2
  fi

  if test -n "$owns_tmpdir"; then
    rm -R "$tmpdir"
  fi
}

bin2c_init() {
  exe="$(readlink -f "$0")"
  cd "$(dirname "$0")"

  # exit from loop
  trap "exit" SIGINT SIGTERM

  # Dealing with temp files
  if test -z "$BIN2C_BENCH_TMPDIR"; then
    export BIN2C_BENCH_TMPDIR="/tmp/bin2c-bench-"$(date +"%Y-%m-%d-%H:%M:%S")"-$RANDOM"
    mkdir -p "$BIN2C_BENCH_TMPDIR"
    owns_tmpdir=true
    trap bin2c_clean EXIT
  fi
  tmpdir="$BIN2C_BENCH_TMPDIR"

  # Command parsing; this is arbitrary code injection
  # as a service
  local cmd="$1"; shift
  test -n "$cmd" || cmd="benchmark"
  "$cmd" "$@"
}

bin2c_init "$@"