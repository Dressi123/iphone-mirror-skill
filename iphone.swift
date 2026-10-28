// iphone — drive a real iPhone through the macOS iPhone Mirroring window.
//
// Every coordinate is in *window points*: (0,0) is the top-left of the mirroring
// window and a `shot` is saved at exactly that size, so a pixel you see in a shot is
// the point you pass to `tap`. Actions bring iPhone Mirroring to the front (synthetic
// input only reaches the frontmost app), then hand focus and the cursor back.
//
// Build: ./build.sh  (compiles to bin/iphone-core)

import AppKit
import Carbon
import CoreGraphics
import CoreImage
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

/// A labelled grid over a point-size capture, for picking out icons OCR can't name.
/// A line every 25 pt, heavier and numbered every 100.
func gridded(_ image: CGImage) -> CGImage {
    let width = image.width, height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Could not draw the grid.") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // CG draws bottom-up; window points run top-down, so y is flipped throughout.
    for value in stride(from: 25, to: max(width, height), by: 25) {
        let major = value % 100 == 0
        context.setStrokeColor(NSColor.magenta.withAlphaComponent(major ? 0.8 : 0.35).cgColor)
        context.setLineWidth(major ? 1 : 0.5)
        if value < width { context.strokeLineSegments(between: [CGPoint(x: value, y: 0), CGPoint(x: value, y: height)]) }
        if value < height { context.strokeLineSegments(between: [CGPoint(x: 0, y: height - value), CGPoint(x: width, y: height - value)]) }
    }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.white, .backgroundColor: NSColor.magenta.withAlphaComponent(0.8),
    ]
    for value in stride(from: 100, to: max(width, height), by: 100) {
        if value < width { NSAttributedString(string: "\(value)", attributes: attributes).draw(at: CGPoint(x: value + 2, y: height - 12)) }
        if value < height { NSAttributedString(string: "\(value)", attributes: attributes).draw(at: CGPoint(x: 2, y: height - value - 12)) }
    }
    NSGraphicsContext.current = nil
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

// MARK: - Settling

/// A 32×64 greyscale thumbnail of the screen: enough to tell motion from stillness, and
/// coarse enough that the mirrored video's compression noise averages out.
func fingerprint(_ window: MirrorWindow) -> [UInt8] {
    let image = captureRaw(window)
    var pixels = [UInt8](repeating: 0, count: 32 * 64)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: 32, height: 64, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 64))
    }
    return pixels
}

/// How many cells of the thumbnail changed. A cell is ~12 pt square, so a typed letter
/// changes one, while the video's compression noise changes none.
func changedCells(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 6 ? 1 : 0) }
}

/// Waits until two captures in a row match: a pushed screen, a sheet or a spring has
/// finished moving. Two cells may still change, so a blinking caret or a small spinner
/// doesn't hold it up. False when it is still moving at the deadline (a video).
func waitStable(_ window: MirrorWindow, timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var last = fingerprint(window)
    while Date() < deadline {
        usleep(100_000)
        let next = fingerprint(window)
        if changedCells(last, next) <= 2 { return true }
        last = next
    }
    return false
}

// MARK: - Text

struct Line {
    let text: String
    let rect: CGRect    // window points
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// OCR on the full-resolution capture (labels under the home-screen icons are ~9 pt, too
/// small at point size), returned in window points. The accurate model fails on the neural
/// engine on this macOS (e5rt error 13), so the fast one is used. `region` (window points)
/// reads only that part of the screen, which is quicker and keeps the output short.
///
/// Fast OCR loses white text on a light background — every label on a light wallpaper —
/// so a second pass reads a darkened greyscale copy, and adds what the first one missed.
func recognize(_ window: MirrorWindow, region: CGRect? = nil) -> [Line] {
    let image = captureRaw(window)
    let w = window.frame.width, h = window.frame.height
    let area = region?.intersection(CGRect(x: 0, y: 0, width: w, height: h)) ?? CGRect(x: 0, y: 0, width: w, height: h)
    var lines = read(image, area: area, in: window)
    if let darkened = darkened(image) {
        for line in read(darkened, area: area, in: window) where !lines.contains(where: { $0.rect.intersects(line.rect) }) {
            lines.append(line)
        }
    }
    return lines.sorted { abs($0.rect.minY - $1.rect.minY) > 6 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
}

/// Greyscale, then a gamma of 4: a light wallpaper (~0.8) falls to ~0.4 while white text
/// stays at 1, which turns the text the first pass missed back into contrast it can read.
func darkened(_ image: CGImage) -> CGImage? {
    let input = CIImage(cgImage: image)
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 4])
    return CIContext().createCGImage(input, from: input.extent)
}

