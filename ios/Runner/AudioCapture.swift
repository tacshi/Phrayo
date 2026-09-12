import AVFoundation

/// The tap copies buffers; one serial queue owns file rotation, duration and conversion.
// Engine methods are called by the main-actor host; file/converter state is queue-owned.
final class AudioCapture: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let queue = DispatchQueue(label: "app.capyvibe.phrayo.capture")
  private var writer: AVAudioFile?
  private var converter: AVAudioConverter?
  private var urls = [URL]()
  private var frames: AVAudioFramePosition = 0
  private var segmentFrames: AVAudioFramePosition = 0
  private var rate = 48000.0
  private var paused = false
  private var accepting = false
  private var tapInstalled = false
  let folder: URL
  var onBuffer: ((Data, Double, Double) -> Void)?
  var onFailure: ((Error) -> Void)?
  init(folder: URL) { self.folder = folder }
  func start() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw appError("microphone_unavailable")
    }
    rate = format.sampleRate
    let output = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    guard let converter = AVAudioConverter(from: format, to: output) else {
      throw appError("microphone_unavailable")
    }
    self.converter = converter
    accepting = true
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
      [weak self] buffer, _ in
      guard let self,
        let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
      else { return }
      copy.frameLength = buffer.frameLength
      let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
      let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
      for i in 0..<src.count {
        if let s = src[i].mData, let d = dst[i].mData { memcpy(d, s, Int(src[i].mDataByteSize)) }
      }
      self.queue.async { self.consume(copy, output: output) }
    }
    tapInstalled = true
    engine.prepare()
    try engine.start()
  }
  private func consume(_ buffer: AVAudioPCMBuffer, output: AVAudioFormat) {
    guard accepting, !paused else { return }
    do {
      if writer == nil || segmentFrames >= Int64(rate * 30) {
        writer = nil
        let url = folder.appendingPathComponent(String(format: "%06d.caf", urls.count))
        writer = try AVAudioFile(
          forWriting: url, settings: buffer.format.settings,
          commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        urls.append(url)
        segmentFrames = 0
      }
      try writer?.write(from: buffer)
      frames += Int64(buffer.frameLength)
      segmentFrames += Int64(buffer.frameLength)
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: output,
        frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / rate + 32))!
      var supplied = false
      var error: NSError?
      converter?.convert(to: outputBuffer, error: &error) { _, status in
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
      }
      if let error { throw error }
      if let samples = outputBuffer.int16ChannelData?[0] {
        let count = Int(outputBuffer.frameLength)
        let data = Data(bytes: samples, count: count * 2)
        var sum = 0.0
        for i in 0..<count {
          let value = Double(samples[i]) / 32768
          sum += value * value
        }
        onBuffer?(data, Double(frames) / rate, sqrt(sum / Double(max(count, 1))))
      }
    } catch {
      accepting = false
      onFailure?(error)
    }
  }
  func setPaused(_ value: Bool) { queue.sync { paused = value } }
  func finish() async -> [URL] {
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    return await withCheckedContinuation { continuation in
      queue.async {
        self.accepting = false
        self.writer = nil
        continuation.resume(returning: self.urls)
      }
    }
  }
  static func export(_ urls: [URL], to destination: URL) async throws {
    guard !urls.isEmpty else { throw appError("no_audio") }
    let composition = AVMutableComposition()
    guard
      let track = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw appError("audio_save_failed") }
    var position = CMTime.zero
    for url in urls {
      let asset = AVURLAsset(url: url)
      guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
      let duration = try await asset.load(.duration)
      try track.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration), of: source, at: position)
      position = CMTimeAdd(position, duration)
    }
    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else { throw appError("audio_save_failed") }
    try await exporter.export(to: destination, as: .m4a)
  }
}
