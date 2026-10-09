// Record one window of an app, a rectangle of the screen, or both together, until interrupted.
//
//   winrec <pid> <out.mov> [window title]                 the window with that title; with no title, the app's largest
//   winrec rect <x,y,w,h> <out.mov>                       a rectangle of the screen, in global points from the top left
//   winrec item <pid> <out.mov>                           an app's menu bar icon, followed as it moves
//   winrec <pid> <out.mov> <title> rect|item … <out2.mov>     a window and one of the above, on one clock
//
// A window is captured by itself, at two pixels per point, without its shadow and without the pointer.
// Other windows passing in front of it are not in the picture, so a take can be recorded while the Mac
// is in use. The rectangle form is for what is not an app window: its icon in the menu bar. It records
// whatever is in that rectangle, so keep it to the icon's own frame (tools/itemrect gives it).
// The icon form asks the accessibility API where the icon is before every screenshot: an icon that shows
// figures changes width as they change, the menu bar shuffles to make room, and a fixed rectangle soon
// has half the wing in it and half of the neighbour. The picture is 24 points wider than the icon was at
// the start, so there is room for it to grow; what lies past the icon's own right edge is the neighbour,
// so the icon's width at each moment is written beside the movie as <out>.widths.json ([seconds, points])
// and the compositor shows only that much.
// A frame is written only when the picture changed: the files are variable frame rate.
//
// Three things here were each learnt from a lost take:
//  - Screenshots, not a capture stream. A stream makes macOS replace the window's close, minimise and
//    zoom buttons with its purple "being shared" control, and that control is then in every frame.
//    The price is the frame rate, about 18 a second for one target: movement that has to look smooth
//    is recorded slowly and sped up in the edit.
//  - Two targets go through one process. Two recorders running at once both got no screenshots at all.
//  - Stopping does not wait for the capture loop, and a screenshot that has not come back in half a
//    second is given up on. Under a heavy CPU load a request can fail to return, and a recorder that
//    was only told to stop left an empty file behind.
import AppKit
import AVFoundation
import ScreenCaptureKit

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
let usage = "usage: winrec <pid> <out.mov> [window title]  |  winrec rect <x,y,w,h> <out.mov>  |  winrec item <pid> <out.mov>  |  winrec <pid> <out.mov> <title> rect|item … <out2.mov>"

enum Source { case window(pid: pid_t, title: String?), rect(CGRect), item(pid_t) }

/// The frame of an app's menu bar icon, in global points from the top left.
func itemFrame(_ pid: pid_t) -> CGRect? {
    var bar: CFTypeRef?, kids: CFTypeRef?, v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXExtrasMenuBar" as CFString, &bar) == .success else { return nil }
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
    guard let item = (kids as? [AXUIElement])?.first else { return nil }
    var p = CGPoint.zero, size = CGSize.zero
    if AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    return size.width > 0 ? CGRect(origin: p, size: size) : nil
}
var requests: [(Source, URL)] = []
var args = Array(CommandLine.arguments.dropFirst())
func takeRect() {
    guard args.count >= 3 else { fail(usage) }
    if args[0] == "item" {
        guard let pid = pid_t(args[1]) else { fail(usage) }
        requests.append((.item(pid), URL(fileURLWithPath: args[2])))
    } else {
        let n = args[1].split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { fail("the rectangle is x,y,w,h") }
        requests.append((.rect(CGRect(x: n[0], y: n[1], width: n[2], height: n[3])), URL(fileURLWithPath: args[2])))
    }
    args.removeFirst(3)
}
let regions: Set<String> = ["rect", "item"]
if let first = args.first, regions.contains(first) { takeRect() } else {
    guard args.count >= 2, let pid = pid_t(args[0]) else { fail(usage) }
    let title: String? = args.count > 2 && !regions.contains(args[2]) ? args[2] : nil
    requests.append((.window(pid: pid, title: title), URL(fileURLWithPath: args[1])))
    args.removeFirst(title == nil ? 2 : 3)
    if let next = args.first, regions.contains(next) { takeRect() }
}
_ = CGMainDisplayID()                                   // opens the window server connection

nonisolated(unsafe) var stopping = false
nonisolated(unsafe) var finish: (() -> Void)? = nil
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler {
    stopping = true
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { if let finish { finish() } else { exit(0) } }
}
interrupt.resume()

