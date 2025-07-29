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
