# Run benchmarks
# (c) 2023 Federico Ceratto - released under GPL-3.0

import os
import osproc
import strutils
import tables
import times

import std/[db_sqlite, posix_utils, tempfiles, sequtils]
import std/strformat


const
  benchmarks_dir = "benchmarks"
  bench_glob = benchmarks_dir.join_path("*.nim")
  db_fn = "minimize.sqlite"
  tmpdb_fn = "minimize.tmp.sqlite"

proc list_benchmarks(): seq[string] =
  # List benchmarks without dir name and extension
  result = @[]
  for fname in walk_files(bench_glob):
    result.add fname.splitFile.name

  echo "Found $# benchmarks" % $result.len

proc bfname(bench_name: string): string =
  benchmarks_dir / bench_name & ".nim"


# # Benchmarking # #

proc compile_benchmarks(bench_names: seq[string]): seq[string] =
  echo "Compiling benchmarks"
  for bench_name in bench_names:
    echo "Compiling ", bench_name
    let rc = execShellCmd("nim c -d:danger $#" % bench_name.bfname)
    if rc == 0:
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
    rv = execCmd(cmd.join(" "))
  if rv == 0:
    result = parse_cachegrind_output(tmpfile)
    removeFile(tmp_fname)

type
  Summary = tuple[l1_hits, l3_hits, ram_hits, score: int]
  Datapoint = tuple[commitish: string, commit_epoch: int, os, architecture, bench_name: string, l1_hits, l3_hits, ram_hits, score: int]
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

proc run_benchmarks(commitish: string, commit_epoch: int, bench_names: seq[string]): Datapoints =
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
      result.add (commitish, commit_epoch, os, architecture, bench_name, l1_hits, l3_hits, ram_hits, score)

    except:
      echo "Unhandled error"


# # DB # #

const
  create_tbl = sql"""
    CREATE TABLE IF NOT EXISTS minimize (
      commitish VARCHAR(50),
      commit_epoch INTEGER,
      os VARCHAR(32) NOT NULL,
      architecture VARCHAR(32) NOT NULL,
      bench_name VARCHAR(50) NOT NULL,
      bench_datetime DATETIME DEFAULT CURRENT_TIMESTAMP,
      l1_hits INTEGER,
      l3_hits INTEGER,
      ram_hits INTEGER,
      score INTEGER
    )
  """
  rowsql = "commitish, commit_epoch, os, architecture, bench_name, l1_hits, l3_hits, ram_hits, score"
  insertsql = sql(&"INSERT INTO minimize ({rowsql}) VALUES (?, ?, ?, ?,  ?, ?, ?, ?, ?)")

proc write_tmp_db(rows: Datapoints) =
  echo &"Reading "
  let db = open(tmpdb_fn, "", "", "")
  db.exec(create_tbl)
  for row in rows:
    let id = db.insertID(insertsql,
      row.commitish, row.commit_epoch, row.os, row.architecture, row.bench_name, row.l1_hits, row.l3_hits, row.ram_hits, row.score
    )
  db.close()
  echo &"{tmpdb_fn} written"

proc update_db() =
  ## Append data from tmp db to persistent db
  echo &"Reading {tmpdb_fn}"
  let tmpdb = open(tmpdb_fn, "", "", "")
  let db = open(db_fn, "", "", "")
  db.exec(create_tbl)
  for x in tmpdb.rows(sql(&"SELECT {rowsql} FROM minimize")):
    let id = db.insertID(insertsql, x)

  db.close()
  tmpdb.close()
  echo &"{db_fn} written"
  # removeFile(tmpdb_fn)


# # Charting # #

const chart_baseurl = "https://github.com/FedericoCeratto/minimize/blob/master/"

type
  ChartBar = tuple[date, github_commit: string, height: int, value: float]
  Chart* = object
    title*: string
    srcurl*: string
    bars*: seq[ChartBar]

include "bench_page.tmpl"  # provides generateHTMLPage

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


proc generate_charts(bench_names: seq[string], db: DbConn): seq[Chart] =

  const q = sql(&"""
    SELECT {rowsql} FROM minimize WHERE bench_name = ?
  """)
  for bench_name in bench_names:
    var dps: Datapoints = @[]
    for row in db.rows(q, bench_name):
      let x: Datapoint = (row[0], row[1].parseInt, row[2], row[3],
          row[4], row[5].parseInt, row[6].parseInt, row[7].parseInt, row[8].parseInt)
      dps.add x

    echo &"Fetched data for {bench_name}: {dps.len} datapoints"

    let c = generate_chart(bench_name, dps)
    result.add c

proc gen_bench_page*(bench_names: seq[string]) =
  echo &"Reading {db_fn}"
  let db = open(db_fn, "", "", "")
  let tstamp = $now().utc
  let
    charts = generate_charts(bench_names, db)
    page = generateHTMLPage(charts, tstamp)
  echo "Writing output to minimize.html"
  let f = open("minimize.html", fmWrite)
  f.writeLine(page)


# # main # #

proc bench() =
  let
    commitish =
      if paramCount() > 1:
        paramStr(2)
      else:
        execProcess("git rev-parse HEAD").strip

    commit_epoch =
      if paramCount() > 2:
        paramStr(3).parseInt
      else:
        execProcess("""git --no-pager log -1 --format="%at" """).strip.parseInt

    bench_names = list_benchmarks()
    compiled_bnames = compile_benchmarks(bench_names)
    outcome = run_benchmarks(commitish, commit_epoch, compiled_bnames)
  write_tmp_db(outcome)


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

    else:
      echo "Usage: [bench|update-db|generate-report]"
