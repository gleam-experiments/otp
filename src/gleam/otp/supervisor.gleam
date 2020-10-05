// TODO: test
// TODO: specify amount of time permitted for shut-down
import gleam/list
import gleam/pair
import gleam/result
import gleam/dynamic
import gleam/option.{None, Option, Some}
import gleam/otp/process.{Pid, Sender}
import gleam/otp/actor.{StartError}
import gleam/otp/intensity_tracker.{IntensityTracker}
import gleam/io
import gleam/otp/node.{Node}

// TODO: document
pub type Spec(argument, return) {
  Spec(
    argument: argument,
    max_frequency: Int,
    frequency_period: Int,
    init: fn(Children(argument)) -> Children(return),
  )
}

// TODO: document
pub opaque type Children(argument) {
  Ready(Starter(argument))
  Failed(ChildStartError)
}

// TODO: document
pub opaque type ChildSpec(msg, argument_in, argument_out) {
  ChildSpec(
    start: fn(argument_in) -> Result(Sender(msg), StartError),
    returning: fn(argument_in, Sender(msg)) -> argument_out,
  )
}

type ChildStartError {
  ChildStartError(previous_pid: Option(Pid), error: StartError)
}

// TODO: document
pub opaque type Message {
  Exit(process.Exit)
  RetryRestart(process.Pid)
}

type Instruction {
  StartAll
  StartFrom(Pid)
}

type State(a) {
  State(
    restarts: IntensityTracker,
    starter: Starter(a),
    retry_restart_channel: process.Sender(process.Pid),
  )
}

type Starter(argument) {
  Starter(
    argument: argument,
    exec: Option(
      fn(Instruction) ->
        Result(tuple(Starter(argument), Instruction), ChildStartError),
    ),
  )
}

type Child(argument) {
  Child(pid: Pid, argument: argument)
}

fn start_child(
  child_spec: ChildSpec(msg, argument_in, argument_out),
  argument: argument_in,
) -> Result(Child(argument_out), ChildStartError) {
  try channel =
    child_spec.start(argument)
    |> result.map_error(ChildStartError(None, _))

  Ok(Child(
    pid: process.pid(channel),
    // Merge the new child's pid into the argument to produce the new argument
    // used to start any remaining children.
    argument: child_spec.returning(argument, channel),
  ))
}

// TODO: more sophsiticated stopping of processes. i.e. give supervisors
// more time to shut down.
fn shutdown_child(pid: Pid, _spec: ChildSpec(msg, arg_1, arg_2)) -> Nil {
  process.send_exit(pid, process.Normal)
}

fn perform_instruction_for_child(
  argument: argument_in,
  instruction: Instruction,
  child_spec: ChildSpec(msg, argument_in, argument_out),
  child: Child(argument_out),
) -> Result(tuple(Child(argument_out), Instruction), ChildStartError) {
  let current = child.pid
  case instruction {
    // This child is older than the StartFrom target, we don't need to
    // restart it
    StartFrom(target) if target != current -> Ok(tuple(child, instruction))

    // This pid either is the cause of the problem, or we have the StartAll
    // instruction. Either way it and its younger siblings need to be restarted.
    _ -> {
      shutdown_child(current, child_spec)
      try child = start_child(child_spec, argument)
      Ok(tuple(child, StartAll))
    }
  }
}

fn add_child_to_starter(
  starter: Starter(argument_in),
  child_spec: ChildSpec(msg, argument_in, argument_out),
  child: Child(argument_out),
) -> Starter(argument_out) {
  let starter = fn(instruction) {
    // Restart the older children. We use `try` to return early if the older
    // children failed to start
    try tuple(starter, instruction) = case starter.exec {
      Some(start) -> start(instruction)
      None -> Ok(tuple(starter, instruction))
    }

    // Perform the instruction, restarting the child as required
    try tuple(child, instruction) =
      perform_instruction_for_child(
        starter.argument,
        instruction,
        child_spec,
        child,
      )

    // Create a new starter for the next time the supervisor needs to restart
    let starter = add_child_to_starter(starter, child_spec, child)

    Ok(tuple(starter, instruction))
  }

  Starter(exec: Some(starter), argument: child.argument)
}

fn start_and_add_child(
  state: Starter(argument_0),
  child_spec: ChildSpec(msg, argument_0, argument_1),
) -> Children(argument_1) {
  case start_child(child_spec, state.argument) {
    Ok(child) -> Ready(add_child_to_starter(state, child_spec, child))
    Error(reason) -> Failed(reason)
  }
}