func read(_ image: CGImage, area: CGRect, in window: MirrorWindow) -> [Line] {
    let w = window.frame.width, h = window.frame.height
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    // Normalized, bottom-left origin; results come back relative to this rectangle.
    request.regionOfInterest = CGRect(x: area.minX / w, y: 1 - area.maxY / h, width: area.width / w, height: area.height / h)
    do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { fail("text recognition failed: \(error)") }
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        let rect = CGRect(
            x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
            width: box.width * area.width, height: box.height * area.height
        )
        return Line(text: candidate.string, rect: rect)
    }
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

// MARK: - Focus

/// Set while `run` holds iPhone Mirroring in front for a whole script.
var focusHeld = false
/// Gives focus and the cursor back; `fail` calls it too, so an error never strands them.
var restoreFocus: (() -> Void)?

func bringMirrorForward() {
    mirrorApp()?.activate()
    // NSWorkspace only learns the app changed by running the run loop; sleeping instead
    // leaves frontmostApplication stale and the loop always ran its full second.
    for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    usleep(100_000)
}

func takeFocus() {
    let previous = NSWorkspace.shared.frontmostApplication
    let cursor = CGEvent(source: nil)?.location
    bringMirrorForward()
    restoreFocus = {
        restoreFocus = nil
        if let previous, previous.bundleIdentifier != bundleID { previous.activate() }
        if let cursor { CGWarpMouseCursorPosition(cursor) }
    }
}

/// Runs `body` with iPhone Mirroring frontmost, then gives focus and the cursor back.
/// Inside `run` focus stays put between steps, unless something else took it meanwhile.
func withMirrorFocused(_ body: () -> Void) {
    if focusHeld {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID { bringMirrorForward() }
        body()
        return
    }
    takeFocus()
    body()
    usleep(150_000)
    restoreFocus?()
}

// MARK: - Touch

func global(_ window: MirrorWindow, _ point: CGPoint) -> CGPoint {
    CGPoint(x: window.frame.minX + point.x, y: window.frame.minY + point.y)
}

/// `clicks` is the click count a double-click carries on its second press.
func mouse(_ type: CGEventType, _ point: CGPoint, clicks: Int64 = 1) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: clicks)
    event?.post(tap: .cghidEventTap)
}

/// A tap, or with `hold` a press held still that long: a context menu, a long press.
func click(_ window: MirrorWindow, _ point: CGPoint, hold: UInt32 = 0) {
    let p = global(window, point)
    withMirrorFocused {
        mouse(.mouseMoved, p); usleep(60_000)
        mouse(.leftMouseDown, p); usleep(hold > 0 ? hold * 1000 : 70_000)
        mouse(.leftMouseUp, p)
    }
}

func doubleTap(_ window: MirrorWindow, _ point: CGPoint) {
    let p = global(window, point)
    withMirrorFocused {
        mouse(.mouseMoved, p); usleep(60_000)
        mouse(.leftMouseDown, p); usleep(50_000); mouse(.leftMouseUp, p)
        usleep(90_000)
        mouse(.leftMouseDown, p, clicks: 2); usleep(50_000); mouse(.leftMouseUp, p, clicks: 2)
    }
}

/// iPhone Mirroring scrolls on wheel events, not drags. Negative `dy` scrolls down and
/// negative `dx` scrolls right, toward what is off the right edge.
func scroll(_ window: MirrorWindow, dy: Int32, dx: Int32, at point: CGPoint?) {
    let p = global(window, point ?? CGPoint(x: window.frame.width / 2, y: window.frame.height / 2))
    withMirrorFocused {
        mouse(.mouseMoved, p); usleep(60_000)
        let steps: Int32 = 20
        for _ in 0..<steps {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy / steps, wheel2: dx / steps, wheel3: 0)?
                .post(tap: .cghidEventTap)
            usleep(12_000)
        }
        usleep(400_000)   // let momentum settle before focus moves away
    }
}

