# Run benchmarks
# (c) 2023 Federico Ceratto - released under GPL-3.0

import os
import osproc
import strutils
import tables
import times

import std/[posix_utils, tempfiles, sequtils, parsecsv]
import std/strformat


const
  benchmarks_dir = "benchmarks"
  bench_glob = benchmarks_dir.join_path("*.nim")
  db_fn = "minimize.csv"
  tmpdb_fn = "minimize.tmp.csv"

proc list_benchmarks(): seq[string] =
  # List benchmarks without dir name and extension
  result = @[]
  for fname in walk_files(bench_glob):
    result.add fname.splitFile.name

  echo "Found $# benchmarks" % $result.len

proc bfname(bench_name: string): string =
  benchmarks_dir / bench_name & ".nim"

proc exec(cmd: string, workdir = ""): string {.discardable.} =
  let r = execCmdEx(cmd, workingDir = workdir)
  if r.exitCode != 0:
    echo &"#### ERROR executing {cmd} ####"
    echo r.output
    echo "---------------------"
    raise newException(CatchableError, "command failed")
  return r.output

# # Benchmarking # #

proc compile_benchmarks(bench_names: seq[string]): seq[string] =
  echo "Compiling benchmarks"
  for bench_name in bench_names:
    echo " Compiling ", bench_name
    let r = execCmdEx("nim c -d:danger $#" % bench_name.bfname)
    if r.exitCode == 0:
      result.add bench_name
    else:
      echo &"Failed to compile {bench_name.bfname}, skipping it"

type CC = Table[string, int]

proc parse_cachegrind_output(tmpfile: File): CC =
  var header: string
  var summary: string
  for line in tmpfile.lines:
    if line.startswith("events: "):
      header = line[8..^1].strip()
    elif line.startswith("summary: "):
      summary = line[8..^1].strip()

  for (k, v) in zip(header.split(), summary.split()):
    result[k] = parseInt(v)
  #return dict(zip(header.split(), [int(i) for i in last_line.split()]))

proc run_under_cachegrind(bench_fname: string): CC =
  ## Run the the given program and arguments under Cachegrind, parse the
  ## Cachegrind output.
  let
    arch = uname().machine
    (tmpfile, tmp_fname) = createTempFile("cachegrind_", ".tmp")
    # Disable ASLR
    # Set some reasonable L1 and LL values, based on Haswell. You can set
    # your own, important part is that they are consistent across runs,
    # instead of the default of copying from the current machine.
    cmd = @[
      "setarch",
      arch,
      "-R",
      "valgrind",
      "--tool=cachegrind",
      "--I1=32768,8,64",
      "--D1=32768,8,64",
      "--LL=8388608,16,64",
      "--cachegrind-out-file=" & tmp_fname,
      bench_fname
    ]
    r = execCmdEx(cmd.join(" "))
  if r.exitCode == 0:
    result = parse_cachegrind_output(tmpfile)
    removeFile(tmp_fname)

type
  Summary = tuple[l1_hits, l3_hits, ram_hits, score: int]
  Datapoint = tuple[commitish: string, commit_epoch: int, os, architecture,
      bench_name: string, l1_hits, l3_hits, ram_hits, score: int]
  Datapoints = seq[Datapoint]

proc extract_score(d: CC): Summary =
  ## We pretend there's no L2 since Cachegrind doesn't currently support it.
  ## Caveats: we're not including time to process instructions, only time to
  ## access instruction cache(s), so we're assuming time to fetch and run_with_cachegrind
  ## instruction is the same as time to retrieve data if they're both to L1
  ## cache.
  let
    ram_hits = d["DLmr"] + d["DLmw"] + d["ILmr"]
    l3_hits = d["I1mr"] + d["D1mw"] + d["D1mr"] - ram_hits
    total_memory_rw = d["Ir"] + d["Dr"] + d["Dw"]
    l1_hits = total_memory_rw - l3_hits - ram_hits
    score = l1_hits + 5 * l3_hits + 35 * ram_hits

  (l1_hits, l3_hits, ram_hits, score)

proc run_benchmarks(commitish: string, commit_epoch: int, bench_names: seq[
    string]): Datapoints =
  result = @[]
  #let tstamp = now().utc
  for bench_name in bench_names:
    echo "  Running $#" % bench_name
    try:
      let
        bin_fname = benchmarks_dir / bench_name
        stats = run_under_cachegrind(bin_fname)
        (l1_hits, l3_hits, ram_hits, score) = extract_score(stats)
        os = "linux"
        architecture = uname().machine
      result.add (commitish, commit_epoch, os, architecture, bench_name,
          l1_hits, l3_hits, ram_hits, score)

    except:
      echo "Unhandled error"


# # DB # #

const hdr = "commitish,commit_epoch,os,architecture,bench_name,bench_datetime,l1_hits,l3_hits,ram_hits,score"

func to_line(row: Datapoint): string =
  [row.commitish, $row.commit_epoch, row.os, row.architecture, row.bench_name,
      $row.l1_hits, $row.l3_hits, $row.ram_hits, $row.score].join(",") & "\n"

iterator db_scan(fn: string, bench_name: string): Datapoint =
  var p: CsvParser
  p.open(fn)
  p.readHeaderRow()
  assert p.headers == hdr.split(',')
  while p.readRow():
    #for col in items(p.headers):
    #  echo "##", col, ":", p.rowEntry(col), "##"
    let row = p.row
    let dp: Datapoint = (row[0], row[1].parseInt, row[2], row[3],
          row[4], row[5].parseInt, row[6].parseInt, row[7].parseInt, row[8].parseInt)
    if bench_name == "" or bench_name == dp.bench_name:
      yield dp

  p.close()