// TODO: document
pub fn add(
  children: Children(argument),
  child_spec: ChildSpec(msg, argument, new_argument),
) -> Children(new_argument) {
  case children {
    // If one of the previous children has failed then we cannot continue
    Failed(fail) -> Failed(fail)

    // If everything is OK so far then we can add the child
    Ready(state) -> start_and_add_child(state, child_spec)
  }
}

// TODO: test
// TODO: document
pub fn worker(
  start: fn(argument) -> Result(Sender(msg), StartError),
) -> ChildSpec(msg, argument, argument) {
  ChildSpec(start: start, returning: fn(argument, _channel) { argument })
}

// TODO: test
// TODO: document
pub fn returning(
  child: ChildSpec(msg, argument_a, argument_b),
  updater: fn(argument_a, Sender(msg)) -> argument_c,
) -> ChildSpec(msg, argument_a, argument_c) {
  ChildSpec(start: child.start, returning: updater)
}

fn init(
  spec: Spec(argument, return),
) -> actor.InitResult(State(return), Message) {
  // Create a channel so that we can asynchronously retry restarting when we
  // fail to bring an exited child
  let tuple(retry_sender, retry_receiver) = process.new_channel()
  let retry_receiver = process.map_receiver(retry_receiver, RetryRestart)

  // Trap exits so that we get a message when a child crashes
  let exit_receiver =
    process.trap_exits()
    |> process.map_receiver(Exit)

  // Combine receivers
  let receiver =
    exit_receiver
    |> process.merge_receiver(retry_receiver)

  // Start any children
  let result =
    Starter(argument: spec.argument, exec: None)
    |> Ready
    |> spec.init

  // Pass back up the result
  case result {
    Ready(starter) -> {
      let restarts =
        intensity_tracker.new(
          limit: spec.max_frequency,
          period: spec.frequency_period,
        )
      let state =
        State(
          starter: starter,
          restarts: restarts,
          retry_restart_channel: retry_sender,
        )
      actor.Ready(state, Some(receiver))
    }
    Failed(reason) -> {
      // TODO: refine error type
      let reason = process.Abnormal(dynamic.from(reason))
      actor.Failed(reason)
    }
  }
}

type HandleExitError {
  RestartFailed(pid: Pid, restarts: IntensityTracker)
  TooManyRestarts
}

fn handle_exit(pid: process.Pid, state: State(a)) -> actor.Next(State(a)) {
  let outcome = {
    // If we are handling an exit then we must have some children
    assert Some(start) = state.starter.exec

    // Check to see if there has been too many restarts in this period
    try restarts =
      state.restarts
      |> intensity_tracker.add_event
      |> result.map_error(fn(_) { TooManyRestarts })

    // Restart the exited child and any following children
    try tuple(starter, _) =
      start(StartFrom(pid))
      |> result.map_error(fn(e: ChildStartError) {
        RestartFailed(option.unwrap(e.previous_pid, pid), restarts)
      })

    Ok(State(..state, starter: starter, restarts: restarts))
  }

  case outcome {
    Ok(state) -> actor.Continue(state)
    Error(RestartFailed(failed_child, restarts)) -> {
      // Asynchronously enqueue the restarting of this child again as we were
      // unable to restart them this time. We do this asynchronously as we want
      // to have a chance to handle any system messages that have come in.
      process.send(state.retry_restart_channel, failed_child)
      let state = State(..state, restarts: restarts)
      actor.Continue(state)
    }
    Error(TooManyRestarts) ->
      actor.Stop(process.Abnormal(dynamic.from(TooManyRestarts)))
  }
}

fn loop(message: Message, state: State(argument)) -> actor.Next(State(argument)) {
  case message {
    Exit(process.Exit(pid: pid, ..)) | RetryRestart(pid) ->
      handle_exit(pid, state)
  }
}

// TODO: document
pub fn start_spec(spec: Spec(a, b)) -> Result(Sender(Message), StartError) {
  actor.start_spec(actor.Spec(
    init: fn() { init(spec) },
    loop: loop,
    init_timeout: 60_000,
  ))
}

// TODO: document
pub fn start(
  init: fn(Children(Nil)) -> Children(a),
) -> Result(Sender(Message), StartError) {
  start_spec(Spec(
    init: init,
    argument: Nil,
    max_frequency: 5,
    frequency_period: 1,
  ))
}

// TODO: document
pub type ApplicationStartMode {
  Normal
  Takeover(Node)
  Failover(Node)
}
