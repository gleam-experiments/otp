import gleam/otp/process.{ExitReason, From, Message, Normal}
import gleam/should
import gleam/io
import gleam/result
import gleam/atom
import gleam/dynamic.{Dynamic}
import gleam/option.{Some}

external fn sleep(Int) -> Nil =
  "timer" "sleep"

pub fn is_alive_test() {
  let f = fn() { sleep(1000) }
  let pid = process.start(f)
  pid
  |> process.is_alive
  |> should.equal(True)
}

pub fn is_alive_dead_test() {
  let routine = fn() { Nil }
  let pid = process.start(routine)
  sleep(20)
  pid
  |> process.is_alive
  |> should.equal(False)
}

// pub fn make_opaque_test() {
//   let f = fn(handle: fn(x) -> x) {
//     fn(self) {
//       process.started(self)
//       assert Ok(Message(msg)) = process.receive(self, 1000)
//       handle(msg)
//       Normal
//     }
//   }
//   assert Ok(float_pid) = process.start(f(fn(x) { x +. 1. }))
//   assert Ok(int_pid) = process.start(f(fn(x) { x + 1 }))
//   // They can be compared now, they are the same type
//   process.make_opaque(float_pid) != process.make_opaque(int_pid)
// }
//pub fn async_send_test() {
//  assert Ok(
//    pid,
//  ) = process.start(
//    fn() {
//      self
//      |> process.receive(50)
//      |> should.equal(Ok(Message(1)))
//      self
//      |> process.receive(50)
//      |> should.equal(Ok(Message(2)))
//      self
//      |> process.receive(50)
//      |> should.equal(Ok(Message(3)))
//      Normal
//    },
//  )
//  let resp = process.async_send(pid, 1)
//  should.equal(resp, Nil)
//  let resp = process.async_send(pid, 2)
//  should.equal(resp, Nil)
//  let resp = process.async_send(pid, 3)
//  should.equal(resp, Nil)
//}
type EchoMessage(x) {
  EchoMessage(From(x), x)
}

//pub fn sync_send_test() {
//  assert Ok(
//    pid,
//  ) = process.start(
//    fn() {
//      assert Ok(Message(EchoMessage(from, x))) = process.receive(self, 50)
//      assert Nil = process.reply(from, x)
//      assert Ok(Message(EchoMessage(from, x))) = process.receive(self, 50)
//      assert Nil = process.reply(from, x)
//      assert Ok(Message(EchoMessage(from, x))) = process.receive(self, 50)
//      assert Nil = process.reply(from, x)
//      Normal
//    },
//  )
//  let resp = process.sync_send(pid, EchoMessage(_, 1), 50)
//  should.equal(resp, 1)
//  let resp = process.sync_send(pid, EchoMessage(_, 2), 50)
//  should.equal(resp, 2)
//  let resp = process.sync_send(pid, EchoMessage(_, 2.0), 50)
//  should.equal(resp, 2.0)
//}
//pub fn unsafe_downcast_send() {
//  let f = fn(handle: fn(x) -> x) {
//    fn() {
//      let Message(msg) = process.receive(self, 1000)
//      handle(msg)
//    }
//  }
//  assert Ok(float_pid) = process.start(f(fn(x) { x +. 1. }))
//  assert Ok(int_pid) = process.start(f(fn(x) { x + 1 }))
//  let opaque_pid = process.make_opaque(int_pid)
//  let fake_float_pid = process.unsafe_downcast(opaque_pid)
//  // They can be compared now, they are the same type
//  should.equal(float_pid, fake_float_pid)
//}
type HandleExit {
  HandleExit(exited: process.Pid, reason: ExitReason)
  Ping
}
// pub fn trap_exit_test() {
//   let linkee_routine = fn() { process.receive(self, 150) }
//   let linkee = process.start(linkee_routine)
//
//   let routine = fn(self) {
//     process.started(self)
//     let expected_exit_signal = HandleExit(process.make_opaque(linkee), Normal)
//     self
//     |> process.receive_forever
//     |> should.equal(Message(expected_exit_signal))
//     Normal
//   }
//
//   let spec = Spec(routine: routine, exit_trapper: Some(HandleExit))
//   assert Ok(_) = process.start_spec(spec)
//
//   process.async_send(linkee, Ping)
//   sleep(20)
// }
