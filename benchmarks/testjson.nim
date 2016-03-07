# JSON benchmark
#

from times import epochTime
import json
from benchutils import run_bench

var arr = @[1,2,3,5,6,0,7,8,9]
for x in 1..1000:
  arr.add x

run_bench(100):
  var j = %* [
    {
      "name": "foo",
      "age": 30
    },
    {
      "name": "Susan",
      "age": 30
    }
  ]
  for x in 1..1000:
    j.add j[0]

  var c = copy(j)
  var text = $c
  var parsed = text.parseJson()
  doAssert parsed.len == 1002