proc write_tmp_db(dps: Datapoints) =
  let f = open(tmpdb_fn, fmWrite)
  var cnt = 0
  f.write(hdr & "\n")
  for dp in dps:
    f.write(dp.to_line())
    inc cnt

  f.close()
  echo &"{tmpdb_fn} written. {cnt} datapoints"

proc update_db() =
  ## Append data from tmp db to persistent db
  let outf = open(db_fn, fmAppend)
  if outf.getFilePos() == 0:
    outf.write(hdr & "\n")
  var cnt = 0
  echo &"Reading {tmpdb_fn}"
  for dp in db_scan(tmpdb_fn, ""):
    outf.write(dp.to_line())
    inc cnt

  outf.close()
  echo &"{db_fn} written. {cnt} new datapoints"
  # removeFile(tmpdb_fn)



# # Charting # #

const chart_baseurl = "https://github.com/FedericoCeratto/minimize/blob/master/"

type
  ChartBar = tuple[date, github_commit: string, height: int, value: float]
  Chart* = object
    title*: string
    srcurl*: string
    bars*: seq[ChartBar]

include "bench_page.tmpl" # provides generateHTMLPage

proc generate_chart(bench_name: string, dps: Datapoints): Chart =
  var barcnt = 0
  var c = Chart(title: bench_name, bars: @[])
  c.srcurl = chart_baseurl & c.title & ".nim"
  let max_value = dps.mapIt(it.score).max()

  for dp in dps:
    barcnt.inc
    let
      date = ""
      github_commit = dp.commitish
      value = dp.score
      height = int(200 * value / max_value)
      r: ChartBar = (date, dp.commitish, height, value.float)
    c.bars.add r
  return c


proc generate_charts(bench_names: seq[string]): seq[Chart] =
  for bench_name in bench_names:
    let dps = toSeq db_scan(db_fn, bench_name)
    echo &"Fetched data for {bench_name}: {dps.len} datapoints"

    let c = generate_chart(bench_name, dps)
    result.add c

proc gen_bench_page*(bench_names: seq[string]) =
  echo &"Reading {db_fn}"
  let tstamp = $now().utc
  let
    charts = generate_charts(bench_names)
    page = generateHTMLPage(charts, tstamp)
  echo "Writing output to minimize.html"
  let f = open("minimize.html", fmWrite)
  f.writeLine(page)


proc gen_table*(bench_names: seq[string]) =
  echo &"Reading {db_fn}"
  const fn = "summary.md"
  var tbl: seq[string] = @[
    "| Bench name             | Change                |",
    "| ---                    | ---                   |",
  ]
  for bench_name in bench_names:
    let dps = toSeq db_scan(db_fn, bench_name)
    if dps.len < 2:
      continue
    let
      last = dps[dps.high]
      prev = dps[dps.high-1]
      change = (last.score - prev.score) / prev.score * 100
    if change > 1:
      tbl.add &"| {bench_name:22} | {change:8.2f}% slowdown    |"
    elif change < -1:
      tbl.add &"| {bench_name:22} | {-change:8.2f}% improvement |"

  echo &"Writing {fn}"
  if tbl.len > 2:
    fn.write_file(tbl.join("\n") & "\n")
  else:
    fn.write_file("No significant performance changes\n")



# # main # #

proc bench() =
  let
    commitish =
      if paramCount() > 1:
        paramStr(2)
      else:
        exec("git rev-parse HEAD").strip

    commit_epoch =
      if paramCount() > 2:
        paramStr(3).parseInt
      else:
        exec("""git --no-pager log -1 --format="%at" """).strip.parseInt

    bench_names = list_benchmarks()
    compiled_bnames = compile_benchmarks(bench_names)
    outcome = run_benchmarks(commitish, commit_epoch, compiled_bnames)
  write_tmp_db(outcome)


iterator sample(li: seq[string], samples: int): (string, int) =
  let jump = int(li.len / samples)
  for n in 0..<samples:
    let x = li[n * jump].split
    yield (x[0], x[1].parseInt)

  let x = li[li.high].split
  yield (x[0], x[1].parseInt)


proc rebuild_db() =
  # Assume minimize is being run from its own repo checked out under the
  # Nim repo
  let
    since = "2022-06-01"
    samples = 20 #FIXME
    cmd = &"git log --format='%H %at' --since='{since}'"
    li = exec(cmd, workdir = "../").strip.splitLines
    bench_names = list_benchmarks()
    mdir = getCurrentDir()

  echo &"{li.len} Nim commits listed"
  var cnt = 0
  for commitish, commit_epoch in sample(li, samples):
    echo &"\n### Building Nim {commitish} {commit_epoch} ###\n"
    try:
      setCurrentDir(mdir)
      setCurrentDir("../")
      exec(&"git checkout {commitish}")
      echo "Compiling koch"
      exec("./bin/nim c koch", )
      echo "Compiling nim"
      exec("./koch boot -d:release -d:nimStrictMode --lib:lib")
      echo "Nim compiler ready"
      setCurrentDir(mdir)
      let compiled_bnames = compile_benchmarks(bench_names)
      let outcome = run_benchmarks(commitish, commit_epoch, compiled_bnames)
      write_tmp_db(outcome)
      inc cnt
    except:
      echo "Run failed, ignoring it"

  setCurrentDir(mdir)
  discard exec("git checkout devel", workdir = "../")
  echo &"completed {cnt} samples out of {samples+1}"


when isMainModule:
  let action =
    if paramCount() > 0:
      paramStr(1)
    else:
      ""

  case action:

    of "bench":
      bench()

    of "update-db":
      update_db()

    of "generate-report":
      let bench_names = list_benchmarks()
      gen_bench_page(bench_names)
      gen_table(bench_names)

    of "rebuild-db":
      rebuild_db()

    else:
      echo "Usage: [bench|update-db|generate-report]"
