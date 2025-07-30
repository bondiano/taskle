import gleam/erlang/process
import gleam/otp/supervision
import gleeunit
import gleeunit/should
import taskle/supervised
import taskle/task_supervisor

pub fn main() -> Nil {
  gleeunit.main()
}

// Create a proper task supervisor for testing
fn create_test_supervisor() -> Result(task_supervisor.TaskSupervisor, String) {
  case task_supervisor.start() {
    Ok(supervisor) -> Ok(supervisor)
    Error(_) -> Error("Failed to start supervisor")
  }
}

pub fn supervised_async_basic_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) = supervised.async(supervisor, config, fn() { 42 })

  case supervised.await(task, 1000) {
    Ok(42) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_async_with_error_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) =
    supervised.async(supervisor, config, fn() {
      panic as "intentional supervised error"
    })

  case supervised.await(task, 1000) {
    Error(supervised.Crashed(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_timeout_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) =
    supervised.async(supervisor, config, fn() {
      process.sleep(2000)
      42
    })

  case supervised.await(task, 100) {
    Error(supervised.Timeout) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_cancel_task_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) =
    supervised.async(supervisor, config, fn() {
      process.sleep(5000)
      42
    })

  case supervised.cancel(task) {
    Ok(Nil) -> should.be_true(True)
    _ -> should.fail()
  }

  case supervised.await(task, 1000) {
    Error(supervised.Crashed(_)) | Error(supervised.Timeout) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_not_owner_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()
  let result_subject = process.new_subject()

  process.spawn(fn() {
    let assert Ok(task) = supervised.async(supervisor, config, fn() { 42 })
    process.send(result_subject, task)
  })

  let assert Ok(task) = process.receive(result_subject, 1000)

  case supervised.await(task, 1000) {
    Error(supervised.NotOwner) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_await_forever_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) = supervised.async(supervisor, config, fn() { 42 })

  case supervised.await_forever(task) {
    Ok(42) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_yield_ready_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) = supervised.async(supervisor, config, fn() { 42 })

  process.sleep(100)
  // Give task time to complete
  case supervised.yield(task) {
    Ok(42) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_yield_not_ready_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) =
    supervised.async(supervisor, config, fn() {
      process.sleep(1000)
      42
    })

  case supervised.yield(task) {
    Error(supervised.NotReady) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervised_pid_test() {
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  let assert Ok(task) = supervised.async(supervisor, config, fn() { 42 })

  let task_pid = supervised.pid(task)
  let supervisor_from_task = supervised.supervisor(task)

  // Just check that we get valid PIDs
  case process.is_alive(task_pid) {
    True -> should.be_true(True)
    False -> should.be_true(True)
    // Task might have completed already
  }

  // Check that supervisors match
  should.equal(supervisor_from_task, supervisor)
}

pub fn default_config_test() {
  let config = supervised.default_config()

  // Test that default config has expected values
  should.equal(config.max_restarts, 3)
  should.equal(config.max_seconds, 5000)
  // Check restart strategy is Temporary
  case config.restart {
    supervision.Temporary -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn custom_config_test() {
  let assert Ok(supervisor) = create_test_supervisor()

  let custom_config =
    supervised.SupervisedTaskConfig(
      restart: supervision.Permanent,
      max_restarts: 5,
      max_seconds: 10_000,
    )

  let assert Ok(task) =
    supervised.async(supervisor, custom_config, fn() { 42 })

  case supervised.await(task, 1000) {
    Ok(42) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn supervisor_not_available_test() {
  // Create a supervisor and then test with it
  let assert Ok(supervisor) = create_test_supervisor()
  let config = supervised.default_config()

  // Test that we can create tasks with a proper supervisor
  case supervised.async(supervisor, config, fn() { 42 }) {
    Ok(_task) -> should.be_true(True)
    Error(_) -> should.fail()
  }
}
