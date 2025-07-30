# Taskle

[![Package Version](https://img.shields.io/hexpm/v/taskle)](https://hex.pm/packages/taskle)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/taskle/)

✨ **Concurrent programming for Gleam** ✨

Taskle brings Elixir-style `Task` to Gleam.

## Installation

```sh
gleam add taskle
```

## Example

```gleam
import taskle
import gleam/io

pub fn main() {
  let task = taskle.async(fn() { expensive_computation() })

  case taskle.await(task, 5000) {
    Ok(result) -> io.println("Got: " <> result)
    Error(taskle.Timeout) -> io.println("Timed out")
    Error(taskle.Crashed(_)) -> io.println("Task crashed")
  }
}
```

## Features

- **Async/await patterns** inspired by Elixir's Task module
- **True concurrency** using BEAM processes
- **Type-safe** with compile-time guarantees
- **Timeout support** for all operations
- **Task cancellation** and resource management
- **Parallel processing** utilities

## More Examples

### Parallel Processing

```gleam
import taskle
import gleam/list

let numbers = list.range(1, 100)
case taskle.parallel_map(numbers, fn(n) { n * n }, 5000) {
  Ok(squares) -> // Process results
  Error(_) -> // Handle error
}
```

### Task Management

```gleam
import taskle

let task = taskle.async(fn() { long_running_work() })

let result = taskle.await(task, 5000)

// Cancel if needed
taskle.cancel(task, 5000)
```

## Documentation

- [API Reference](https://hexdocs.pm/taskle/)

## Contributing

Contributions welcome! Run:

```sh
gleam test    # Run tests
gleam format  # Format code
```
