import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/function
import gleam/int
import gleam/otp/actor
import gleam/otp/system
import gleam/result
import gleeunit/should

pub fn get_state_test() {
  let assert Ok(subject) =
    actor.start("Test state", fn(_msg, state) { actor.continue(state) })

  subject
  |> process.subject_owner
  |> system.get_state
  |> should.equal(dynamic.from("Test state"))
}

@external(erlang, "sys", "get_status")
fn get_status(a: Pid) -> Dynamic

pub fn get_status_test() {
  let assert Ok(subject) =
    actor.start(Nil, fn(_msg, state) { actor.continue(state) })

  subject
  |> process.subject_owner
  |> get_status
  // TODO: assert something about the response
}

pub fn failed_init_test() {
  let server =
    process.start(linked: False, running: fn() {
      actor.Spec(
        init: fn() { actor.Failed("not enough wiggles") },
        loop: fn(_msg, state) { actor.continue(state) },
        init_timeout: 10,
      )
      |> actor.start_spec
      |> result.is_error
      |> should.be_true
    })

  // Check that our server is alive
  process.is_alive(server)
  |> should.be_true

  // Create a monitor to check if our monitor is down
  let monitor = process.monitor_process(server)
  let selector =
    process.new_selector()
    |> process.selecting_process_down(monitor, Mon)

  let result = case process.select(selector, 500) {
    // Child got shutdown
    Ok(Mon(_down)) -> Error(dynamic.from("init_failed"))

    // Child did not finish initialising in time
    _ -> {
      Error(dynamic.from("timeout"))
    }
  }

  result
  |> should.equal(Error(dynamic.from("init_failed")))

  // Check that the server is not longer running
  process.is_alive(server)
  |> should.be_false

  // teardown
  process.demonitor_process(monitor)
}

pub fn timed_out_init_test() {
  process.trap_exits(True)
  let exit_selector =
    process.new_selector()
    |> process.selecting_trapped_exits(function.identity)

  let result =
    actor.Spec(
      init: fn() {
        process.sleep(1000)
        panic as "should not be reached"
      },
      loop: fn(_msg, _state) { panic as "should not be reached" },
      init_timeout: 1,
    )
    |> actor.start_spec

  // Check that the exit isn't unhandled: it should be handled by start_spec.
  // Stop trapping exits before asserting, to avoid interfering with other tests.
  let exit = process.select(exit_selector, 10)
  process.trap_exits(False)

  result |> should.equal(Error(actor.InitTimeout))
  exit |> should.equal(Error(Nil))
}

pub fn suspend_resume_test() {
  let assert Ok(subject) =
    actor.start(0, fn(_msg, iter) { actor.continue(iter + 1) })

  // Suspend process
  subject
  |> process.subject_owner
  |> system.suspend
  |> should.equal(Nil)

  // This normal message will not be handled yet so the state remains 0
  actor.send(subject, "hi")

  // System messages are still handled
  subject
  |> process.subject_owner
  |> system.get_state
  |> should.equal(dynamic.from(0))

  // Resume process
  subject
  |> process.subject_owner
  |> system.resume
  |> should.equal(Nil)

  // The queued regular message has been handled so the state has incremented
  subject
  |> process.subject_owner
  |> system.get_state
  |> should.equal(dynamic.from(1))
}

pub fn subject_test() {
  let assert Ok(subject) =
    actor.start("state 1", fn(msg, _state) { actor.continue(msg) })

  subject
  |> process.subject_owner
  |> system.get_state()
  |> should.equal(dynamic.from("state 1"))

  actor.send(subject, "state 2")

  subject
  |> process.subject_owner
  |> system.get_state()
  |> should.equal(dynamic.from("state 2"))
}

