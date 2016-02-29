# Simple benchmark
#

from times import epochTime
import algorithm

var best_time = 999.0
for loop_cnt in 1..100:
  let t0 = epochTime()

  var v = @[0]
  for x in 1..1000000:
    v.add x

  v.nextPermutation()
  doAssert v[v.high] == 999999

  let elapsed = epochTime() - t0
  if elapsed < best_time:
    best_time = elapsed

echo best_time
