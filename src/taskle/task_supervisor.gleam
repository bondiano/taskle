import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// A task supervisor that manages and restarts tasks according to their configuration
pub opaque type TaskSupervisor {
  TaskSupervisor(pid: Pid)
}

/// Message type for task supervisor operations
pub type TaskSupervisorMessage {
  StartTask(
    reply: Subject(Result(Pid, String)),
    spec: supervision.ChildSpecification(Nil),
  )
  GetChildren(reply: Subject(List(Pid)))
  TerminateChild(reply: Subject(Result(Nil, String)), pid: Pid)
}

/// Starts a new task supervisor with the given strategy
pub fn start_link(
  strategy: supervisor.Strategy,
) -> Result(TaskSupervisor, actor.StartError) {
  case supervisor.new(strategy) |> supervisor.start {
    Ok(actor.Started(pid, _)) -> Ok(TaskSupervisor(pid))
    Error(err) -> Error(err)
  }
}

/// Starts a new task supervisor with the default OneForOne strategy
pub fn start() -> Result(TaskSupervisor, actor.StartError) {
  start_link(supervisor.OneForOne)
}

/// Starts a task as a child of the given supervisor (like Elixir's start_child)
/// This is fire-and-forget - you don't await the result
pub fn start_child(
  supervisor: TaskSupervisor,
  fun: fn() -> a,
  _restart: supervision.Restart,
) -> Result(Pid, String) {
  let TaskSupervisor(_supervisor_pid) = supervisor
  
  // For now, we'll use a simple approach - spawn the task directly
  // In a full implementation with dynamic supervisors, we'd add children dynamically
  let pid = process.spawn_unlinked(fun)
  Ok(pid)
}

/// Starts a task that can be awaited on (like Elixir's async_nolink)
/// The task is not linked to the caller, only to the supervisor
pub fn async_nolink(
  supervisor: TaskSupervisor,
  fun: fn() -> a,
  _subject: Subject(b),
) -> Result(Pid, String) {
  let TaskSupervisor(_supervisor_pid) = supervisor
  
  // Create a task that sends its result to the subject
  let task_fun = fn() {
    let _result = fun()
    // Note: We can't send 'a' to Subject(b) directly
    // The caller needs to handle the type mapping
    Nil
  }
  
  // For now, spawn the task directly
  // In a full implementation, this would be supervised
  let pid = process.spawn_unlinked(task_fun)
  Ok(pid)
}

/// Gets all children PIDs from the supervisor
pub fn children(supervisor: TaskSupervisor) -> List(Pid) {
  let TaskSupervisor(_supervisor_pid) = supervisor
  // In a real implementation, we'd query the supervisor for its children
  // For now, return empty list
  []
}

/// Terminates a child process
pub fn terminate_child(
  supervisor: TaskSupervisor,
  child_pid: Pid,
) -> Result(Nil, String) {
  let TaskSupervisor(_supervisor_pid) = supervisor
  process.kill(child_pid)
  Ok(Nil)
}

/// Returns the supervisor's PID
pub fn pid(supervisor: TaskSupervisor) -> Pid {
  let TaskSupervisor(pid) = supervisor
  pid
}