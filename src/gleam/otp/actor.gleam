import gleam/erlang/process.{Pid, Selector, Subject}
import gleam/otp/process.{
  Abnormal, DebugState, ExitReason, GetState, GetStatus, Mode, Resume, Running, Suspend,
  Suspended, SystemMessage,
} as legacy
import gleam/io
import gleam/erlang/atom
import gleam/dynamic.{Dynamic}

type Message(message) {
  /// A regular message excepted by the process
  Message(message)

  /// An OTP system message, for debugging or maintenance
  System(SystemMessage)

  /// An unexpected message
  Unexpected(Dynamic)
}

type UnexpectedMessageError {
  UnexpectedMessage(Dynamic)
}

/// The type used to indicate what to do after handling a message.
///
pub type Next(state) {
  /// Continue handling messages.
  ///
  Continue(state)

  /// Stop handling messages and shut down.
  ///
  Stop(ExitReason)
}

/// The type used to indicate whether an actor has started successfully or not.
///
pub type InitResult(state, message) {
  /// The actor has successfully initialised. The actor can start handling
  /// messages and actor's channel sender can be returned to the parent
  /// process.
  ///
  Ready(state: state, selector: Selector(message))

  // TODO: exit reason
  // Failed(ExitReason)
  /// The actor has failed to initialise. The actor shuts down and an error is
  /// returned to the parent process.
  ///
  Failed(Dynamic)
}

type Self(state, msg) {
  Self(
    mode: Mode,
    parent: Pid,
    state: state,
    selector: Selector(Message(msg)),
    debug_state: DebugState,
    message_handler: fn(msg, state) -> Next(state),
  )
}

/// This data structure holds all the values required by the `start_spec`
/// function in order to create an actor.
///
/// If you do not need to configure the initialisation behaviour of your actor
/// consider using the `start` function.
///
pub type Spec(state, msg) {
  Spec(
    /// The initialisation functionality for the actor. This function is called
    /// just after the actor starts but before the channel sender is returned
    /// to the parent.
    ///
    /// This function is used to ensure that any required data or state is
    /// correct. If this function returns an error it means that the actor has
    /// failed to start and an error is returned to the parent.
    ///
    init: fn() -> InitResult(state, msg),
    /// How many milliseconds the `init` function has to return before it is
    /// considered to have taken too long and failed.
    ///
    init_timeout: Int,
    /// This function is called to handle each message that the actor receives.
    ///
    loop: fn(msg, state) -> Next(state),
  )
}

// TODO: Check needed functionality here to be OTP compatible
fn exit_process(reason: ExitReason) -> ExitReason {
  // TODO
  reason
}

fn receive_message(self: Self(state, msg)) -> Message(msg) {
  let selector = case self.mode {
    // When suspended we only respond to system messages
    Suspended ->
      process.new_selector()
      |> selecting_system_messages

    // When running we respond to all messages
    Running ->
      // We add the handler for unexpected messages first so that the user
      // supplied selector can override it if desired
      process.new_selector()
      |> process.selecting_anything(Unexpected)
      |> process.merge_selector(self.selector)
      |> selecting_system_messages
  }

  process.select_forever(selector)
}

fn selecting_system_messages(
  selector: Selector(Message(msg)),
) -> Selector(Message(msg)) {
  selector
  |> process.selecting_record3(
    atom.create_from_string("system"),
    convert_system_message,
  )
}

external fn convert_system_message(Dynamic, Dynamic) -> Message(msg) =
  "gleam_otp_external" "convert_system_message"

fn process_status_info(self: Self(state, msg)) -> legacy.StatusInfo {
  legacy.StatusInfo(
    module: atom.create_from_string("gleam@otp@actor"),
    parent: self.parent,
    mode: self.mode,
    debug_state: self.debug_state,
    state: dynamic.from(self.state),
  )
}