pub fn unexpected_message_test() {
  // Quieten the logger
  logger_set_primary_config(
    atom.create_from_string("level"),
    atom.create_from_string("error"),
  )

  let assert Ok(subject) =
    actor.start("state 1", fn(msg, _state) { actor.continue(msg) })

  subject
  |> process.subject_owner
  |> system.get_state()
  |> should.equal(dynamic.from("state 1"))

  raw_send(process.subject_owner(subject), "Unexpected message 1")
  actor.send(subject, "state 2")
  raw_send(process.subject_owner(subject), "Unexpected message 2")

  subject
  |> process.subject_owner
  |> system.get_state()
  |> should.equal(dynamic.from("state 2"))
}

pub fn unexpected_message_handled_test() {
  let assert Ok(subject) =
    actor.start_spec(actor.Spec(
      init: fn() {
        let selector =
          process.new_selector()
          |> process.selecting_anything(function.identity)
        actor.Ready(dynamic.from("init"), selector)
      },
      loop: fn(msg, _state) { actor.continue(msg) },
      init_timeout: 10,
    ))

  raw_send(process.subject_owner(subject), "Unexpected message 1")

  subject
  |> process.subject_owner
  |> system.get_state()
  |> should.equal(dynamic.from("Unexpected message 1"))
}

type ActorMessage {
  UserMessage(String)
  Unknown(Dynamic)
  SetStringSelector(
    reply: Subject(Subject(String)),
    mapper: fn(String) -> ActorMessage,
  )
  SetIntSelector(reply: Subject(Subject(Int)), mapper: fn(Int) -> ActorMessage)
}

pub fn replace_selector_test() {
  let assert Ok(subject) =
    actor.start("init", fn(msg: ActorMessage, state) {
      case msg {
        UserMessage(string) -> actor.continue("user message: " <> string)
        Unknown(val) ->
          actor.continue("unknown message: " <> dynamic.classify(val))
        SetStringSelector(reply, mapper) -> {
          let #(subject, selector) = mapped_selector(mapper)
          process.send(reply, subject)

          actor.continue(state)
          |> actor.with_selector(selector)
        }
        SetIntSelector(reply, mapper) -> {
          let #(subject, selector) = mapped_selector(mapper)
          process.send(reply, subject)

          actor.continue(state)
          |> actor.with_selector(selector)
        }
      }
    })

  // Send initial user message to original subject
  process.send(subject, UserMessage("test 1"))
  // Check state
  get_actor_state(subject)
  |> should.equal(dynamic.from("user message: test 1"))

  // Get a new subject with string selector
  let str_subj = process.call(subject, SetStringSelector(_, UserMessage), 1000)
  // Send to new string subject
  process.send(str_subj, "test 2")
  // Check state
  get_actor_state(subject)
  |> should.equal(dynamic.from("user message: test 2"))

  // Get a new subject with int selector
  let int_subj =
    process.call(
      subject,
      SetIntSelector(_, fn(n: Int) { UserMessage("test " <> int.to_string(n)) }),
      1000,
    )
  // Send to new int subject
  process.send(int_subj, 3)
  // Check state
  get_actor_state(subject)
  |> should.equal(dynamic.from("user message: test 3"))

  // Try to send to old string subject
  process.send(str_subj, "test 4")
  // Check state
  get_actor_state(subject)
  |> should.equal(dynamic.from("unknown message: String"))
}

type ActorExitMessage {
  Shutdown(reason: process.ExitReason)
  GetPid(reply: Subject(Result(Pid, Nil)))
}

pub fn exit_actor_normally_test() {
  // We don't need to create a server and monitor it. An exit with reason
  // "normal" won't crash our whole test suite.
  //
  // More information: https://www.erlang.org/doc/apps/erts/erlang#exit/2
  let assert Ok(actor_exits_normal) =
    actor.start(Nil, fn(message: ActorExitMessage, state) {
      case message {
        Shutdown(reason) -> {
          actor.Stop(reason)
        }
        GetPid(client) -> {
          let self = process.self()
          process.send(client, Ok(self))
          actor.continue(state)
        }
      }
    })

  let assert Ok(actor_pid) = process.call(actor_exits_normal, GetPid, 10)

  // Check that the actor is still alive
  process.is_alive(actor_pid)
  |> should.be_true

  let assert Ok(actor_pid) = process.call(actor_exits_normal, GetPid, 10)
  process.send(actor_exits_normal, Shutdown(process.Normal))

  // Check that the actor has exited after the Shutdown message
  process.is_alive(actor_pid)
  |> should.be_false
}

