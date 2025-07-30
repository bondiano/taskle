import gleam/bool
import gleam/erlang/process.{type Down, type Monitor, type Pid, type Subject}
import gleam/otp/supervision
import gleam/result
import gleam/string
import taskle/task_supervisor.{type TaskSupervisor}

/// A supervised task represents an asynchronous computation running under
/// a supervisor. Unlike regular tasks, supervised tasks can be restarted
/// according to supervisor configuration if they crash.
pub opaque type SupervisedTask(a) {
  SupervisedTask(
    pid: Pid,
    monitor: Monitor,
    owner: Pid,
    subject: Subject(SupervisedTaskMessage(a)),
    supervisor: TaskSupervisor,
  )
}

/// Configuration for supervised task behavior.
pub type SupervisedTaskConfig {
  SupervisedTaskConfig(
    /// Restart strategy for the task
    restart: RestartStrategy,
    /// Maximum number of restarts allowed
    max_restarts: Int,
    /// Time window for restart counting (in milliseconds)
    max_seconds: Int,
  )
}

/// Re-export restart strategies from OTP supervision
pub type RestartStrategy =
  supervision.Restart

/// Error types specific to supervised tasks.
pub type SupervisedError {
  /// The task didn't complete within the specified timeout
  Timeout
  /// The task process crashed with the given reason
  Crashed(reason: String)
  /// Attempted to await or cancel a task from a different process
  NotOwner
  /// The supervisor is not running or available
  SupervisorNotAvailable
  /// Maximum restart limit exceeded
  RestartLimitExceeded
  /// The task is not ready yet (used by yield function)
  NotReady
}

pub type SupervisedTaskMessage(a) {
  SupervisedTaskResult(value: a)
}

type SupervisedAwaitMsg(a) {
  SupervisedTaskMsg(SupervisedTaskMessage(a))
  SupervisedDownMsg(Down)
}

/// Default configuration for supervised tasks.
/// - Temporary restart strategy (no restarts)
/// - 3 max restarts
/// - 5 second time window
pub fn default_config() -> SupervisedTaskConfig {
  SupervisedTaskConfig(
    restart: supervision.Temporary,
    max_restarts: 3,
    max_seconds: 5000,
  )
}

/// Creates a supervised task that runs the given function under a supervisor.
///
/// The task will be monitored and potentially restarted according to the
/// supervisor configuration. Only the process that creates the task can
/// await its result or cancel it.
///
/// ## Examples
///
/// ```gleam
/// let config = taskle.supervised.default_config()
/// let task = taskle.supervised.async(supervisor, config, fn() {
///   // This runs under supervision
///   expensive_computation()
/// })
/// ```
pub fn async(
  supervisor: TaskSupervisor,
  config: SupervisedTaskConfig,
  fun: fn() -> a,
) -> Result(SupervisedTask(a), SupervisedError) {
  let owner = process.self()
  let subject = process.new_subject()

  // Start the task under the supervisor
  case start_supervised_task(supervisor, config, fun, subject) {
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      Ok(SupervisedTask(
        pid: pid,
        monitor: monitor,
        owner: owner,
        subject: subject,
        supervisor: supervisor,
      ))
    }
    Error(_) -> Error(SupervisorNotAvailable)
  }
}

/// Waits for a supervised task to complete with a timeout.
///
/// Only the process that created the task can await its result.
///
/// ## Examples
///
/// ```gleam
/// case taskle.supervised.await(task, 5000) {
///   Ok(value) -> io.println("Success: " <> string.inspect(value))
///   Error(taskle.supervised.Timeout) -> io.println("Task timed out")
///   Error(taskle.supervised.Crashed(reason)) -> io.println("Task failed: " <> reason)
/// }
/// ```
pub fn await(
  task: SupervisedTask(a),
  timeout: Int,
) -> Result(a, SupervisedError) {
  let SupervisedTask(pid: task_pid, monitor: monitor, owner: _owner, ..) = task

  use _ <- result.try(validate_supervised_ownership(task))

  let selector =
    build_supervised_task_selector(task, SupervisedTaskMsg, SupervisedDownMsg)

  case process.selector_receive(from: selector, within: timeout) {
    Ok(SupervisedTaskMsg(SupervisedTaskResult(value))) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    Ok(SupervisedDownMsg(down)) -> Error(supervised_down_to_error(down))
    Error(Nil) -> {
      process.kill(task_pid)
      process.demonitor_process(monitor)
      Error(Timeout)
    }
  }
}