fn loop(self: Self(state, msg)) -> ExitReason {
  case receive_message(self) {
    System(GetState(callback)) -> {
      callback(dynamic.from(self.state))
      loop(self)
    }

    System(Resume(callback)) -> {
      callback()
      loop(Self(..self, mode: Running))
    }

    System(Suspend(callback)) -> {
      callback()
      loop(Self(..self, mode: Suspended))
    }

    System(GetStatus(callback)) -> {
      callback(process_status_info(self))
      loop(self)
    }

    // TODO: test
    Unexpected(message) -> {
      io.debug(#("unexpected", message))
      exit_process(Abnormal(dynamic.from(UnexpectedMessage(message))))
    }

    Message(msg) ->
      case self.message_handler(msg, self.state) {
        Stop(reason) -> exit_process(reason)
        Continue(state) -> loop(Self(..self, state: state))
      }

    System(_unsupported_system_message) -> {
      io.println("Gleam Action: unsupported system message dropped")
      loop(self)
    }
  }
}

fn initialise_actor(
  spec: Spec(state, msg),
  ack: Subject(Result(Subject(msg), ExitReason)),
) {
  let subject = process.new_subject()
  case spec.init() {
    Ready(state, selector) -> {
      let selector =
        process.new_selector()
        |> process.selecting(subject, Message)
        |> process.merge_selector(process.map_selector(selector, Message))
      // Signal to parent that the process has initialised successfully
      process.send(ack, Ok(subject))
      // Start message receive loop
      let self =
        Self(
          state: state,
          parent: process.subject_owner(ack),
          selector: selector,
          message_handler: spec.loop,
          debug_state: legacy.debug_state([]),
          mode: Running,
        )
      loop(self)
    }

    Failed(reason) -> {
      process.send(ack, Error(Abnormal(reason)))
      exit_process(Abnormal(reason))
    }
  }
}

pub type StartError {
  InitTimeout
  InitFailed(ExitReason)
  InitCrashed(Dynamic)
}

/// The result of starting a Gleam actor.
///
/// This type is compatible with Gleam supervisors. If you wish to convert it
/// to a type compatible with Erlang supervisors see the `ErlangStartResult`
/// type and `erlang_start_result` function.
///
pub type StartResult(msg) =
  Result(Subject(msg), StartError)

/// An Erlang supervisor compatible process start result.
///
/// If you wish to convert this into a `StartResult` compatible with Gleam
/// supervisors see the `from_erlang_start_result` and `wrap_erlang_starter`
/// functions.
///
pub type ErlangStartResult =
  Result(Pid, Dynamic)

/// Convert a Gleam actor start result into an Erlang supervisor compatible
/// process start result.
///
pub fn to_erlang_start_result(res: StartResult(msg)) -> ErlangStartResult {
  case res {
    Ok(x) -> Ok(process.subject_owner(x))
    Error(x) -> Error(dynamic.from(x))
  }
}

type StartInitMessage(msg) {
  Ack(Result(Subject(msg), ExitReason))
  Mon(process.ProcessDown)
}

// TODO: test init_timeout. Currently if we test it eunit prints an error from
// the process death. How do we avoid this?
//
/// Start an actor from a given specification. If the actor's `init` function
/// returns an error or does not return within `init_timeout` then an error is
/// returned.
///
/// If you do not need to specify the initialisation behaviour of your actor
/// consider using the `start` function.
///
pub fn start_spec(spec: Spec(state, msg)) -> Result(Subject(msg), StartError) {
  let ack_subject = process.new_subject()

  let child =
    process.start(
      linked: True,
      running: fn() { initialise_actor(spec, ack_subject) },
    )

  let selector =
    process.new_selector()
    |> process.selecting(ack_subject, Ack)
    |> process.selecting_process_down(process.monitor_process(child), Mon)

  case process.select(selector, spec.init_timeout) {
    // Child started OK
    Ok(Ack(Ok(channel))) -> Ok(channel)

    // Child initialiser returned an error
    Ok(Ack(Error(reason))) -> Error(InitFailed(reason))

    // Child went down while initialising
    Ok(Mon(down)) -> Error(InitCrashed(down.reason))

    // Child did not finish initialising in time
    Error(Nil) -> {
      process.kill(child)
      Error(InitTimeout)
    }
  }
}

/// Start an actor with a given initial state and message handling loop
/// function.
///
/// This function returns a `Result` but it will always be `Ok` so it is safe
/// to use with `assert` if you are not starting this actor as part of a
/// supervision tree.
///
/// If you wish to configure the initialisation behaviour of a new actor see
/// the `Spec` record and the `start_spec` function.
///
pub fn start(
  state: state,
  loop: fn(msg, state) -> Next(state),
) -> Result(Subject(msg), StartError) {
  start_spec(Spec(
    init: fn() { Ready(state, process.new_selector()) },
    loop: loop,
    init_timeout: 5000,
  ))
}

/// Send a message over a given channel.
///
/// This is a re-export of `process.send`, for the sake of convenience.
///
pub fn send(subject: Subject(msg), msg: msg) -> Nil {
  process.send(subject, msg)
}

// TODO: test
/// Send a synchronous message and wait for a response from the receiving
/// process.
///
/// If a reply is not received within the given timeout then the sender process
/// crashes. If you wish receive a `Result` rather than crashing see the
/// `process.try_call` function.
///
/// This is a re-export of `process.call`, for the sake of convenience.
///
pub fn call(
  selector: Subject(message),
  make_message: fn(Subject(reply)) -> message,
  timeout: Int,
) -> reply {
  process.call(selector, make_message, timeout)
}
