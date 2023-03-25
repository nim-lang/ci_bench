# Simple benchmark

import algorithm

var v = @[0]
for x in 1..1000000:
  v.add x

v.nextPermutation()
doAssert v[v.high] == 999999