/// `hold` presses still for that long before moving: drag-to-reorder in a list only picks
/// the row up after a long press, and an immediate drag reads as a tap or a scroll. The
/// finger rests before lifting, so the release carries no velocity; `swipe` is the flick.
func drag(_ window: MirrorWindow, from a: CGPoint, to b: CGPoint, hold: UInt32 = 0) {
    let start = global(window, a), end = global(window, b)
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

/// A flick: constant speed over `ms` and released while still moving, so the gesture ends
/// with velocity — swipe to delete, page a carousel, throw a sheet away. Shorter is faster.
func swipe(_ window: MirrorWindow, from a: CGPoint, to b: CGPoint, ms: Int) {
    let start = global(window, a), end = global(window, b)
    let steps = max(6, ms / 8)
    withMirrorFocused {
        mouse(.mouseMoved, start); usleep(60_000); mouse(.leftMouseDown, start); usleep(20_000)
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f))
            usleep(useconds_t(ms * 1000 / steps))
        }
        mouse(.leftMouseUp, end)
    }
}

// MARK: - Keyboard

/// Character → key code and modifiers on the Mac's current keyboard layout. iPhone
/// Mirroring forwards key codes, not text, so typing has to press the keys a person would.
let keyboard: [Character: (code: CGKeyCode, flags: CGEventFlags)] = {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return [:] }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    var map: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]
    let layers: [(UInt32, CGEventFlags)] = [
        (0, []), (UInt32(shiftKey >> 8) & 0xFF, .maskShift),
        (UInt32(optionKey >> 8) & 0xFF, .maskAlternate), (UInt32((shiftKey | optionKey) >> 8) & 0xFF, [.maskShift, .maskAlternate]),
    ]
    data.withUnsafeBytes { buffer in
        let layout = buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        for (modifiers, flags) in layers {
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars
                )
                guard status == noErr, length == 1, chars[0] >= 32,
                      let character = String(utf16CodeUnits: chars, count: 1).first, map[character] == nil
                else { continue }
                map[character] = (CGKeyCode(code), flags)
            }
        }
    }
    return map
}()

let namedKeys: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forward-delete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

/// Presses a key the way a hand does: modifier keys go down first and up last, since an
/// app may ignore a shortcut whose modifier only appears as a flag on the key itself.
func press(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
        .filter { flags.contains($0.0) }
    var held: CGEventFlags = []
    for (flag, modifier) in modifiers {
        held.insert(flag)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: true)
        event?.flags = held
        event?.post(tap: .cghidEventTap); usleep(20_000)
    }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        if let text {
            let units = Array(text.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event?.post(tap: .cghidEventTap); usleep(30_000)
    }
    for (flag, modifier) in modifiers.reversed() {
        held.remove(flag)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: false)
        event?.flags = held
        event?.post(tap: .cghidEventTap); usleep(20_000)
    }
}

