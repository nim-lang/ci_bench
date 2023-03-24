
from times import epochTime

template run_bench*(loop_num: int, body: untyped): untyped =
  var best_time = -1.0
  for loop_cnt in 1..loop_num:
    let start_time = epochTime()
    body
    let elapsed = epochTime() - start_time
    if elapsed < best_time or best_time == -1.0:
      best_time = elapsed

  echo best_time
