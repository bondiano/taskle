import gleam/bool
import gleam/erlang/process.{type Down, type Monitor, type Pid, type Subject}
import gleam/list
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
  let Task(pid: task_pid, monitor:, owner:, subject:) = task

  use <- bool.guard(process.self() != owner, Error(NotOwner))

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, DownMsg)
    |> process.select_map(subject, TaskMsg)

  case process.selector_receive(from: selector, within: timeout) {
    Ok(TaskMsg(TaskResult(value))) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    Ok(DownMsg(process.ProcessDown(pid: _, monitor: _, reason: reason))) -> {
      case reason {
        process.Normal -> Error(Crashed("normal"))
        process.Killed -> Error(Crashed("killed"))
        process.Abnormal(reason) -> Error(Crashed(string.inspect(reason)))
      }
    }
    Ok(DownMsg(process.PortDown(..))) -> {
      Error(Crashed("port_down"))
    }
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
  let Task(pid:, monitor:, owner:, ..) = task

  use <- bool.guard(process.self() != owner, Error(NotOwner))

  process.kill(pid)
  process.demonitor_process(monitor)
  Ok(Nil)
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
      let elapsed = system_time_nanoseconds() - start_time
      let remaining_timeout = timeout - elapsed / 1_000_000

      use <- bool.lazy_guard(remaining_timeout <= 0, fn() {
        list.each(rest, cancel)
        Error(Timeout)
      })

      case await(task, remaining_timeout) {
        Ok(result) ->
          await_all_loop(rest, [result, ..results], timeout, start_time)
        Error(err) -> {
          list.each(rest, cancel)
          Error(err)
        }
      }
    }
  }
}

/// Creates an asynchronous task that is not linked to the calling process.
///
/// This is identical to `async`, but provided for clarity when you specifically
/// want to emphasize that the task is unlinked. Use this for fire-and-forget
/// scenarios where you don't want the parent process to be affected if the task crashes.
///
/// ## Examples
///
/// ```gleam
/// let fire_and_forget = taskle.async_unlinked(fn() {
///   // This task won't affect the parent process if it crashes
///   risky_operation()
/// })
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

@external(erlang, "erlang", "system_time")
fn system_time_nanoseconds() -> Int
