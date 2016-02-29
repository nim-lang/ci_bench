# JSON benchmark
#

from times import epochTime
import json

var best_time = 999.0

var arr = @[1,2,3,5,6,0,7,8,9]
for x in 1..1000:
  arr.add x

for loop_cnt in 1..100:
  let t0 = epochTime()

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

  let elapsed = epochTime() - t0
  if elapsed < best_time:
    best_time = elapsed

echo best_time
