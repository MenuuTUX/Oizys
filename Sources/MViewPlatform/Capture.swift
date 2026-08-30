import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// Swift binds ScreenCaptureKit callbacks. C owns queueing, buffer lifetimes, pixel
// access, encoding, transport, telemetry and all frame scheduling decisions.
private final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
    let output: OpaquePointer
    init?(_ driver: OpaquePointer, _ head: UInt8, _ queue: DispatchQueue) {
        guard let output = mview_output_create(driver, head, queue) else { return nil }
        self.output = output
    }
    deinit { mview_output_destroy(output) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first, let status = first[.status] as? NSNumber else { return }
        let displayed = (first[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let rects = dirtyRects(first)
        rects.withUnsafeBufferPointer {
            mview_output_enqueue(output, sampleBuffer, status.int32Value, displayed,
                                 $0.baseAddress, Int32($0.count))
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        "ScreenCaptureKit stopped: \(error.localizedDescription)".withCString { mview_output_fail(output, $0) }
    }
}

// What the compositor says moved. The stream is configured at the display's own pixel
// size, so these are already surface pixels and need no scaling; C bounds-checks every
// rect against the surface anyway and falls back to fingerprinting the whole frame if one
// does not fit, which is the only thing that stays correct if that assumption ever breaks.
// An empty list means "no rectangles reported", which is not the same as "nothing changed"
// and is passed through as a full pass.
private func dirtyRects(_ info: [SCStreamFrameInfo: Any]) -> [MViewDirtyRect] {
    guard let raw = info[.dirtyRects] as? [[String: Any]], !raw.isEmpty,
          raw.count <= Int(MVIEW_CAPTURE_MAX_RECTS) else { return [] }
    var out: [MViewDirtyRect] = []
    out.reserveCapacity(raw.count)
    for entry in raw {
        guard let rect = CGRect(dictionaryRepresentation: entry as CFDictionary) else { return [] }
        let r = rect.integral
        guard r.minX >= 0, r.minY >= 0, r.width > 0, r.height > 0 else { return [] }
        out.append(MViewDirtyRect(x: UInt32(r.minX), y: UInt32(r.minY),
                                  w: UInt32(r.width), h: UInt32(r.height)))
    }
    return out
}

private final class StartState {
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    var cancelled = false
    var ok = false
}

private final class Capture {
    let count: Int
    let worker = DispatchQueue(label: "org.mview.capture.serial", qos: .userInteractive)
    let ingest = DispatchQueue(label: "org.mview.capture.ingest", qos: .userInteractive)
    var streams: [SCStream] = []
    var outputs: [Int: CaptureDelegate] = [:]
    var timer: DispatchSourceTimer?
    init(_ count: Int) { self.count = count }
    func stop() {
        timer?.cancel(); timer = nil
        for output in outputs.values { mview_output_disable(output.output) }
        for stream in streams {
            let done = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
        ingest.sync {}
        worker.sync {}
        streams.removeAll(); outputs.removeAll()
    }
}

private func start(_ stream: SCStream) -> Bool {
    let state = StartState()
    stream.startCapture { error in
        state.lock.lock()
        state.ok = error == nil
        if state.cancelled && state.ok { stream.stopCapture(completionHandler: nil) }
        state.lock.unlock()
        state.done.signal()
    }
    if state.done.wait(timeout: .now() + 10) == .timedOut {
        state.lock.lock(); state.cancelled = true; state.lock.unlock()
        stream.stopCapture(completionHandler: nil)
        return false
    }
    state.lock.lock(); defer { state.lock.unlock() }
    return state.ok
}

private func shareable() -> SCShareableContent? {
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { value, _ in
        lock.lock(); content = value; lock.unlock(); done.signal()
    }
    guard done.wait(timeout: .now() + 10) == .success else { return nil }
    lock.lock(); defer { lock.unlock() }
    return content
}

@_cdecl("mview_capture_start")
func captureStart(_ ids: UnsafePointer<UInt32>?, _ count: Int32, _ driver: OpaquePointer?,
                  _ error: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> UnsafeMutableRawPointer? {
    guard let ids, let driver, count > 0, count <= 2 else { return nil }
    func fail(_ text: String) { if let error, capacity > 0 { text.withCString { _ = strlcpy(error, $0, capacity) } } }
    guard let content = shareable() else {
        fail("ScreenCaptureKit returned no content; grant Screen Recording access"); return nil
    }
    let capture = Capture(Int(count))
    let config = mview_config()!.pointee
    for head in 0..<Int(count) where ids[head] != 0 {
        guard let display = content.displays.first(where: { $0.displayID == ids[head] }),
              display.width == 1920, display.height == 1080 else {
            fail("Head \(head) is missing or not 1920x1080; check mirroring"); capture.stop(); return nil
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 1920; configuration.height = 1080
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: config.capture_fps)
        configuration.queueDepth = Int(config.capture_queue_depth)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true; configuration.capturesAudio = false
        guard let delegate = CaptureDelegate(driver, UInt8(head), capture.worker) else {
            fail("Could not allocate capture state"); capture.stop(); return nil
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: delegate)
        capture.outputs[head] = delegate; capture.streams.append(stream)
        do { try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: capture.ingest) }
        catch { fail(error.localizedDescription); capture.stop(); return nil }
        guard start(stream) else { fail("Head \(head) capture did not start within 10 seconds"); capture.stop(); return nil }
    }
    return Unmanaged.passRetained(capture).toOpaque()
}

private func instance(_ raw: UnsafeRawPointer) -> Capture { Unmanaged<Capture>.fromOpaque(raw).takeUnretainedValue() }

@_cdecl("mview_capture_start_refresh_clock")
func captureClock(_ raw: UnsafeMutableRawPointer?, _ driver: OpaquePointer?, _ heads: Int32, _ hz: Int32) {
    guard let raw, let driver, hz > 0 else { return }
    let capture = instance(raw)
    capture.timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: capture.worker)
    timer.schedule(deadline: .now() + .milliseconds(200), repeating: .nanoseconds(1_000_000_000 / Int(hz)), leeway: .milliseconds(2))
    timer.setEventHandler { [weak capture] in
        guard let capture, capture.outputs.values.allSatisfy({ mview_output_failure($0.output) == nil }) else { return }
        if mview_driver_service_control(driver) < 0 {
            for output in capture.outputs.values { mview_output_fail(output.output, "control session keepalive failed") }
            return
        }
        for head in 0..<min(Int(heads), capture.count) {
            guard let output = capture.outputs[head], mview_driver_head_is_armed(driver, UInt8(head)) != 0,
                  mview_output_needs_refresh(output.output) != 0 else { continue }
            if mview_driver_refresh_head(driver, UInt8(head)) < 0 { mview_output_fail(output.output, "cached desktop refresh failed") }
        }
    }
    capture.timer = timer; timer.resume()
}

@_cdecl("mview_capture_frames")
func captureFrames(_ raw: UnsafeRawPointer?, _ head: Int32) -> Int32 {
    guard let raw, let output = instance(raw).outputs[Int(head)] else { return 0 }
    return mview_output_frames(output.output)
}
@_cdecl("mview_capture_failure")
func captureFailure(_ raw: UnsafeRawPointer?, _ head: Int32) -> UnsafePointer<CChar>? {
    guard let raw, let output = instance(raw).outputs[Int(head)] else { return nil }
    return mview_output_failure(output.output)
}
@_cdecl("mview_capture_head_count")
func captureCount(_ raw: UnsafeRawPointer?) -> Int32 { raw.map { Int32(instance($0).count) } ?? 0 }
@_cdecl("mview_capture_profile_report")
func captureReport(_ raw: UnsafeMutableRawPointer?, _ title: UnsafePointer<CChar>?) {
#if !MVIEW_PRODUCTION
    guard let raw else { return }
    let capture = instance(raw)
    capture.worker.sync {
        if mview_profile_active != 0 { mview_profile_report(title) }
        else if let title { puts(title) }
        for head in 0..<capture.count { if let output = capture.outputs[head] { mview_output_report(output.output) } }
        if mview_profile_active != 0 { mview_profile_reset() }
    }
#endif
}
@_cdecl("mview_capture_stop")
func captureStop(_ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    let capture = Unmanaged<Capture>.fromOpaque(raw).takeRetainedValue()
    capture.stop()
}
