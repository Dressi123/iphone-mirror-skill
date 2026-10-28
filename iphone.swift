// iphone — drive a real iPhone through the macOS iPhone Mirroring window.
//
// Every coordinate is in *window points*: (0,0) is the top-left of the mirroring
// window and a `shot` is saved at exactly that size, so a pixel you see in a shot is
// the point you pass to `tap`. Actions bring iPhone Mirroring to the front (synthetic
// input only reaches the frontmost app), then hand focus and the cursor back.
//
// Build: ./build.sh  (compiles to bin/iphone)

import AppKit
import CoreGraphics
import Foundation
import Vision

// MARK: - Window

struct MirrorWindow {
    let id: CGWindowID
    let frame: CGRect   // global screen points, top-left origin (same space as CGEvent)
}

let bundleID = "com.apple.ScreenContinuity"

func mirrorApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func findWindow() -> MirrorWindow? {
    guard let app = mirrorApp(),
          let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    // The phone window is the on-screen layer-0 window. The app also keeps an off-screen
    // "Welcome" window and menu-bar-sized strips around, so on-screen and taller than wide.
    let candidates = list.compactMap { info -> MirrorWindow? in
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
              (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.width > 200, rect.height > rect.width,
              let number = info[kCGWindowNumber as String] as? CGWindowID
        else { return nil }
        return MirrorWindow(id: number, frame: rect)
    }
    return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

func requireWindow() -> MirrorWindow {
    if mirrorApp() == nil {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/iPhone Mirroring.app"))
        for _ in 0..<20 where findWindow() == nil { usleep(250_000) }
    }
    guard let window = findWindow() else { fail("iPhone Mirroring window not found. Open iPhone Mirroring and connect.") }
    return window
}

// MARK: - Capture

/// Captures the window at full Retina resolution. By window ID first, which works while
/// it is covered; that sometimes returns a blank frame of the mirrored video, and then
/// the window is brought forward and its screen region captured instead.
func captureRaw(_ window: MirrorWindow) -> CGImage {
    let raw = NSTemporaryDirectory() + "iphone-raw-\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: raw) }
    func load() -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: raw) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.id), raw])
    if let image = load(), !isBlank(image) { return image }
    let f = window.frame
    withMirrorFocused {
        run("/usr/sbin/screencapture", ["-x", "-R\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))", raw])
    }
    guard let image = load() else {
        fail("Capture failed. Grant Screen Recording to your terminal in System Settings → Privacy & Security.")
    }
    return image
}

/// True when a 16×16 grid of samples is all one colour.
func isBlank(_ image: CGImage) -> Bool {
    guard let context = CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    guard let data = context.data else { return false }
    let pixels = data.bindMemory(to: UInt32.self, capacity: 256)
    let first = pixels[0]
    return (0..<256).allSatisfy { pixels[$0] == first }
}

