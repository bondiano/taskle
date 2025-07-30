import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should

import taskle

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn async_basic_test() {
  let task = taskle.async(fn() { 42 })
  taskle.await(task, 1000)
  |> should.be_ok()
  |> should.equal(42)
}

pub fn async_with_error_test() {
  let task = taskle.async(fn() { panic as "intentional error" })
  case taskle.await(task, 1000) {
    Error(taskle.Crashed(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn timeout_test() {
  let task =
    taskle.async(fn() {
      process.sleep(2000)
      42
    })
  case taskle.await(task, 100) {
    Error(taskle.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parallel_map_test() {
  let numbers = [1, 2, 3, 4, 5]
  case taskle.parallel_map(numbers, fn(x) { x * 2 }, 2000) {
    Ok(results) -> {
      list.length(results) |> should.equal(5)
      should.equal(results, [2, 4, 6, 8, 10])
    }
    _ -> should.fail()
  }
}

pub fn cancel_task_test() {
  let task =
    taskle.async(fn() {
      process.sleep(5000)
      42
    })

  case taskle.cancel(task) {
    Ok(Nil) -> should.be_true(True)
    _ -> should.fail()
  }

  case taskle.await(task, 1000) {
    Error(taskle.Crashed(_)) | Error(taskle.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn not_owner_test() {
  let result_subject = process.new_subject()

  process.spawn(fn() {
    let task = taskle.async(fn() { 42 })
    process.send(result_subject, task)
  })

  let assert Ok(task) = process.receive(result_subject, 1000)

  case taskle.await(task, 1000) {
    Error(taskle.NotOwner) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await_forever_test() {
  let task = taskle.async(fn() { 42 })
  taskle.await_forever(task)
  |> should.be_ok()
  |> should.equal(42)
}

pub fn yield_ready_test() {
  let task = taskle.async(fn() { 42 })
  process.sleep(100)
  // Give task time to complete
  case taskle.yield(task) {
    Ok(42) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn yield_not_ready_test() {
  let task =
    taskle.async(fn() {
      process.sleep(1000)
      42
    })
  case taskle.yield(task) {
    Error(taskle.NotReady) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn try_await_all_test() {
  let task1 = taskle.async(fn() { 1 })
  let task2 = taskle.async(fn() { 2 })
  let task3 = taskle.async(fn() { 3 })

  case taskle.try_await_all([task1, task2, task3], 2000) {
    Ok([1, 2, 3]) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn shutdown_test() {
  let task =
    taskle.async(fn() {
      process.sleep(5000)
      42
    })

  case taskle.shutdown(task, 1000) {
    Ok(Nil) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn race_fastest_wins_test() {
  let slow_task =
    taskle.async(fn() {
      process.sleep(1000)
      "slow"
    })
  let fast_task =
    taskle.async(fn() {
      process.sleep(100)
      "fast"
    })

  case taskle.race([slow_task, fast_task], 2000) {
    Ok("fast") -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn race_empty_list_test() {
  case taskle.race([], 1000) {
    Error(taskle.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn race_single_task_test() {
  let task = taskle.async(fn() { 42 })

  case taskle.race([task], 1000) {
    Ok(42) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn race_with_crash_test() {
  let crash_task =
    taskle.async(fn() {
      process.sleep(100)
      panic as "intentional crash"
    })
  let slow_task =
    taskle.async(fn() {
      process.sleep(1000)
      "slow"
    })

  case taskle.race([slow_task, crash_task], 2000) {
    Error(taskle.Crashed(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn race_timeout_test() {
  let task1 =
    taskle.async(fn() {
      process.sleep(2000)
      "task1"
    })
  let task2 =
    taskle.async(fn() {
      process.sleep(2000)
      "task2"
    })

  case taskle.race([task1, task2], 100) {
    Error(taskle.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn all_settled_success_test() {
  let task1 = taskle.async(fn() { 1 })
  let task2 = taskle.async(fn() { 2 })
  let task3 = taskle.async(fn() { 3 })

  case taskle.all_settled([task1, task2, task3], 2000) {
    Ok([taskle.Fulfilled(1), taskle.Fulfilled(2), taskle.Fulfilled(3)]) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn all_settled_mixed_results_test() {
  let success_task = taskle.async(fn() { 42 })
  let crash_task = taskle.async(fn() { panic as "intentional error" })
  let another_task = taskle.async(fn() { 99 })

  case taskle.all_settled([success_task, crash_task, another_task], 2000) {
    Ok([
      taskle.Fulfilled(42),
      taskle.Rejected(taskle.Crashed(_)),
      taskle.Fulfilled(99),
    ]) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn all_settled_empty_list_test() {
  case taskle.all_settled([], 1000) {
    Ok([]) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn all_settled_timeout_test() {
  let task1 =
    taskle.async(fn() {
      process.sleep(2000)
      1
    })
  let task2 =
    taskle.async(fn() {
      process.sleep(2000)
      2
    })

  case taskle.all_settled([task1, task2], 100) {
    Error(taskle.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await2_success_test() {
  let task1 = taskle.async(fn() { 42 })
  let task2 = taskle.async(fn() { "hello" })

  case taskle.await2(task1, task2, 2000) {
    Ok(#(42, "hello")) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await2_first_fails_test() {
  let task1 = taskle.async(fn() { panic as "intentional error" })
  let task2 = taskle.async(fn() { "hello" })

  case taskle.await2(task1, task2, 2000) {
    Error(taskle.Crashed(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await2_timeout_test() {
  let task1 =
    taskle.async(fn() {
      process.sleep(2000)
      42
    })
  let task2 = taskle.async(fn() { "hello" })

  case taskle.await2(task1, task2, 100) {
    Error(taskle.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await3_success_test() {
  let task1 = taskle.async(fn() { 42 })
  let task2 = taskle.async(fn() { "hello" })
  let task3 = taskle.async(fn() { True })

  case taskle.await3(task1, task2, task3, 2000) {
    Ok(#(42, "hello", True)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await3_second_fails_test() {
  let task1 = taskle.async(fn() { 42 })
  let task2 = taskle.async(fn() { panic as "intentional error" })
  let task3 = taskle.async(fn() { True })

  case taskle.await3(task1, task2, task3, 2000) {
    Error(taskle.Crashed(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await4_success_test() {
  let task1 = taskle.async(fn() { 42 })
  let task2 = taskle.async(fn() { "hello" })
  let task3 = taskle.async(fn() { True })
  let task4 = taskle.async(fn() { 3.14 })

  case taskle.await4(task1, task2, task3, task4, 2000) {
    Ok(#(42, "hello", True, 3.14)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn await5_success_test() {
  let task1 = taskle.async(fn() { 42 })
  let task2 = taskle.async(fn() { "hello" })
  let task3 = taskle.async(fn() { True })
  let task4 = taskle.async(fn() { 3.14 })
  let task5 = taskle.async(fn() { [1, 2, 3] })

  case taskle.await5(task1, task2, task3, task4, task5, 2000) {
    Ok(#(42, "hello", True, 3.14, [1, 2, 3])) -> should.be_true(True)
    _ -> should.fail()
  }
}
