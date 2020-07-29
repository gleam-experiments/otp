// TODO: test
import gleam/list
import gleam/option.{None, Option, Some}
import gleam/otp/process.{ExitReason, Pid}

// API
pub opaque type Spec(argument) {
  Starting(pids: List(Pid), argument: argument, restarter: Restarter(argument))
  Failed(ExitReason)
}

pub opaque type ChildSpec(argument_in, argument_out) {
  ChildSpec(
    start: fn(argument_in) -> process.StartResult,
    update_argument: fn(argument_in, Pid) -> argument_out,
  )
}

type RestartInstruction {
  RestartAll
  RestartFrom(Pid)
}

type StartAcc(argument) {
  StartAcc(
    argument: argument,
    instruction: RestartInstruction,
    pids: List(Pid),
    restarter: fn(RestartInstruction) -> Result(StartAcc(argument), ExitReason),
  )
}

type Restarter(argument) =
  fn(RestartInstruction) -> Result(StartAcc(argument), ExitReason)

type Child(argument) {
  Child(pid: Pid, argument: argument)
}

fn start_child(
  child_spec: ChildSpec(argument_in, argument_out),
  argument: argument_in,
) -> Result(Child(argument_out), ExitReason) {
  // Try and start the child
  try pid = child_spec.start(argument)

  // Merge the new child's pid into the argument to produce the new argument
  // used to start any remaining children.
  let argument = child_spec.update_argument(argument, pid)

  Ok(Child(pid: pid, argument: argument))
}

// TODO: more sophsiticated stopping of processes. i.e. give supervisors
// more time to shut down.
fn shutdown_child(child: Child(arg_2), _spec: ChildSpec(arg_1, arg_2)) -> Nil {
  process.send_exit(child.pid, process.Normal)
}

fn restart_child(
  argument: argument_in,
  instruction: RestartInstruction,
  child_spec: ChildSpec(argument_in, argument_out),
  child: Child(argument_out),
) -> Result(tuple(Child(argument_out), RestartInstruction), ExitReason) {
  let current = child.pid
  case instruction {
    // This child is older than the RestartFrom target, we don't need to
    // restart it
    RestartFrom(target) if target != current -> Ok(tuple(child, instruction))

    // This pid either is the cause of the problem, or we have the RestartAll
    // instruction. Either way it and its younger siblings need to be restarted.
    RestartAll -> {
      shutdown_child(child, child_spec)
      try child = start_child(child_spec, argument)
      Ok(tuple(child, RestartAll))
    }
  }
}

fn add_child_to_restarter(
  restarter: Restarter(argument_in),
  child_spec: ChildSpec(argument_in, argument_out),
  child: Child(argument_out),
) -> Restarter(argument_out) {
  fn(instr) {
    // Restart the older children. We use `try` to return early if the older
    // children failed to start
    try acc = restarter(instr)
    let argument = acc.argument

    // Restart the current child
    try pair = restart_child(argument, instr, child_spec, child)
    let tuple(child, instr) = pair

    // Create a new restarter for the next time the supervisor needs to restart
    let restarter = add_child_to_restarter(acc.restarter, child_spec, child)

    let pids = [child.pid, ..acc.pids]
    let acc = StartAcc(child.argument, instr, pids, restarter)
    Ok(acc)
  }
}

fn start_and_add_child(
  pids: List(Pid),
  argument: argument_0,
  restarter: Restarter(argument_0),
  child_spec: ChildSpec(argument_0, argument_1),
) -> Spec(argument_1) {
  case start_child(child_spec, argument) {
    Ok(child) -> {
      let pids = [child.pid, ..pids]
      let restarter = add_child_to_restarter(restarter, child_spec, child)
      Starting(pids: pids, argument: child.argument, restarter: restarter)
    }

    Error(reason) -> Failed(reason)
  }
}

pub fn add(
  spec: Spec(argument),
  child_spec: ChildSpec(argument, new_argument),
) -> Spec(new_argument) {
  case spec {
    // If one of the previous children has failed then we cannot continue
    Failed(fail) -> Failed(fail)

    // If everything is OK so far then we can add the child
    Starting(
      pids: pids,
      argument: argument,
      restarter: restarter,
    ) -> start_and_add_child(pids, argument, restarter, child_spec)
  }
}

// TODO: test
// TODO: document
pub fn worker_child(
  start: fn(argument) -> process.StartResult,
) -> ChildSpec(argument, argument) {
  ChildSpec(start: start, update_argument: fn(argument, _pid) { argument })
}

// TODO: test
// TODO: document
pub fn update_argument(
  child: ChildSpec(argument_a, argument_b),
  updater: fn(argument_a, Pid) -> argument_c,
) -> ChildSpec(argument_a, argument_c) {
  ChildSpec(start: child.start, update_argument: updater)
}
// Testing
// pub fn start_child1(x: Nil) -> process.StartResult {
//   todo
// }
// pub fn start_child2(_older: Pid) -> process.StartResult {
//   todo
// }
// pub fn start_child3(_older: Pid) -> process.StartResult {
//   todo
// }
// pub fn init(spec) {
//   spec
//   |> add(
//     worker_child(start_child1)
//     |> update_argument(fn(_arg, pid) { pid }),
//   )
//   |> add(worker_child(start_child2))
//   |> add(worker_child(start_child3))
// }
