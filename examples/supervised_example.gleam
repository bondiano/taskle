import gleam/erlang/process
import gleam/io
import gleam/string
import taskle/supervised

pub fn main() {
  // Create a mock supervisor process for this example
  let supervisor_pid = process.spawn(fn() { example_supervisor_loop() })

  // Use default configuration
  let config = supervised.default_config()

  io.println("Creating supervised task...")

  // Create a supervised task
  case
    supervised.async(supervisor_pid, config, fn() {
      io.println("Supervised task is running!")
      process.sleep(100)
      42
    })
  {
    Ok(task) -> {
      io.println("Supervised task created successfully")

      // Await the result
      case supervised.await(task, 1000) {
        Ok(result) -> {
          io.println(
            "Supervised task completed with result: " <> string.inspect(result),
          )
        }
        Error(err) -> {
          io.println("Supervised task failed: " <> string.inspect(err))
        }
      }
    }
    Error(err) -> {
      io.println("Failed to create supervised task: " <> string.inspect(err))
    }
  }
}

fn example_supervisor_loop() -> Nil {
  let subject = process.new_subject()
  case process.receive(subject, 10_000) {
    Ok(_) -> example_supervisor_loop()
    Error(Nil) -> example_supervisor_loop()
  }
}