/// The capture scaled to window points, so a pixel in a saved shot is a point to tap.
func capture(_ window: MirrorWindow) -> CGImage {
    let image = captureRaw(window)
    let width = Int(window.frame.width), height = Int(window.frame.height)
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Could not scale the capture.") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func save(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("Cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// MARK: - Text

struct Line {
    let text: String
    let rect: CGRect    // window points
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// OCR on the full-resolution capture (labels under the home-screen icons are ~9 pt, too
/// small at point size), returned in window points. The accurate model fails on the neural
/// engine on this macOS (e5rt error 13), so the fast one is used.
func recognize(_ window: MirrorWindow) -> [Line] {
    let image = captureRaw(window)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { fail("text recognition failed: \(error)") }
    let results = request.results ?? []
    let w = window.frame.width, h = window.frame.height
    return results.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox   // normalized, bottom-left origin
        let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        return Line(text: candidate.string, rect: rect)
    }
    .sorted { abs($0.rect.minY - $1.rect.minY) > 6 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
}

/// Exact matches first, then lines containing the label, top to bottom. Case and spaces are
/// ignored, since fast OCR splits words ("Prof ile"). With `regex`, LABEL is a regular
/// expression matched against each line as read, e.g. "[1-9][0-9]* place lookups".
func find(_ label: String, in lines: [Line], regex: Bool = false) -> [Line] {
    if regex {
        guard let pattern = try? NSRegularExpression(pattern: label, options: [.caseInsensitive]) else {
            fail("bad regex \(label)")
        }
        return lines.filter { pattern.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
    }
    func squash(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
    let needle = squash(label)
    let exact = lines.filter { squash($0.text) == needle }
    let partial = lines.filter { squash($0.text) != needle && squash($0.text).contains(needle) }
    return exact + partial
}

enum Connection: String { case connected, inUse = "in-use", connecting, disconnected, blank }

func connection(of lines: [Line]) -> Connection {
    if lines.isEmpty { return .blank }
    let all = lines.map(\.text).joined(separator: "\n").lowercased()
    if all.contains("iphone in use") || all.contains("lock your iphone") { return .inUse }
    if all.contains("connecting to") { return .connecting }
    if lines.contains(where: { $0.text == "Connect" }) && all.contains("iphone mirroring") { return .disconnected }
    return .connected
}

// MARK: - Input

/// Runs `body` with iPhone Mirroring frontmost, then gives focus and the cursor back.
func withMirrorFocused(_ body: () -> Void) {
    let previous = NSWorkspace.shared.frontmostApplication
    let cursor = CGEvent(source: nil)?.location
    mirrorApp()?.activate()
    for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID { usleep(50_000) }
    usleep(150_000)
    body()
    usleep(150_000)
    if let previous, previous.bundleIdentifier != bundleID { previous.activate() }
    if let cursor { CGWarpMouseCursorPosition(cursor) }
}

func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func click(_ window: MirrorWindow, _ point: CGPoint) {
    let global = CGPoint(x: window.frame.minX + point.x, y: window.frame.minY + point.y)
    withMirrorFocused {
        mouse(.mouseMoved, global); usleep(60_000)
        mouse(.leftMouseDown, global); usleep(70_000)
        mouse(.leftMouseUp, global)
    }
}

/// iPhone Mirroring scrolls on wheel events, not drags. Negative `dy` scrolls down.
func scroll(_ window: MirrorWindow, dy: Int32, at point: CGPoint?) {
    let p = point ?? CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
    let global = CGPoint(x: window.frame.minX + p.x, y: window.frame.minY + p.y)
    withMirrorFocused {
        mouse(.mouseMoved, global); usleep(60_000)
        let steps: Int32 = 20
        for _ in 0..<steps {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy / steps, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            usleep(12_000)
        }
        usleep(400_000)   // let momentum settle before focus moves away
    }
}

/// `hold` presses still for that long before moving: drag-to-reorder in a list only picks
/// the row up after a long press, and an immediate drag reads as a tap or a scroll.
func drag(_ window: MirrorWindow, from a: CGPoint, to b: CGPoint, hold: UInt32 = 0) {
    let origin = window.frame.origin
    let start = CGPoint(x: origin.x + a.x, y: origin.y + a.y), end = CGPoint(x: origin.x + b.x, y: origin.y + b.y)
    let steps = hold > 0 ? 60 : 25
    withMirrorFocused {
        mouse(.mouseMoved, start); usleep(60_000); mouse(.leftMouseDown, start)
        if hold > 0 {
            usleep(hold * 1000)
            mouse(.leftMouseDragged, CGPoint(x: start.x, y: start.y + 1)); usleep(50_000)
        }
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f))
            usleep(hold > 0 ? 25_000 : 15_000)
        }
        usleep(hold > 0 ? 400_000 : 100_000); mouse(.leftMouseUp, end)
    }
}

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func type(_ text: String) {
    withMirrorFocused {
        for character in text {
            if character == "\n" { key(36); continue }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
            usleep(25_000)
        }
    }
}

// MARK: - Helpers

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("iphone: \(message)\n".utf8))
    exit(1)
}

func number(_ s: String?) -> CGFloat {
    guard let s, let value = Double(s) else { fail("expected a number, got \(s ?? "nothing")") }
    return CGFloat(value)
}

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String, in args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

/// `--wait MS` then `--shot PATH`, after any action, so one call can act and look.
func afterAction(_ args: inout [String]) {
    let wait = option("--wait", in: &args).flatMap(Double.init) ?? 700
    let shotPath = option("--shot", in: &args)
    usleep(useconds_t(wait * 1000))
    if let shotPath, let window = findWindow() {
        save(capture(window), to: shotPath)
        print(shotPath)
    }
}

let usage = """
usage: iphone <command>   (coordinates are window points; a shot's pixels are points)
  window                         print x y width height of the mirroring window
  shot PATH                      save the screen at window-point size
  text [--json]                  OCR the screen: "x y w h<TAB>text" per line
  state                          connected | in-use | connecting | disconnected | blank
  connect                        press Connect if mirroring has dropped, wait until live
  tap X Y                        tap a point
  tap-text LABEL [--nth N] [--regex]       tap the Nth (default 1) match; case and spaces ignored
  wait-text LABEL [--timeout S] [--regex]  wait until LABEL is on screen
  scroll DY [--at X Y]           wheel-scroll; negative DY scrolls down (≈ -600 is most of a screen)
  drag X1 Y1 X2 Y2 [--hold MS]   press-drag (sliders, sheets; lists want scroll;
                                 --hold 600 long-presses first, for drag-to-reorder)
  type TEXT                      type into the focused field ("\\n" presses return)
  home | switcher | spotlight    Cmd-1 / Cmd-2 / Cmd-3
  back                           tap the top-left back button region
Any action also takes --wait MS (default 700) and --shot PATH to look right after.
"""

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "window":
    let w = requireWindow()
    print(Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height))

