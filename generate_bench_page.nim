#
# Generate benchmark page
#

import os, parsecsv, streams
import strutils
import sequtils
import times

const chart_baseurl = "https://github.com/FedericoCeratto/minimize/blob/master/"

type
  ChartRow = tuple[date, github_commit: string, height: int, value: float]
  Chart* = object
    title*: string
    srcurl*: string
    rows*: seq[ChartRow]

include "bench_page.tmpl"

proc load_csv(fname: string): seq[seq[string]] =
  result = @[]
  var s = newFileStream(fname, fmRead)
  if s == nil: quit("cannot open the file" & fname)
  var p: CsvParser
  p.open(s, fname)
  while readRow(p):
    result.add p.row
  close(p)


var
  charts: seq[Chart] = @[]
  linecnt = 0

for input_fname in walkFiles("benchmarks/*.csv"):
  echo "Processing $#" % input_fname
  linecnt = 0
  var c = Chart(title: input_fname[0..^5], rows: @[])
  c.srcurl = chart_baseurl & c.title & ".nim"
  let rows = load_csv(input_fname)
  let max_value = rows.mapIt(it[2].strip.parseFloat).max()

  for row in rows:
    linecnt.inc
    let
      date = row[0]
      github_commit = row[1].strip
      value = row[2].strip().parseFloat()
      height = int(200 * value / max_value)
      r: ChartRow = (date, github_commit, height, value)
    c.rows.add r

  charts.add c
  echo "Processed $# lines" % $linecnt

let tstamp = $getGmTime(getTime())
let page = generateHTMLPage(charts, tstamp)
echo "Writing output to bench.html"
let f = open("bench.html", fmWrite)
f.writeLine(page)
