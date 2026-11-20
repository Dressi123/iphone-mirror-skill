// iphone-hid — touches and key presses on a device through Xcode's CoreDevice remote digitizer
// and keyboard: the services Device Hub turns clicks and keys into, called directly, so
// nothing on the Mac moves.
//
// CoreDevice is private and ships no Swift interface; `CoreDevice.swiftmodule/` beside this
// file is a hand-written slice of it, enough to reach the digitizer. `build.sh` builds this
// only where the framework exists, and again when its version changes.
//
// Usage: iphone-hid DEVICE VERB ARGS...   (DEVICE is the CoreDevice identifier; points are
// fractions of the screen, 0...1 from the top left)
//   tap X Y [HOLD_MS]
//   double-tap X Y
//   move X1 Y1 X2 Y2 MS [PRESS_MS] [REST_MS]   one finger: press, move, rest, lift
//   pinch CX CY FROM TO MS                     two fingers, FROM/TO half the gap, as fractions of the width
//   edge left|right|top|bottom X1 Y1 X2 Y2 MS  a swipe in from that edge
//   check                                      exits 0 when the device's digitizer is reachable
//   type TEXT                                  types TEXT as US-layout key presses; \n is Return
//   key NAME [cmd] [shift] [alt] [ctrl]        one key (a character or a name in `namedKeys`), with modifiers

import CoreDevice
import Foundation

/// Generic on purpose: inside, `A.ProtocolType` is the framework's own type, read at runtime
/// from its witness table, never the placeholder the hand-written interface declares.
@inline(never) @_optimize(none)
func implementation<A: DeviceCapability>(_ device: RemoteDevice, _ member: CapabilityStaticMember<A>) async throws -> Any {
    try await device.getImplementation(for: member)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("iphone-hid: \(message)\n".utf8))
    exit(1)
}

func sleep(ms: Double) async { try? await Task.sleep(for: .milliseconds(Int(ms))) }

// MARK: - Keyboard

/// HID usage codes (page 7). The phone reads them through its own hardware keyboard layout,
/// so this is the US layout regardless of the Mac's.
let modifierKeys: [String: UInt16] = ["ctrl": 0xE0, "shift": 0xE1, "alt": 0xE2, "cmd": 0xE3]
let namedKeys: [String: UInt16] = [
    "return": 0x28, "escape": 0x29, "delete": 0x2A, "tab": 0x2B, "space": 0x2C, "forward-delete": 0x4C,
    "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
]
/// Character → usage and whether Shift is held.
let characterKeys: [Character: (usage: UInt16, shift: Bool)] = {
    var map: [Character: (usage: UInt16, shift: Bool)] = ["\n": (0x28, false), "\t": (0x2B, false), " ": (0x2C, false)]
    for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
        map[c] = (0x04 + UInt16(i), false)
        map[Character(c.uppercased())] = (0x04 + UInt16(i), true)
    }
    for (i, (plain, shifted)) in zip("1234567890", "!@#$%^&*()").enumerated() {
        map[plain] = (0x1E + UInt16(i), false)
        map[shifted] = (0x1E + UInt16(i), true)
    }
    let pairs: [(UInt16, Character, Character)] = [
        (0x2D, "-", "_"), (0x2E, "=", "+"), (0x2F, "[", "{"), (0x30, "]", "}"), (0x31, "\\", "|"),
        (0x33, ";", ":"), (0x34, "'", "\""), (0x35, "`", "~"), (0x36, ",", "<"), (0x37, ".", ">"), (0x38, "/", "?"),
    ]
    for (usage, plain, shifted) in pairs {
        map[plain] = (usage, false)
        map[shifted] = (usage, true)
    }
    return map
}()

@main struct HID {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { fail("usage: iphone-hid DEVICE VERB ARGS...") }
        let id = args.removeFirst().uppercased(), verb = args.removeFirst()
        let side = args.first.flatMap { Double($0) == nil ? $0 : nil }
        let n = args.compactMap(Double.init)
        func number(_ i: Int, _ fallback: Double? = nil) -> Double {
            if i < n.count { return n[i] }
            if let fallback { return fallback }
            fail("\(verb) needs more numbers")
        }

        // The device list fills in from the CoreDevice service just after launch.
        var device: RemoteDevice?
        for _ in 0..<60 {
            device = DeviceManager.shared.allDevices().first { $0.deviceIdentifier.uuidString == id }
            if device != nil { break }
            await sleep(ms: 50)
        }
        guard let device else { fail("device \(id) not found; is it connected and unlocked?") }