/// Waits for a supervised task to complete without a timeout.
///
/// Only the process that created the task can await its result.
///
/// ## Examples
///
/// ```gleam
/// case taskle.supervised.await_forever(task) {
///   Ok(value) -> io.println("Success: " <> string.inspect(value))
///   Error(taskle.supervised.Crashed(reason)) -> io.println("Task failed: " <> reason)
/// }
/// ```
pub fn await_forever(task: SupervisedTask(a)) -> Result(a, SupervisedError) {
  let SupervisedTask(monitor: monitor, ..) = task

  use _ <- result.try(validate_supervised_ownership(task))

  let selector =
    build_supervised_task_selector(task, SupervisedTaskMsg, SupervisedDownMsg)

  case process.selector_receive_forever(from: selector) {
    SupervisedTaskMsg(SupervisedTaskResult(value)) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    SupervisedDownMsg(down) -> Error(supervised_down_to_error(down))
  }
}

/// Cancels a supervised task.
///
/// Only the process that created the task can cancel it. Cancelling a supervised
/// task will also remove it from supervision.
///
/// ## Examples
///
/// ```gleam
/// case taskle.supervised.cancel(task) {
///   Ok(Nil) -> io.println("Task cancelled")
///   Error(taskle.supervised.NotOwner) -> io.println("Cannot cancel from different process")
/// }
/// ```
pub fn cancel(task: SupervisedTask(a)) -> Result(Nil, SupervisedError) {
  let SupervisedTask(pid: pid, monitor: monitor, supervisor: supervisor, ..) =
    task

  use _ <- result.try(validate_supervised_ownership(task))

  // Remove from supervisor first
  let _ = task_supervisor.terminate_child(supervisor, pid)

  process.kill(pid)
  process.demonitor_process(monitor)
  Ok(Nil)
}

/// Checks if a supervised task has completed without blocking.
///
/// Returns `Ok(value)` if the task has completed, `Error(NotReady)` if it's still
/// running, or other errors if the task crashed or ownership check fails.
///
/// ## Examples
///
/// ```gleam
/// case taskle.supervised.yield(task) {
///   Ok(value) -> io.println("Task completed")
///   Error(taskle.supervised.NotReady) -> io.println("Task still running")
/// }
/// ```
pub fn yield(task: SupervisedTask(a)) -> Result(a, SupervisedError) {
  let SupervisedTask(monitor: monitor, ..) = task

  use _ <- result.try(validate_supervised_ownership(task))

  let selector =
    build_supervised_task_selector(task, SupervisedTaskMsg, SupervisedDownMsg)

  case process.selector_receive(from: selector, within: 0) {
    Ok(SupervisedTaskMsg(SupervisedTaskResult(value))) -> {
      process.demonitor_process(monitor)
      Ok(value)
    }
    Ok(SupervisedDownMsg(down)) -> Error(supervised_down_to_error(down))
    Error(Nil) -> Error(NotReady)
  }
}

/// Returns the process ID of the supervised task's underlying BEAM process.
///
/// ## Examples
///
/// ```gleam
/// let task_pid = taskle.supervised.pid(task)
/// ```
pub fn pid(task: SupervisedTask(a)) -> Pid {
  let SupervisedTask(pid: pid, ..) = task
  pid
}

/// Returns the supervisor for this supervised task.
///
/// ## Examples
///
/// ```gleam
/// let supervisor = taskle.supervised.supervisor(task)
/// ```
pub fn supervisor(task: SupervisedTask(a)) -> TaskSupervisor {
  let SupervisedTask(supervisor: supervisor, ..) = task
  supervisor
}

// Internal helper functions

fn validate_supervised_ownership(
  task: SupervisedTask(a),
) -> Result(Nil, SupervisedError) {
  let SupervisedTask(owner: owner, ..) = task
  use <- bool.guard(process.self() != owner, Error(NotOwner))
  Ok(Nil)
}

fn build_supervised_task_selector(
  task: SupervisedTask(a),
  result_mapper: fn(SupervisedTaskMessage(a)) -> b,
  down_mapper: fn(Down) -> b,
) -> process.Selector(b) {
  let SupervisedTask(monitor: monitor, subject: subject, ..) = task
  process.new_selector()
  |> process.select_map(subject, result_mapper)
  |> process.select_specific_monitor(monitor, down_mapper)
}

fn supervised_down_to_error(down: Down) -> SupervisedError {
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

// Start a supervised task using the task supervisor
fn start_supervised_task(
  supervisor: TaskSupervisor,
  config: SupervisedTaskConfig,
  fun: fn() -> a,
  subject: Subject(SupervisedTaskMessage(a)),
) -> Result(Pid, String) {
  // Create a wrapper function that sends the result
  let task_fun = fn() {
    let result = fun()
    process.send(subject, SupervisedTaskResult(result))
  }
  
  // Start the task under supervision
  task_supervisor.start_child(supervisor, task_fun, config.restart)
}
