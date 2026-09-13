import Foundation

@MainActor
private final class PendingDrain {
  var continuation: CheckedContinuation<[URL], Never>?
  var calls = 0

  func run() async -> [URL] {
    calls += 1
    return await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilDraining() async {
    while continuation == nil { await Task.yield() }
  }

  func complete() {
    continuation?.resume(returning: [URL(fileURLWithPath: "/tmp/capture.caf")])
    continuation = nil
  }
}

@main
struct RecordingDrainTests {
  @MainActor
  static func main() async {
    let drain = RecordingDrain()
    let pending = PendingDrain()
    var processingStarted = false
    let stop = Task {
      if let _ = await drain.finish({ await pending.run() }) {
        processingStarted = true
      }
    }
    await pending.waitUntilDraining()
    var cancelFinished = false
    let cancel = Task {
      await drain.discard()
      cancelFinished = true
    }
    while !drain.discarded { await Task.yield() }
    precondition(!cancelFinished, "Cancel must wait for capture cleanup")
    pending.complete()
    await stop.value
    await cancel.value
    precondition(cancelFinished && !processingStarted,
      "An automatic stop must not process a recording discarded during drain")
    precondition(pending.calls == 1)
    print("PASS: cancellation during automatic stop drains once and prevents processing")

    let discarded = RecordingDrain()
    await discarded.discard()
    let skipped = await discarded.finish { preconditionFailure("Capture was already discarded") }
    precondition(skipped == nil)
    print("PASS: cancellation before a queued stop prevents draining and processing")

    let normal = RecordingDrain()
    let normalPending = PendingDrain()
    let first = Task { await normal.finish { await normalPending.run() } }
    let second = Task { await normal.finish { await normalPending.run() } }
    await normalPending.waitUntilDraining()
    normalPending.complete()
    let firstResult = await first.value
    let secondResult = await second.value
    precondition(firstResult?.count == 1 && firstResult == secondResult)
    precondition(normalPending.calls == 1)
    print("PASS: ordinary and repeated stops retain drained audio for processing")

    let next = RecordingDrain()
    let nextResult = await next.finish { [URL(fileURLWithPath: "/tmp/next.caf")] }
    precondition(nextResult?.count == 1 && !next.discarded)
    print("PASS: a new recording has independent cancellation ownership")
  }
}