        if verb == "type" || verb == "key" {
            let keyboard: any HIDKeyboard
            do {
                guard let found = try await implementation(device, CapabilityStaticMember<KeyboardHIDCapability>()) as? any HIDKeyboard
                else { fail("the device has no keyboard") }
                keyboard = found
            } catch {
                fail("no keyboard: \(error)")
            }
            func send(_ usage: UInt16, _ state: HIDButtonState) async {
                do { try keyboard.send(key: HIDKeyboardUsageCode(rawValue: usage), state: state) }
                catch { fail("key failed: \(error)") }
                await sleep(ms: 25)
            }
            /// Modifiers go down first and up last, as a hand presses a shortcut.
            func press(_ usage: UInt16, _ modifiers: [UInt16]) async {
                for m in modifiers { await send(m, .down) }
                await send(usage, .down)
                await send(usage, .up)
                for m in modifiers.reversed() { await send(m, .up) }
            }
            guard let text = args.first else { fail("\(verb) needs an argument") }
            if verb == "type" {
                var skipped = ""
                for character in text {
                    guard let key = characterKeys[character] else { skipped.append(character); continue }
                    await press(key.usage, key.shift ? [modifierKeys["shift"]!] : [])
                }
                if !skipped.isEmpty {
                    FileHandle.standardError.write(Data("iphone: no key types \(skipped.debugDescription) on a US layout; skipped\n".utf8))
                }
            } else {
                var modifiers = args.dropFirst().map { name -> UInt16 in
                    guard let usage = modifierKeys[name] else { fail("unknown modifier \(name)") }
                    return usage
                }
                let usage: UInt16
                if let named = namedKeys[text] {
                    usage = named
                } else if text.count == 1, let key = characterKeys[text.first!] {
                    usage = key.usage
                    if key.shift, !modifiers.contains(0xE1) { modifiers.append(0xE1) }
                } else {
                    fail("unknown key \(text)")
                }
                await press(usage, modifiers)
            }
            keyboard.sendBarrier()
            return
        }

        let digitizer: any HIDDigitizer
        do {
            guard let found = try await implementation(device, CapabilityStaticMember<DigitizerHIDCapability>()) as? any HIDDigitizer
            else { fail("the device has no digitizer") }
            digitizer = found
        } catch {
            fail("no digitizer: \(error)")
        }

        func send(_ one: CGPoint, _ two: CGPoint?, _ type: DigitizerEventType, _ edge: DigitizerEdge = .none) {
            do { try digitizer.send(pointOne: one, pointTwo: two, eventType: type, edge: edge, target: .mainScreen) }
            catch { fail("send failed: \(error)") }
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        /// Fingers down at `from`, moved at a steady speed to `to` over `ms`, an update every 8 ms.
        func move(_ from: [CGPoint], _ to: [CGPoint], ms: Double, press: Double = 0, rest: Double = 0, edge: DigitizerEdge = .none) async {
            send(from[0], from.count > 1 ? from[1] : nil, .start, edge)
            if press > 0 { await sleep(ms: press) }
            let steps = max(4, Int(ms / 8))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                send(lerp(from[0], to[0], t), from.count > 1 ? lerp(from[1], to[1], t) : nil, .position, edge)
                await sleep(ms: ms / Double(steps))
            }
            if rest > 0 {
                // Held still before lifting, so the release carries no velocity.
                send(to[0], to.count > 1 ? to[1] : nil, .position, edge)
                await sleep(ms: rest)
            }
            send(to[0], to.count > 1 ? to[1] : nil, .end, edge)
        }

        switch verb {
        case "check":
            break
        case "tap":
            let p = CGPoint(x: number(0), y: number(1))
            send(p, nil, .start)
            await sleep(ms: number(2, 70))
            send(p, nil, .end)
        case "double-tap":
            let p = CGPoint(x: number(0), y: number(1))
            send(p, nil, .start); await sleep(ms: 50); send(p, nil, .end)
            await sleep(ms: 90)
            send(p, nil, .start); await sleep(ms: 50); send(p, nil, .end)
        case "move":
            await move([CGPoint(x: number(0), y: number(1))], [CGPoint(x: number(2), y: number(3))],
                       ms: number(4), press: number(5, 0), rest: number(6, 0))
        case "pinch":
            let c = CGPoint(x: number(0), y: number(1)), from = number(2), to = number(3)
            await move([CGPoint(x: c.x - from, y: c.y), CGPoint(x: c.x + from, y: c.y)],
                       [CGPoint(x: c.x - to, y: c.y), CGPoint(x: c.x + to, y: c.y)], ms: number(4))
        case "edge":
            let edge: DigitizerEdge
            switch side {
            case "left"?: edge = .left
            case "right"?: edge = .right
            case "top"?: edge = .top
            case "bottom"?: edge = .bottom
            default: fail("edge needs left, right, top or bottom")
            }
            await move([CGPoint(x: number(0), y: number(1))], [CGPoint(x: number(2), y: number(3))], ms: number(4), edge: edge)
        default:
            fail("unknown verb \(verb)")
        }
        digitizer.sendBarrier()
    }
}