/// One screenshot, or nil if it has not come back within half a second.
func shot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async -> CVPixelBuffer? {
    await withTaskGroup(of: CVPixelBuffer?.self) { group in
        group.addTask { (try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config))?.imageBuffer }
        group.addTask { try? await Task.sleep(for: .milliseconds(500)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

nonisolated(unsafe) var widths: [[Double]] = []          // [seconds, points] each time the followed icon changes width
nonisolated(unsafe) var widthsURL: URL? = nil
nonisolated(unsafe) var began = ContinuousClock().now

struct Target {
    let filter: SCContentFilter, config: SCStreamConfiguration
    let writer: AVAssetWriter, input: AVAssetWriterInput, sink: Sink, name: String
    var follow: (() -> Void)? = nil            // moves the capture rectangle before each screenshot
}

func target(_ source: Source, _ url: URL, _ content: SCShareableContent) -> Target {
    let config = SCStreamConfiguration()
    config.showsCursor = false
    config.colorSpaceName = CGColorSpace.sRGB
    config.pixelFormat = kCVPixelFormatType_32BGRA
    let filter: SCContentFilter
    var follow: (() -> Void)? = nil
    switch source {
    case .item(let pid):
        guard let start = itemFrame(pid) else { fail("no menu bar icon for pid \(pid)") }
        guard let display = content.displays.first(where: { $0.frame.intersects(start) }) else { fail("no display holds the icon") }
        let width = start.width + 24
        filter = SCContentFilter(display: display, excludingWindows: [])
        config.width = Int(width * 2)
        config.height = Int(start.height * 2)
        let origin = display.frame.origin
        let place = { (r: CGRect) in config.sourceRect = CGRect(x: r.minX - origin.x, y: r.minY - origin.y, width: width, height: start.height) }
        place(start)
        widthsURL = url.deletingPathExtension().appendingPathExtension("widths.json")
        follow = {
            guard let now = itemFrame(pid) else { return }
            place(now)
            if widths.last?[1] != Double(now.width) {
                let t = ContinuousClock().now - began
                widths.append([Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18, Double(now.width)])
            }
        }
    case .rect(let rect):
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { fail("no display holds that rectangle") }
        filter = SCContentFilter(display: display, excludingWindows: [])
        config.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY, width: rect.width, height: rect.height)
        config.width = Int(rect.width * 2)
        config.height = Int(rect.height * 2)
    case .window(let pid, let title):
        let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
        let pick = title.flatMap { t in mine.first { $0.title == t } } ?? (title == nil ? mine.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } : nil)
        guard let window = pick else { fail("no window \(title ?? "on screen") for pid \(pid)") }
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.ignoreShadowsSingleWindow = true
        filter = SCContentFilter(desktopIndependentWindow: window)
    }
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { fail("cannot write \(url.path)") }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: config.width, AVVideoHeightKey: config.height,
        // No frame reordering: with B-frames the file's timestamps stopped matching when things happened.
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoMaxKeyFrameIntervalKey: 30,
                                          AVVideoAllowFrameReorderingKey: false],
    ])
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    return Target(filter: filter, config: config, writer: writer, input: input,
                  sink: Sink(input: input, adaptor: adaptor), name: url.lastPathComponent, follow: follow)
}

Task {
    let content: SCShareableContent
    do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
    catch { fail("cannot list windows: \(error.localizedDescription)") }
    let targets = requests.map { target($0.0, $0.1, content) }
    finish = {
        Task {
            for t in targets {
                await t.sink.close()
                t.input.markAsFinished()
                await t.writer.finishWriting()
                print("\(t.name): \(await t.sink.summary)")
            }
            if let widthsURL, let data = try? JSONSerialization.data(withJSONObject: widths) { try? data.write(to: widthsURL) }
            fflush(stdout)
            exit(0)
        }
    }
    let clock = ContinuousClock()
    began = clock.now
    widths.removeAll()
    print("Recording started"); fflush(stdout)
    while !stopping {
        for t in targets {
            let asked = clock.now - began
            let seconds = Double(asked.components.seconds) + Double(asked.components.attoseconds) / 1e18
            t.follow?()
            if let pixels = await shot(t.filter, t.config) { await t.sink.take(pixels, at: seconds) }
        }
    }
}

actor Sink {
    let input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    var lastTime = -1.0, lastProbe: [Int] = [], written = 0, seen = 0, closed = false
    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) { self.input = input; self.adaptor = adaptor }
    var summary: String { "frames written \(written) of \(seen) screenshots" }
    func close() { closed = true }

    func take(_ pixels: CVPixelBuffer, at seconds: Double) {
        seen += 1
        guard !closed, seconds > lastTime, input.isReadyForMoreMediaData else { return }
        // A frame is kept only if the picture moved: hash every other row and compare with the last kept.
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pixels)!, row = CVPixelBufferGetBytesPerRow(pixels), h = CVPixelBufferGetHeight(pixels)
        var probe: [Int] = []
        probe.reserveCapacity(h / 2)
        for y in stride(from: 0, to: h, by: 2) { probe.append(Data(bytesNoCopy: base + y * row, count: row, deallocator: .none).hashValue) }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        guard probe != lastProbe else { return }
        adaptor.append(pixels, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        lastTime = seconds; lastProbe = probe; written += 1
    }
}

dispatchMain()