func type(_ text: String) {
    var skipped: [Character] = []
    withMirrorFocused {
        for character in text {
            if character == "\n" { press(36); continue }
            guard let key = keyboard[character] else { skipped.append(character); continue }
            press(key.code, flags: key.flags, text: String(character))
            usleep(25_000)
        }
    }
    if !skipped.isEmpty {
        FileHandle.standardError.write(Data("iphone: no key types \(String(skipped).debugDescription) on this layout; skipped\n".utf8))
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

/// The script line being run, so a failure says which step it was.
var currentStep: String?

func fail(_ message: String) -> Never {
    restoreFocus?()
    let step = currentStep.map { " (at `\($0)`)" } ?? ""
    FileHandle.standardError.write(Data("iphone: \(message)\(step)\n".utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("iphone: \(message)\n".utf8))
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

/// An option taking several numbers, `--at X Y` or `--region X Y W H`.
func numbers(_ name: String, _ count: Int, in args: inout [String]) -> [CGFloat]? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + count < args.count else { fail("\(name) needs \(count) numbers") }
    let values = args[(i + 1)...(i + count)].map { number($0) }
    args.removeSubrange(i...(i + count))
    return values
}

func region(in args: inout [String]) -> CGRect? {
    numbers("--region", 4, in: &args).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
}

func flag(_ name: String, in args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

/// What an action does once it has acted: `--wait` then `--shot PATH`, so one call can act
/// and look. The wait defaults to `stable`: until the screen has moved and then stopped
/// moving. `--wait MS` sleeps instead, and `--wait 0` moves straight on.
struct Settle {
    let wait: String
    let shot: String?
    /// The screen before the action, so stillness is only judged once it has changed.
    let before: [UInt8]?

    init(_ args: inout [String]) {
        wait = option("--wait", in: &args) ?? "stable"
        shot = option("--shot", in: &args)
        before = wait == "stable" ? findWindow().map(fingerprint) : nil
    }

    func finish() {
        if wait == "stable" {
            if let window = findWindow(), let before {
                // Mirroring shows the phone a few hundred ms late, and a still screen read
                // before the change arrives would pass for a settled one.
                let deadline = Date().addingTimeInterval(1.5)
                var moved = false
                while !moved && Date() < deadline {
                    moved = changedCells(before, fingerprint(window)) > 0
                    if !moved { usleep(50_000) }
                }
                if !moved {
                    warn("screen did not change")
                } else if !waitStable(window, timeout: 5) {
                    warn("screen still changing after 5 s (a video or a spinner?); carrying on")
                }
            }
        } else {
            guard let ms = Double(wait) else { fail("--wait takes MS or stable") }
            usleep(useconds_t(ms * 1000))
        }
        if let shot, let window = findWindow() {
            save(capture(window), to: shot)
            print(shot)
        }
    }
}

/// Splits a script line like a shell: spaces separate, quotes group, `#` starts a comment.
func words(_ line: String) -> [String] {
    var result: [String] = [], current = "", quote: Character?, started = false
    for character in line {
        if let open = quote {
            if character == open { quote = nil } else { current.append(character) }
        } else if character == "\"" || character == "'" {
            quote = character; started = true
        } else if character == "#" && !started {
            break
        } else if character.isWhitespace {
            if started { result.append(current); current = ""; started = false }
        } else {
            current.append(character); started = true
        }
    }
    if started { result.append(current) }
    return result
}

let usage = """
usage: iphone <command>   (coordinates are window points; a shot's pixels are points)
  window                         print x y width height of the mirroring window
  shot PATH [--grid]             save the screen at window-point size; --grid overlays
                                 numbered lines every 100 pt, faint ones every 25
  shot PATH --crop X Y W H       save that area at full Retina resolution, to look closely
  text [--json] [--region X Y W H]         OCR: "x y w h<TAB>text" per line
  state                          connected | in-use | connecting | disconnected | blank
  connect                        press Connect if mirroring has dropped, wait until live
  tap X Y [--hold MS]            tap a point; --hold long-presses in place
  tap-text LABEL [--nth N] [--regex] [--offset DX DY] [--hold MS] [--region X Y W H]
                                 tap the Nth (default 1) match; case and spaces ignored;
                                 --offset taps beside it, for an icon next to a label
  double-tap X Y                 double-tap (zoom a photo or the map)
  wait-text LABEL [--timeout S] [--regex] [--region X Y W H]  wait until LABEL is on screen
  wait-gone LABEL [--timeout S] [--regex] [--region X Y W H]  wait until LABEL has gone
  wait-stable [--timeout S]      wait until the screen stops moving
  scroll DY [--dx DX] [--at X Y] wheel-scroll; negative DY scrolls down (≈ -600 is most of
                                 a screen), negative DX scrolls right
  drag X1 Y1 X2 Y2 [--hold MS]   slow press-drag that rests before lifting (sliders,
                                 sheets; --hold 600 long-presses first, to reorder rows)
  swipe X1 Y1 X2 Y2 [--ms MS]    flick released while moving (default 150 ms; shorter is faster)
  back                           tap the top-left back button
  type TEXT                      type into the focused field ("\\n" presses return)
  key NAME [--cmd] [--shift] [--alt]   return tab space delete escape forward-delete
                                 left right up down, or a single character
  home | switcher | spotlight    Cmd-1 / Cmd-2 / Cmd-3
  record PATH [--seconds S]      record the window to a .mov (default 10 s, clicks shown)
  run                            read commands from stdin, one per line, holding focus
                                 for the whole script; stops at the first failure
Any action also takes --wait (default: until the screen has changed and settled, warning
"screen did not change" when it never moves; or MS to sleep, 0 for none) and --shot PATH.
"""

// MARK: - Commands

let actions: Set<String> = ["tap", "tap-text", "double-tap", "scroll", "drag", "swipe", "back", "type", "key", "home", "switcher", "spotlight"]

func execute(_ command: String, _ arguments: [String]) {
    var args = arguments
    let settle = actions.contains(command) ? Settle(&args) : nil
    switch command {
    case "window":
        let w = requireWindow()
        print(Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height))

    case "shot":
        let grid = flag("--grid", in: &args)
        let crop = numbers("--crop", 4, in: &args)
        guard let path = args.first else { fail("shot needs a PATH") }
        let window = requireWindow()
        if let crop {
            let image = captureRaw(window)
            let scale = CGFloat(image.width) / window.frame.width
            let rect = CGRect(x: crop[0] * scale, y: crop[1] * scale, width: crop[2] * scale, height: crop[3] * scale)
            guard let cropped = image.cropping(to: rect.integral) else { fail("crop is outside the window") }
            save(cropped, to: path)
            print("\(path)\t(\(Int(scale))x: pixel (px, py) is point (\(Int(crop[0])) + px/\(Int(scale)), \(Int(crop[1])) + py/\(Int(scale))))")
        } else {
            let image = capture(window)
            save(grid ? gridded(image) : image, to: path)
            print(path)
        }

    case "text":
        let json = flag("--json", in: &args)
        let lines = recognize(requireWindow(), region: region(in: &args))
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
        case .connected: print("connected"); return
        case .inUse: fail("iPhone is in use. Lock it, then run connect again.")
        case .connecting, .disconnected, .blank:
            if let button = lines.first(where: { $0.text == "Connect" }) { click(window, button.center) }
        }
        for _ in 0..<40 {
            usleep(500_000)
            lines = recognize(window)
            if connection(of: lines) == .connected { print("connected"); return }
            if connection(of: lines) == .inUse { fail("iPhone is in use. Lock it, then run connect again.") }
        }
        fail("still not connected after 20 s")

    case "tap":
        let hold = option("--hold", in: &args).map { UInt32(number($0)) } ?? 0
        guard args.count >= 2 else { fail("tap needs X Y") }
        let point = CGPoint(x: number(args[0]), y: number(args[1]))
        args.removeFirst(2)
        click(requireWindow(), point, hold: hold)
        settle?.finish()

    case "tap-text":
        let nth = option("--nth", in: &args).flatMap(Int.init) ?? 1
        let regex = flag("--regex", in: &args)
        let offset = numbers("--offset", 2, in: &args) ?? [0, 0]
        let hold = option("--hold", in: &args).map { UInt32(number($0)) } ?? 0
        let area = region(in: &args)
        guard let label = args.first else { fail("tap-text needs a LABEL") }
        args.removeFirst()
        let window = requireWindow()
        let matches = find(label, in: recognize(window, region: area), regex: regex)
        guard matches.count >= nth else {
            fail("no on-screen text matches \"\(label)\"\(matches.isEmpty ? "" : " \(nth) times"). Run `iphone text` to see what is there.")
        }
        let target = matches[nth - 1]
        let point = CGPoint(x: target.center.x + offset[0], y: target.center.y + offset[1])
        click(window, point, hold: hold)
        warn("tapped \"\(target.text)\" at \(Int(point.x)) \(Int(point.y))")
        settle?.finish()

    case "double-tap":
        guard args.count >= 2 else { fail("double-tap needs X Y") }
        let point = CGPoint(x: number(args[0]), y: number(args[1]))
        args.removeFirst(2)
        doubleTap(requireWindow(), point)
        settle?.finish()

    case "wait-text", "wait-gone":
        let timeout = option("--timeout", in: &args).flatMap(Double.init) ?? 30
        let regex = flag("--regex", in: &args)
        let area = region(in: &args)
        guard let label = args.first else { fail("\(command) needs a LABEL") }
        let window = requireWindow()
        let deadline = Date().addingTimeInterval(timeout)
        var misses = 0
        while Date() < deadline {
            let hit = find(label, in: recognize(window, region: area), regex: regex).first
            if command == "wait-text", let hit {
                print("\(Int(hit.center.x)) \(Int(hit.center.y))\t\(hit.text)")
                return
            }
            // Fast OCR drops a label now and then, so gone means two misses in a row.
            misses = hit == nil ? misses + 1 : 0
            if command == "wait-gone", misses == 2 { print("gone"); return }
            usleep(500_000)
        }
        fail("\"\(label)\" \(command == "wait-text" ? "did not appear" : "was still there") after \(Int(timeout)) s")

    case "wait-stable":
        let timeout = option("--timeout", in: &args).flatMap(Double.init) ?? 10
        guard waitStable(requireWindow(), timeout: timeout) else { fail("screen still changing after \(Int(timeout)) s") }
        print("stable")

    case "scroll":
        let dx = option("--dx", in: &args).flatMap { Int32($0) } ?? 0
        let at = numbers("--at", 2, in: &args).map { CGPoint(x: $0[0], y: $0[1]) }
        guard let first = args.first, let dy = Int32(first) else { fail("scroll needs DY (0 with --dx to scroll sideways)") }
        args.removeFirst()
        scroll(requireWindow(), dy: dy, dx: dx, at: at)
        settle?.finish()

    case "drag":
        let hold = option("--hold", in: &args).map { UInt32(number($0)) } ?? 0
        guard args.count >= 4 else { fail("drag needs X1 Y1 X2 Y2") }
        let a = CGPoint(x: number(args[0]), y: number(args[1])), b = CGPoint(x: number(args[2]), y: number(args[3]))
        args.removeFirst(4)
        drag(requireWindow(), from: a, to: b, hold: hold)
        settle?.finish()

    case "swipe":
        let ms = option("--ms", in: &args).flatMap(Int.init) ?? 150
        guard args.count >= 4 else { fail("swipe needs X1 Y1 X2 Y2") }
        let a = CGPoint(x: number(args[0]), y: number(args[1])), b = CGPoint(x: number(args[2]), y: number(args[3]))
        args.removeFirst(4)
        swipe(requireWindow(), from: a, to: b, ms: ms)
        settle?.finish()

    case "back":
        // The back button, where a 398×874 window puts it. The back swipe would be the more
        // natural gesture, but no drag, flick or sideways wheel reaches it through Mirroring.
        let window = requireWindow()
        click(window, CGPoint(x: window.frame.width * 45 / 398, y: window.frame.height * 119 / 874))
        settle?.finish()

    case "type":
        guard let text = args.first else { fail("type needs TEXT") }
        args.removeFirst()
        _ = requireWindow()
        type(text.replacingOccurrences(of: "\\n", with: "\n"))
        settle?.finish()

    case "key":
        var flags: CGEventFlags = []
        if flag("--cmd", in: &args) { flags.insert(.maskCommand) }
        if flag("--shift", in: &args) { flags.insert(.maskShift) }
        if flag("--alt", in: &args) { flags.insert(.maskAlternate) }
        guard let name = args.first else { fail("key needs a NAME") }
        args.removeFirst()
        let code: CGKeyCode
        if let named = namedKeys[name] {
            code = named
        } else if name.count == 1, let key = keyboard[name.first!] {
            code = key.code; flags.formUnion(key.flags)
        } else {
            fail("unknown key \(name)")
        }
        _ = requireWindow()
        withMirrorFocused { press(code, flags: flags) }
        settle?.finish()

    case "home", "switcher", "spotlight":
        _ = requireWindow()
        let code: CGKeyCode = command == "home" ? 18 : command == "switcher" ? 19 : 20   // 1, 2, 3
        withMirrorFocused { press(code, flags: .maskCommand) }
        settle?.finish()

    case "record":
        // Records the window's screen region, so the window has to stay uncovered: drive the
        // phone with `run` meanwhile, which keeps iPhone Mirroring in front.
        let seconds = option("--seconds", in: &args).flatMap(Int.init) ?? 10
        guard let path = args.first else { fail("record needs a PATH") }
        let window = requireWindow()
        if !focusHeld { bringMirrorForward() }
        let f = window.frame
        run("/usr/sbin/screencapture", ["-x", "-v", "-k", "-V", String(seconds), "-R\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))", path])
        guard FileManager.default.fileExists(atPath: path) else { fail("recording failed") }
        print(path)

    case "run":
        guard !focusHeld else { fail("run cannot nest") }
        _ = requireWindow()
        takeFocus()
        focusHeld = true
        while let line = readLine() {
            let parts = words(line)
            guard let step = parts.first else { continue }
            currentStep = line.trimmingCharacters(in: .whitespaces)
            warn("› \(currentStep!)")
            execute(step, Array(parts.dropFirst()))
        }
        currentStep = nil
        focusHeld = false
        restoreFocus?()

    default:
        print(usage)
        exit(1)
    }
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()
execute(command, args)
