
#
# Run benchmarks, call deploy script
#

import os
import osproc
import strutils
import tables
import times

# the first argument is the commitish or the special value "test"

const
  benchmarks_dir = "benchmarks"
  bench_glob = benchmarks_dir.join_path("*.nim")
  cycles = 20
  sleep_time = 19_000 # ms

proc backup_timings() =
  for fname in walk_files(benchmarks_dir.join_path("*.csv")):
    echo "Backing up ", fname
    copyFile(fname, fname & ".bak")

proc restore_from_backup() =
  for bakname in walk_files(benchmarks_dir.join_path("*.csv.bak")):
    let fname = bakname[0..^5]
    echo "Restoring ", fname
    copyFile(fname & ".bak", fname)

proc list_benchmarks(): seq[string] =
  result = @[]
  for bench_name in walk_files(bench_glob):
    if bench_name.endswith("benchutils.nim"):
      continue
    result.add bench_name
  echo "Found $# benchmarks" % $result.len

proc compile_benchmarks(bench_names: seq[string]) =
  echo "Compiling benchmarks"
  for bench_name in bench_names:
    echo "Compiling ", bench_name
    discard execShellCmd("nim c -d:release $#" % bench_name)

proc run_benchmarks(commitish: string, bench_names: seq[string]) =
  var timings = initTable[string, float]()
  let tstamp = getGmTime(getTime())

  for cycle_cnt in 1..cycles:
    echo "Running cycle ", $cycle_cnt
    for bench_fname in bench_names:
      let bench_name = bench_fname[0..^5]
      echo "  Running $#" % bench_name
      let output = execProcess(bench_name)
      try:
        for line in output.split("\n"):
          echo "    $#" % line

        let timing = output.split("\n")[^2].parseFloat
        echo "    Timing ", timing
        if bench_name in timings and timings[bench_name] > timing:
          timings[bench_name] = timing
        else:
          timings[bench_name] = timing

      except:
        echo "  Unhandled error"
        discard

    echo "Sleeping"
    sleep(sleep_time)

  for n, t in timings.pairs:
    let f = open(n & ".csv", fmAppend)
    f.write("$#,$#,$#\n" % [$tstamp, commitish, $t])
    f.close()

var commitish = "test"
if paramCount() > 0:
  commitish = paramStr(1)

backup_timings()
let bench_names = list_benchmarks()
compile_benchmarks(bench_names)
run_benchmarks(commitish, bench_names)

discard execShellCmd("./generate_bench_page")

if commitish == "test":
  restore_from_backup()
else:
  discard execShellCmd("./deploy")
