import gleeunit/should
import gleam/otp/task
import gleam/otp/process

external fn sleep(Int) -> Nil =
  "timer" "sleep"

pub fn async_await_test() {
  let work = fn(x) {
    fn() {
      sleep(15)
      x
    }
  }

  // Spawn 3 tasks, performing 45ms work collectively
  let t1 = task.async(work(1))
  let t2 = task.async(work(2))
  let t3 = task.async(work(3))

  // Assert they run concurrently (not taking 45ms total)
  task.try_await(t1, 35)
  |> should.equal(Ok(1))
  task.try_await(t2, 5)
  |> should.equal(Ok(2))
  task.try_await(t3, 5)
  |> should.equal(Ok(3))
}
