import gleam/bool
import gleam/erlang/process.{type Down, type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A task represents an asynchronous computation running in a separate BEAM process.
/// Tasks are created with `async` and their results are retrieved with `await`.
/// Only the process that created a task can await its result or cancel it.
pub opaque type Task(a) {
  Task(pid: Pid, monitor: Monitor, owner: Pid, subject: Subject(TaskMessage(a)))
}

pub type Error {
  /// The task didn't complete within the specified timeout.
  Timeout
  /// The task process crashed with the given reason.
  Crashed(reason: String)
  /// Attempted to await or cancel a task from a different process than the one that created it.
  NotOwner
  /// The task is not ready yet (used by yield function).
  NotReady
}

/// Represents the settled state of a task (for all_settled).
pub type SettledResult(a) {
  /// The task completed successfully with the given value.
  Fulfilled(value: a)
  /// The task failed with the given error.
  Rejected(error: Error)
}

pub type TaskMessage(a) {
  TaskResult(value: a)
}

type AwaitMsg(a) {
  TaskMsg(TaskMessage(a))
  DownMsg(Down)
}

/// Creates an asynchronous task that runs the given function in a separate process.
///
/// The task is unlinked from the calling process, meaning that if the task crashes,
/// it won't cause the calling process to crash. Only the process that creates the
/// task can await its result or cancel it.
///
/// ## Examples
///
/// ```gleam
/// let task = taskle.async(fn() {
///   // This runs in a separate process
///   process.sleep(1000)
///   42
/// })
/// ```
pub fn async(fun: fn() -> a) -> Task(a) {
  let owner = process.self()
  let subject = process.new_subject()

  let pid =
    process.spawn_unlinked(fn() {
      let result = fun()
      process.send(subject, TaskResult(result))
    })

  let monitor = process.monitor(pid)

  Task(pid:, monitor:, owner:, subject:)
}

/// Waits for a task to complete with a timeout in milliseconds.
///
/// Only the process that created the task can await its result. If called from
/// a different process, returns `Error(NotOwner)`.
///
/// ## Examples
///
/// ```gleam
/// case taskle.await(task, 5000) {
///   Ok(value) -> io.println("Success: " <> int.to_string(value))
///   Error(taskle.Timeout) -> io.println("Task timed out after 5 seconds")
///   Error(taskle.Crashed(reason)) -> io.println("Task failed: " <> reason)
///   Error(taskle.NotOwner) -> io.println("Cannot await task from different process")
/// }
/// ```
pub fn await(task: Task(a), timeout: Int) -> Result(a, Error) {
  let Task(pid: task_pid, monitor:, ..) = task

  use _ <- result.try(validate_ownership(task))

  let selector = build_task_selector(task, TaskMsg, DownMsg)

  case process.selector_receive(from: selector, within: timeout) {
    Ok(TaskMsg(TaskResult(value))) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    Ok(DownMsg(down)) -> Error(down_to_error(down))
    Error(Nil) -> {
      process.kill(task_pid)
      process.demonitor_process(monitor)
      Error(Timeout)
    }
  }
}

/// Cancels a running task.
///
/// Only the process that created the task can cancel it. If called from
/// a different process, returns `Error(NotOwner)`.
///
/// ## Examples
///
/// ```gleam
/// let task = taskle.async(fn() {
///   process.sleep(10_000)
///   "done"
/// })
///
/// // Cancel the task
/// case taskle.cancel(task) {
///   Ok(Nil) -> io.println("Task cancelled")
///   Error(taskle.NotOwner) -> io.println("Cannot cancel task from different process")
/// }
/// ```
pub fn cancel(task: Task(a)) -> Result(Nil, Error) {
  let Task(pid:, monitor:, ..) = task

  use _ <- result.try(validate_ownership(task))

  process.kill(pid)
  process.demonitor_process(monitor)
  Ok(Nil)
}

/// Shuts down a task gracefully with a timeout.
///
/// This function attempts to shut down a task more gracefully than `cancel`.
/// It first removes monitoring of the process, then kills it. If the task doesn't shut down
/// within the timeout, it returns an error.
///
/// Only the process that created the task can shut it down. If called from
/// a different process, returns `Error(NotOwner)`.
///
/// ## Examples
///
/// ```gleam
/// let task = taskle.async(fn() {
///   process.sleep(10_000)
///   "done"
/// })
///
/// // Shutdown the task with a 1 second timeout
/// case taskle.shutdown(task, 1000) {
///   Ok(Nil) -> io.println("Task shut down gracefully")
///   Error(taskle.Timeout) -> io.println("Task didn't shut down in time")
///   Error(taskle.NotOwner) -> io.println("Cannot shutdown task from different process")
/// }
/// ```
pub fn shutdown(task: Task(a), timeout: Int) -> Result(Nil, Error) {
  let Task(pid:, monitor:, ..) = task

  use _ <- result.try(validate_ownership(task))

  process.demonitor_process(monitor)
  process.kill(pid)

  let start_time = system_time_nanoseconds()
  shutdown_wait_loop(pid, timeout, start_time)
}

fn shutdown_wait_loop(
  pid: Pid,
  timeout: Int,
  start_time: Int,
) -> Result(Nil, Error) {
  use <- bool.guard(is_timeout_exceeded(start_time, timeout), Error(Timeout))

  case process.is_alive(pid) {
    False -> Ok(Nil)
    True -> {
      process.sleep(10)
      shutdown_wait_loop(pid, timeout, start_time)
    }
  }
}

/// Processes a list of items in parallel, applying the given function to each item.
///
/// Returns when all tasks complete or when any task fails/times out. If any task
/// fails, all remaining tasks are cancelled.
///
/// ## Examples
///
/// ```gleam
/// let numbers = [1, 2, 3, 4, 5]
///
/// case taskle.parallel_map(numbers, fn(x) { x * x }, 5000) {
///   Ok(results) -> {
///     // results = [1, 4, 9, 16, 25]
///     io.debug(results)
///   }
///   Error(taskle.Timeout) -> io.println("Some tasks timed out")
///   Error(taskle.Crashed(reason)) -> io.println("A task crashed: " <> reason)
/// }
/// ```
pub fn parallel_map(
  list: List(a),
  fun: fn(a) -> b,
  timeout: Int,
) -> Result(List(b), Error) {
  let tasks = list.map(list, fn(item) { async(fn() { fun(item) }) })

  await_all(tasks, timeout)
}

/// Waits for all tasks to complete with a timeout.
///
/// Returns when all tasks complete or when any task fails/times out. If any task fails, all remaining tasks are cancelled.
///
/// ## Examples
///
/// ```gleam
/// let task1 = taskle.async(fn() { 42 })
/// let task2 = taskle.async(fn() { "hello" })
/// let task3 = taskle.async(fn() { True })
///
/// case taskle.try_await_all([task1, task2, task3], 5000) {
///   Ok([a, b, c]) -> {
///     // a = 42, b = "hello", c = True
///     io.debug([a, b, c])
///   }
///   Error(taskle.Timeout) -> io.println("Some tasks timed out")
///   Error(taskle.Crashed(reason)) -> io.println("A task crashed: " <> reason)
/// }
/// ```
pub fn try_await_all(
  tasks: List(Task(a)),
  timeout: Int,
) -> Result(List(a), Error) {
  await_all(tasks, timeout)
}

fn await_all(tasks: List(Task(a)), timeout: Int) -> Result(List(a), Error) {
  case tasks {
    [] -> Ok([])
    _ -> {
      let start_time = system_time_nanoseconds()
      await_all_loop(tasks, [], timeout, start_time)
    }
  }
}

fn await_all_loop(
  tasks: List(Task(a)),
  results: List(a),
  timeout: Int,
  start_time: Int,
) -> Result(List(a), Error) {
  case tasks {
    [] -> Ok(list.reverse(results))
    [task, ..rest] -> {
      let remaining = remaining_timeout_ms(start_time, timeout)

      use <- bool.lazy_guard(remaining <= 0, fn() {
        list.each(rest, fn(t) {
          let _ = cancel(t)
        })
        Error(Timeout)
      })

      case await(task, remaining) {
        Ok(result) ->
          await_all_loop(rest, [result, ..results], timeout, start_time)
        Error(err) -> {
          list.each(rest, fn(t) {
            let _ = cancel(t)
          })
          Error(err)
        }
      }
    }
  }
}

/// Creates an asynchronous task for side effects that doesn't need to be awaited.
///
/// This is useful for fire-and-forget operations where you don't need the result.
/// The task runs in an unlinked process and won't affect the parent process if it crashes.
///
/// **Key difference from `async_unlinked`:** Tasks created with `start` do NOT send
/// their result back, making them truly fire-and-forget. While you can technically
/// call `await` on them, it will never receive a result. Use `start` for side effects
/// like logging, cleanup, or background processing where you don't care about the return value.
///
/// ## Examples
///
/// ```gleam
/// taskle.start(fn() {
///   // Log something or perform side effects
///   io.println("Background task completed")
///   cleanup_temp_files()
/// })
/// ```
pub fn start(fun: fn() -> a) -> Task(a) {
  let owner = process.self()
  let subject = process.new_subject()

  let pid =
    process.spawn_unlinked(fn() {
      let _result = fun()
      // Don't send result for start tasks - they're fire-and-forget
      Nil
    })

  let monitor = process.monitor(pid)

  Task(pid:, monitor:, owner:, subject:)
}

/// Creates an asynchronous task that is not linked to the calling process.
///
/// This is identical to `async`, but provided for clarity when you specifically
/// want to emphasize that the task is unlinked. The task DOES send its result back
/// and can be awaited, unlike tasks created with `start`.
///
/// **Key difference from `start`:** Tasks created with `async_unlinked` send their
/// result back and can be awaited. Use this when you need the result but want to
/// emphasize the unlinked nature, or when you might await the task later.
///
/// ## Examples
///
/// ```gleam
/// let task = taskle.async_unlinked(fn() {
///   // This task won't affect the parent process if it crashes
///   expensive_computation()
/// })
///
/// // You can still await the result
/// case taskle.await(task, 5000) {
///   Ok(result) -> use_result(result)
///   Error(_) -> handle_error()
/// }
/// ```
pub fn async_unlinked(fun: fn() -> a) -> Task(a) {
  let owner = process.self()
  let subject = process.new_subject()

  let pid =
    process.spawn_unlinked(fn() {
      let result = fun()
      process.send(subject, TaskResult(result))
    })

  let monitor = process.monitor(pid)

  Task(pid:, monitor:, owner:, subject:)
}

/// Waits for a task to complete without a timeout.
///
/// Only the process that created the task can await its result. If called from
/// a different process, returns `Error(NotOwner)`. Will wait indefinitely until
/// the task completes or crashes.
///
/// ## Examples
///
/// ```gleam
/// case taskle.await_forever(task) {
///   Ok(value) -> io.println("Success: " <> int.to_string(value))
///   Error(taskle.Crashed(reason)) -> io.println("Task failed: " <> reason)
///   Error(taskle.NotOwner) -> io.println("Cannot await task from different process")
/// }
/// ```
pub fn await_forever(task: Task(a)) -> Result(a, Error) {
  let Task(monitor:, ..) = task

  use _ <- result.try(validate_ownership(task))

  let selector = build_task_selector(task, TaskMsg, DownMsg)

  case process.selector_receive_forever(from: selector) {
    TaskMsg(TaskResult(value)) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    DownMsg(down) -> Error(down_to_error(down))
  }
}

/// Checks if a task has completed without blocking.
///
/// Returns `Ok(value)` if the task has completed, `Error(NotReady)` if it's still
/// running, or other errors if the task crashed or ownership check fails.
///
/// ## Examples
///
/// ```gleam
/// case taskle.yield(task) {
///   Ok(value) -> io.println("Task completed: " <> int.to_string(value))
///   Error(taskle.NotReady) -> io.println("Task still running")
///   Error(taskle.Crashed(reason)) -> io.println("Task failed: " <> reason)
///   Error(taskle.NotOwner) -> io.println("Cannot check task from different process")
/// }
/// ```
pub fn yield(task: Task(a)) -> Result(a, Error) {
  let Task(monitor:, ..) = task

  use _ <- result.try(validate_ownership(task))

  let selector = build_task_selector(task, TaskMsg, DownMsg)

  case process.selector_receive(from: selector, within: 0) {
    Ok(TaskMsg(TaskResult(value))) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    Ok(DownMsg(down)) -> Error(down_to_error(down))
    Error(Nil) -> Error(NotReady)
  }
}

/// Returns the process ID of the task's underlying BEAM process.
///
/// Useful for debugging or process monitoring.
///
/// ## Examples
///
/// ```gleam
/// let task = taskle.async(fn() { 42 })
/// let process_id = taskle.pid(task)
/// io.debug(process_id)
/// ```
pub fn pid(task: Task(a)) -> Pid {
  let Task(pid: pid, ..) = task
  pid
}

/// Waits for the first task to complete (analog of Promise.race).
///
/// Returns the result of the first task to complete, whether successful or failed.
/// All other tasks are cancelled when the first one completes.
///
/// ## Examples
///
/// ```gleam
/// let task1 = taskle.async(fn() {
///   process.sleep(1000)
///   "slow"
/// })
/// let task2 = taskle.async(fn() {
///   process.sleep(100)
///   "fast"
/// })
///
/// case taskle.race([task1, task2], 5000) {
///   Ok("fast") -> io.println("Task2 won the race")
///   Error(taskle.Timeout) -> io.println("All tasks timed out")
///   Error(taskle.Crashed(reason)) -> io.println("First task to complete crashed: " <> reason)
/// }
/// ```
pub fn race(tasks: List(Task(a)), timeout: Int) -> Result(a, Error) {
  case tasks {
    [] -> Error(Timeout)
    [single_task] -> await(single_task, timeout)
    _ -> race_with_selector(tasks, timeout)
  }
}

fn race_with_selector(tasks: List(Task(a)), timeout: Int) -> Result(a, Error) {
  case validate_multiple_ownership(tasks) {
    Error(err) -> {
      list.each(tasks, fn(t) {
        let _ = cancel(t)
      })
      Error(err)
    }
    Ok(Nil) -> {
      let selector = build_race_selector(tasks, process.new_selector())

      case process.selector_receive(from: selector, within: timeout) {
        Ok(RaceResult(result, winning_task_pid)) -> {
          tasks
          |> list.filter(fn(task) { pid(task) != winning_task_pid })
          |> list.each(fn(task) {
            let _ = cancel(task)
          })
          result
        }
        Error(Nil) -> {
          list.each(tasks, fn(t) {
            let _ = cancel(t)
          })
          Error(Timeout)
        }
      }
    }
  }
}

type RaceMessage(a) {
  RaceResult(result: Result(a, Error), winning_task_pid: Pid)
}

fn build_race_selector(
  tasks: List(Task(a)),
  selector: process.Selector(RaceMessage(a)),
) -> process.Selector(RaceMessage(a)) {
  list.fold(tasks, selector, fn(acc_selector, task) {
    let Task(pid: task_pid, monitor: monitor, subject: subject, ..) = task
    acc_selector
    |> process.select_map(subject, fn(msg) {
      case msg {
        TaskResult(value) -> {
          // Demonitor after receiving result
          process.demonitor_process(monitor)
          RaceResult(Ok(value), task_pid)
        }
      }
    })
    |> process.select_specific_monitor(monitor, fn(down) {
      RaceResult(Error(down_to_error(down)), task_pid)
    })
  })
}

/// Waits for all tasks to complete regardless of success or failure (analog of Promise.allSettled).
///
/// Returns the results of all tasks, whether they succeeded or failed. Unlike `try_await_all`,
/// this function never cancels tasks early - it waits for all tasks to complete.
///
/// ## Examples
///
/// ```gleam
/// let task1 = taskle.async(fn() { 42 })
/// let task2 = taskle.async(fn() {
///   // This will crash
///   panic as "oops"
/// })
/// let task3 = taskle.async(fn() { "hello" })
///
/// case taskle.all_settled([task1, task2, task3], 5000) {
///   Ok([Fulfilled(42), Rejected(Crashed("oops")), Fulfilled("hello")]) -> {
///     io.println("All tasks completed")
///   }
///   Error(taskle.Timeout) -> io.println("Some tasks timed out")
/// }
/// ```
pub fn all_settled(
  tasks: List(Task(a)),
  timeout: Int,
) -> Result(List(SettledResult(a)), Error) {
  case tasks {
    [] -> Ok([])
    _ -> all_settled_concurrent(tasks, timeout)
  }
}

fn all_settled_concurrent(
  tasks: List(Task(a)),
  timeout: Int,
) -> Result(List(SettledResult(a)), Error) {
  use Nil <- result.try(validate_multiple_ownership(tasks))

  let indexed_tasks = list.index_map(tasks, fn(task, index) { #(index, task) })
  let task_count = list.length(tasks)

  let selector =
    build_all_settled_selector(indexed_tasks, process.new_selector())

  all_settled_collect_loop(
    selector,
    task_count,
    [],
    timeout,
    system_time_nanoseconds(),
  )
}

fn all_settled_collect_loop(
  selector: process.Selector(AllSettledMessage(a)),
  remaining_count: Int,
  results: List(#(Int, SettledResult(a))),
  timeout: Int,
  start_time: Int,
) -> Result(List(SettledResult(a)), Error) {
  case remaining_count {
    0 -> {
      results
      |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
      |> list.map(fn(pair) { pair.1 })
      |> Ok
    }
    _ -> {
      let remaining = remaining_timeout_ms(start_time, timeout)

      use <- bool.guard(remaining <= 0, Error(Timeout))

      case process.selector_receive(from: selector, within: remaining) {
        Ok(AllSettledResult(index, result)) -> {
          all_settled_collect_loop(
            selector,
            remaining_count - 1,
            [#(index, result), ..results],
            timeout,
            start_time,
          )
        }
        Error(Nil) -> Error(Timeout)
      }
    }
  }
}

type AllSettledMessage(a) {
  AllSettledResult(index: Int, result: SettledResult(a))
}

fn build_all_settled_selector(
  indexed_tasks: List(#(Int, Task(a))),
  selector: process.Selector(AllSettledMessage(a)),
) -> process.Selector(AllSettledMessage(a)) {
  list.fold(indexed_tasks, selector, fn(acc_selector, indexed_task) {
    let #(index, task) = indexed_task
    let Task(monitor: monitor, subject: subject, ..) = task

    acc_selector
    |> process.select_map(subject, fn(msg) {
      case msg {
        TaskResult(value) -> {
          process.demonitor_process(monitor)
          AllSettledResult(index, Fulfilled(value))
        }
      }
    })
    |> process.select_specific_monitor(monitor, fn(down) {
      AllSettledResult(index, Rejected(down_to_error(down)))
    })
  })
}

fn down_to_error(down: Down) -> Error {
  case down {
    process.ProcessDown(pid: _, monitor: _, reason: reason) -> {
      case reason {
        process.Normal -> Crashed("normal")
        process.Killed -> Crashed("killed")
        process.Abnormal(reason) -> Crashed(string.inspect(reason))
      }
    }
    process.PortDown(..) -> Crashed("port_down")
  }
}

fn remaining_timeout_ms(start_time: Int, total_timeout: Int) -> Int {
  let elapsed = system_time_nanoseconds() - start_time
  total_timeout - elapsed / 1_000_000
}

fn is_timeout_exceeded(start_time: Int, total_timeout: Int) -> Bool {
  remaining_timeout_ms(start_time, total_timeout) <= 0
}

fn build_task_selector(
  task: Task(a),
  result_mapper: fn(TaskMessage(a)) -> b,
  down_mapper: fn(Down) -> b,
) -> process.Selector(b) {
  let Task(monitor: monitor, subject: subject, ..) = task
  process.new_selector()
  |> process.select_map(subject, result_mapper)
  |> process.select_specific_monitor(monitor, down_mapper)
}

fn validate_ownership(task: Task(a)) -> Result(Nil, Error) {
  let Task(owner: owner, ..) = task
  use <- bool.guard(process.self() != owner, Error(NotOwner))
  Ok(Nil)
}

fn validate_multiple_ownership(tasks: List(Task(a))) -> Result(Nil, Error) {
  let current_pid = process.self()
  use <- bool.guard(
    !list.all(tasks, fn(task) {
      let Task(owner:, ..) = task
      owner == current_pid
    }),
    Error(NotOwner),
  )

  Ok(Nil)
}

@external(erlang, "erlang", "system_time")
fn system_time_nanoseconds() -> Int
