import Foundation
import IOKit
import WhatCableCore

/// Maps each port controller's `UUID` to its physical-port key.
///
/// On Apple Silicon M3 and later, every USB-C / MagSafe port has a power
/// controller of class `AppleHPMDeviceHALType3` that carries a stable `UUID`.
/// That same UUID is the SMC channel's `DxUI` (see ``SMCPowerReader``). Matching
/// the two ties an SMC power-OUT reading to the right physical port with no
/// index guessing, which matters because the SMC D-index and the IOKit `@N`
/// number do NOT agree (SMC `D3` can be `Port-USB-C@4`).
///
/// M1 / M2 use the older `AppleHPMDevice` class, which does not carry this UUID,
/// so this returns an empty map there and the caller falls back to the
/// no-per-port state. It deliberately does NOT guess a positional mapping.
///
/// The UUIDs here are an internal join key only. The returned map's *values*
/// are plain port keys (`"2/4"`, `"17/1"`); the UUID keys never leave this join.
public enum HPMPortUUIDMap {
    /// `[normalised-UUID : portKey]`, e.g. `["17bd562d…fa51": "2/4"]`. UUIDs are
    /// 32 lowercase hex chars (dashes stripped) to match `SMCPortPowerChannel.uuid`.
    public static func current() -> [String: String] {
        var map: [String: String] = [:]

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleHPMDeviceHALType3"),
            &iterator
        ) == KERN_SUCCESS else {
            return map
        }
        defer { IOObjectRelease(iterator) }

        while case let controller = IOIteratorNext(iterator), controller != 0 {
            defer { IOObjectRelease(controller) }
            // Read the controller's own UUID, never a descendant's. The PD
            // power options in the same subtree each carry their own UUID; that
            // one identifies a PDO option, not the port.
            guard let rawUUID = readString(controller, "UUID") else { continue }
            let uuid = normalise(rawUUID)
            guard uuid.count == 32 else { continue }
            guard let portKey = portKey(forController: controller) else { continue }
            // First controller wins on the off chance two report the same UUID.
            if map[uuid] == nil { map[uuid] = portKey }
        }
        return map
    }

    /// Finds the controller's physical port child (`Port-USB-C@N` /
    /// `Port-MagSafe 3@N`) and returns its `"rawType/number"` key, matching the
    /// convention used across the power pipeline (USB-C = `2`, MagSafe = `17`).
    private static func portKey(forController controller: io_service_t) -> String? {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(controller, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(child, &name) == KERN_SUCCESS else { continue }
            let childName = String(cString: name)
            guard childName.hasPrefix("Port-") else { continue }

            // Port number comes from the entry's location in the service plane
            // (the "@N" suffix), falling back to a descendant "Description".
            let number = portNumber(from: child)
            guard let number else { return nil }
            let rawType = childName.contains("MagSafe") ? 0x11 : 0x2
            return "\(rawType)/\(number)"
        }
        return nil
    }

    /// The `@N` port number for a `Port-` node: its location-in-plane, or, when
    /// that is empty, the number inside a descendant `Description` like
    /// `"Port-USB-C@1/CC"`.
    private static func portNumber(from port: io_service_t) -> Int? {
        var location = [CChar](repeating: 0, count: 128)
        // The pipeline treats the location-in-plane suffix as hex (radix 16),
        // same as `wcPortIndex`, so the key here lines up with the keys
        // `resolve()` and `hpmPortKeys()` build.
        if IORegistryEntryGetLocationInPlane(port, kIOServicePlane, &location) == KERN_SUCCESS,
           let value = Int(String(cString: location), radix: 16) {
            return value
        }
        if let description = findDescriptionLocation(port, depth: 0) {
            return description
        }
        return nil
    }

    /// Walks a few levels of descendants for a `Description` containing `@N`.
    private static func findDescriptionLocation(_ service: io_service_t, depth: Int) -> Int? {
        if depth > 4 { return nil }
        if let description = readString(service, "Description"),
           let atIndex = description.firstIndex(of: "@") {
            let after = description[description.index(after: atIndex)...]
            let digits = after.prefix { $0.isHexDigit }
            if let value = Int(digits, radix: 16) { return value }
        }
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }
        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let value = findDescriptionLocation(child, depth: depth + 1) { return value }
        }
        return nil
    }

    private static func readString(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else {
            return nil
        }
        return value
    }

    /// Strips dashes and lowercases a UUID string so it matches the SMC's raw
    /// 16-byte `DxUI` rendered as 32 hex chars.
    static func normalise(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
