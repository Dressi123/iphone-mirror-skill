import Foundation
import CoreDevice

/// Generic on purpose: inside, A.ProtocolType is the framework's own, read at runtime from
/// its witness table, never the placeholder the interface declares.
@inline(never) @_optimize(none)
func implementation<A: DeviceCapability>(_ device: RemoteDevice, _ member: CapabilityStaticMember<A>) async throws -> Any {
    try await device.getImplementation(for: member)
}

@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        let manager = DeviceManager.shared
        var devices: [RemoteDevice] = []
        for _ in 0..<50 {
            devices = manager.allDevices()
            if !devices.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        for d in devices { print("device", d.deviceIdentifier) }
        guard args.count >= 2, let device = devices.first(where: { $0.deviceIdentifier.uuidString == args[1] }) else { return }
        let any = try await implementation(device, CapabilityStaticMember<DigitizerHIDCapability>())
        print("implementation:", type(of: any))
        guard let digitizer = any as? any HIDDigitizer else { print("not an HIDDigitizer"); return }
        guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { print("digitizer ok"); return }
        let point = CGPoint(x: x, y: y)
        try digitizer.send(pointOne: point, pointTwo: nil, eventType: .start, edge: .none, target: .mainScreen)
        try await Task.sleep(for: .milliseconds(80))
        try digitizer.send(pointOne: point, pointTwo: nil, eventType: .end, edge: .none, target: .mainScreen)
        digitizer.sendBarrier()
        print("tapped", point)
    }
}