pub fn exit_actor_abnormal_test() {
  let exit_type = process.Abnormal("por que maria?")
  let server = init_server_exit(exit_type)

  // check that server is still alive
  process.is_alive(server)
  |> should.be_true

  let monitor = process.monitor_process(server)
  let selector =
    process.new_selector()
    |> process.selecting_process_down(monitor, Mon)

  let result = case process.select(selector, 500) {
    // Child got shutdown
    Ok(Mon(down)) -> Error(down.reason)

    // Child did not finish initialising in time
    _ -> {
      Error(dynamic.from("timeout"))
    }
  }

  result
  |> should.equal(Error(dynamic.from(exit_type)))

  // server shouldn't be alive because our Actor got an exit signal
  // with a Abnormal(reason).
  process.is_alive(server)
  |> should.be_false

  // teardown
  process.demonitor_process(monitor)
}

pub fn exit_actor_kill_test() {
  let exit_type = process.Killed
  let server = init_server_exit(exit_type)

  // check that server is still alive
  process.is_alive(server)
  |> should.be_true

  let monitor = process.monitor_process(server)
  let selector =
    process.new_selector()
    |> process.selecting_process_down(monitor, Mon)

  let result = case process.select(selector, 500) {
    // Child got shutdown
    Ok(Mon(down)) -> Error(down.reason)

    // Child did not finish initialising in time
    _ -> {
      Error(dynamic.from("timeout"))
    }
  }

  result
  |> should.equal(Error(dynamic.from(exit_type)))

  // server shouldn't be alive because our actor got an exit signal
  // with a Killed reason (brute force killing a child process).
  process.is_alive(server)
  |> should.be_false

  // teardown
  process.demonitor_process(monitor)
}

fn mapped_selector(mapper: fn(a) -> ActorMessage) {
  let subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.selecting(subject, mapper)
    // Always create a selector that catches unknown messages
    |> process.selecting_anything(fn(data) {
      data
      |> dynamic.element(1, dynamic.dynamic)
      |> result.unwrap(dynamic.from("unknown"))
      |> Unknown
    })

  #(subject, selector)
}

fn get_actor_state(subject: Subject(a)) {
  subject
  |> process.subject_owner
  |> system.get_state
}

type Mon {
  Mon(process.ProcessDown)
}

fn init_server_exit(shutdown: process.ExitReason) -> process.Pid {
  // Actors use the option linked which means that if actor throws an exception
  // it will stop the execution of the link process. That's why we need to set
  // a "server" to run our Actor. The moment we send the Shutdown message to the
  // Actor, this will throw an exception and stop the execution of our "server"
  // without stoping the `gleam test` command.

  process.start(linked: False, running: fn() {
    let assert Ok(actor_subject) =
      actor.start(Nil, fn(message: ActorExitMessage, state) {
        case message {
          Shutdown(reason) -> {
            actor.Stop(reason)
          }
          GetPid(client) -> {
            let self = process.self()
            process.send(client, Ok(self))
            actor.continue(state)
          }
        }
      })

    let assert Ok(actor_pid) = process.call(actor_subject, GetPid, 10)

    // First we check that the actor is still alive
    process.is_alive(actor_pid)
    |> should.be_true

    // the actor has a link to our server which should make it crash
    // but it shouldn't be affecting our main test runner
    process.send(actor_subject, Shutdown(shutdown))

    // give some time to the actor to process the message
    process.sleep(50)
  })
}

@external(erlang, "erlang", "send")
fn raw_send(a: Pid, b: anything) -> anything

@external(erlang, "logger", "set_primary_config")
fn logger_set_primary_config(a: Atom, b: Atom) -> Nil
