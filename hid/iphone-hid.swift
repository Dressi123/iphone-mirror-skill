// iphone-hid — touches on a device through Xcode's CoreDevice remote digitizer: the same
// service Device Hub turns clicks into, called directly, so nothing on the Mac moves.
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