case "shot":
    guard let path = args.first else { fail("shot needs a PATH") }
    save(capture(requireWindow()), to: path)
    print(path)

case "text":
    let json = flag("--json", in: &args)
    let lines = recognize(requireWindow())
    if json {
        let rows = lines.map { ["text": $0.text, "x": Int($0.center.x), "y": Int($0.center.y), "w": Int($0.rect.width), "h": Int($0.rect.height)] as [String: Any] }
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    } else {
        for line in lines {
            print("\(Int(line.center.x)) \(Int(line.center.y)) \(Int(line.rect.width)) \(Int(line.rect.height))\t\(line.text)")
        }
    }

case "state":
    // A single read can land on a frame with no text (a dark screen, a frame mid-update),
    // so `blank` is only reported when three reads in a row agree.
    let window = requireWindow()
    var state = Connection.blank
    for attempt in 0..<3 {
        state = connection(of: recognize(window))
        if state != .blank { break }
        if attempt < 2 { usleep(800_000) }
    }
    print(state.rawValue)

case "connect":
    let window = requireWindow()
    var lines = recognize(window)
    switch connection(of: lines) {
    case .connected: print("connected"); exit(0)
    case .inUse: fail("iPhone is in use. Lock it, then run connect again.")
    case .connecting, .disconnected, .blank:
        if let button = lines.first(where: { $0.text == "Connect" }) { click(window, button.center) }
    }
    for _ in 0..<40 {
        usleep(500_000)
        lines = recognize(window)
        if connection(of: lines) == .connected { print("connected"); exit(0) }
        if connection(of: lines) == .inUse { fail("iPhone is in use. Lock it, then run connect again.") }
    }
    fail("still not connected after 20 s")

case "tap":
    guard args.count >= 2 else { fail("tap needs X Y") }
    let point = CGPoint(x: number(args[0]), y: number(args[1]))
    args.removeFirst(2)
    click(requireWindow(), point)
    afterAction(&args)

case "tap-text":
    let nth = option("--nth", in: &args).flatMap(Int.init) ?? 1
    let regex = flag("--regex", in: &args)
    guard let label = args.first else { fail("tap-text needs a LABEL") }
    args.removeFirst()
    let window = requireWindow()
    let matches = find(label, in: recognize(window), regex: regex)
    guard matches.count >= nth else {
        fail("no on-screen text matches \"\(label)\"\(matches.isEmpty ? "" : " \(nth) times"). Run `iphone text` to see what is there.")
    }
    let target = matches[nth - 1]
    click(window, target.center)
    FileHandle.standardError.write(Data("tapped \"\(target.text)\" at \(Int(target.center.x)) \(Int(target.center.y))\n".utf8))
    afterAction(&args)

case "wait-text":
    let timeout = option("--timeout", in: &args).flatMap(Double.init) ?? 30
    let regex = flag("--regex", in: &args)
    guard let label = args.first else { fail("wait-text needs a LABEL") }
    let window = requireWindow()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let hit = find(label, in: recognize(window), regex: regex).first {
            print("\(Int(hit.center.x)) \(Int(hit.center.y))\t\(hit.text)")
            exit(0)
        }
        usleep(700_000)
    }
    fail("\"\(label)\" did not appear within \(Int(timeout)) s")

case "scroll":
    guard let first = args.first, let dy = Int32(first) else { fail("scroll needs DY") }
    args.removeFirst()
    var at: CGPoint?
    if let i = args.firstIndex(of: "--at"), i + 2 < args.count {
        at = CGPoint(x: number(args[i + 1]), y: number(args[i + 2]))
        args.removeSubrange(i...(i + 2))
    }
    scroll(requireWindow(), dy: dy, at: at)
    afterAction(&args)

case "drag":
    guard args.count >= 4 else { fail("drag needs X1 Y1 X2 Y2") }
    let a = CGPoint(x: number(args[0]), y: number(args[1])), b = CGPoint(x: number(args[2]), y: number(args[3]))
    args.removeFirst(4)
    var hold: UInt32 = 0
    if let index = args.firstIndex(of: "--hold"), index + 1 < args.count {
        hold = UInt32(number(args[index + 1]))
        args.removeSubrange(index...(index + 1))
    }
    drag(requireWindow(), from: a, to: b, hold: hold)
    afterAction(&args)

case "type":
    guard let text = args.first else { fail("type needs TEXT") }
    args.removeFirst()
    _ = requireWindow()
    type(text.replacingOccurrences(of: "\\n", with: "\n"))
    afterAction(&args)

case "home", "switcher", "spotlight":
    _ = requireWindow()
    let code: CGKeyCode = command == "home" ? 18 : command == "switcher" ? 19 : 20   // 1, 2, 3
    withMirrorFocused { key(code, flags: .maskCommand) }
    afterAction(&args)

case "back":
    let window = requireWindow()
    click(window, CGPoint(x: 45, y: 119))
    afterAction(&args)

default:
    print(usage)
    exit(1)
}
