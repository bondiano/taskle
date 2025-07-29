# Taskle

A concurrent programming library for Gleam that provides Elixir-like Task module functionality. Taskle allows you to run computations asynchronously using lightweight BEAM processes with a simple, type-safe API.

## Features

- **Simple async/await API** inspired by Elixir's Task module
- **Type-safe concurrency** with full compile-time guarantees
- **Built on BEAM processes** for true concurrency and fault tolerance
- **Timeout support** for all operations
- **Task cancellation** for resource management
- **Parallel processing** utilities for lists
- **Owner-based access control** prevents race conditions

## Installation

Add `taskle` to your Gleam project:

```sh
gleam add taskle
```

## Quick Start

```gleam
import taskle

pub fn main() {
  // Create an asynchronous task
  let task = taskle.async(fn() {
    // Some expensive computation
    expensive_computation()
  })

  // Wait for the result with a timeout (in milliseconds)
  case taskle.await(task, 5000) {
    Ok(result) -> io.println("Got result: " <> result)
    Error(taskle.Timeout) -> io.println("Task timed out")
    Error(taskle.Crashed(reason)) -> io.println("Task crashed: " <> reason)
  }
}
```

## API

See the module documentation for detailed API reference.

## Examples

### Basic Usage

```gleam
import taskle
import gleam/io
import gleam/int

pub fn basic_example() {
  let task = taskle.async(fn() {
    // Simulate some work
    process.sleep(100)
    42
  })

  case taskle.await(task, 1000) {
    Ok(result) -> io.println("Result: " <> int.to_string(result))
    Error(_) -> io.println("Task failed")
  }
}
```

### Parallel Processing

```gleam
import taskle
import gleam/list
import gleam/int

pub fn parallel_example() {
  let numbers = list.range(1, 10)

  case taskle.parallel_map(numbers, fn(n) {
    // Simulate expensive computation
    process.sleep(100)
    n * n
  }, 5000) {
    Ok(squares) -> {
      io.println("Squares: " <> string.inspect(squares))
    }
    Error(err) -> {
      io.println("Parallel processing failed")
    }
  }
}
```

### Task Cancellation

```gleam
import taskle

pub fn cancellation_example() {
  let long_task = taskle.async(fn() {
    process.sleep(30_000)  // 30 seconds
    "finally done"
  })

  // Cancel after 1 second
  process.sleep(1000)
  case taskle.cancel(long_task) {
    Ok(Nil) -> io.println("Task cancelled successfully")
    Error(_) -> io.println("Failed to cancel task")
  }
}
```

### Error Handling Example

```gleam
import taskle

pub fn error_handling_example() {
  let risky_task = taskle.async(fn() {
    case random_boolean() {
      True -> "success"
      False -> panic as "something went wrong"
    }
  })

  case taskle.await(risky_task, 5000) {
    Ok(result) -> io.println("Success: " <> result)
    Error(taskle.Crashed(reason)) -> {
      io.println("Task crashed: " <> reason)
    }
    Error(taskle.Timeout) -> {
      io.println("Task took too long")
    }
    Error(taskle.NotOwner) -> {
      io.println("Ownership error")
    }
  }
}
```

## Best Practices

1. **Always set appropriate timeouts** to prevent hanging operations
2. **Handle all error cases** explicitly for robust applications
3. **Use `cancel()` for cleanup** when tasks are no longer needed
4. **Consider `async_unlinked()`** for fire-and-forget operations
5. **Keep task functions pure** when possible for easier testing and reasoning

## Performance Considerations

- BEAM processes are lightweight but not free - avoid creating excessive numbers of short-lived tasks
- For CPU-bound work, consider the number of available cores when deciding parallelism level
- Network-bound operations benefit greatly from concurrent execution
- Use `parallel_map` for batch processing rather than creating tasks manually

## Comparison with Other Languages

Taskle provides similar functionality to:

- **Elixir**: `Task.async/1` and `Task.await/2`
- **JavaScript**: `Promise` and `async/await`
- **Go**: Goroutines with channels
- **Rust**: `tokio::spawn` and `.await`

The key difference is that Taskle leverages BEAM's actor model for true parallelism and fault tolerance.

## Contributing

Contributions are welcome! Please ensure:

- All tests pass: `gleam test`
- Code is formatted: `gleam format`
- New features include tests and documentation

## License

This project is licensed under the Apache License 2.0.