import Foundation
import IOKit
import WhatCableCore

/// Watches `IOIOThunderboltSwitch` services and assembles them into a normalised
/// list of `IOThunderboltSwitch` models. Modelled on `AppleHPMInterfaceWatcher`:
///
/// - Match notification on the abstract parent class so all subclass variants
///   come in (we've seen `Type3`, `Type5`, `Type7`, `IntelJHL8440`, and
///   `IntelJHL9580` so far, and there will be more once new silicon ships).
/// - Per-service interest notifications for property changes (link state
///   moves, dock plug/unplug). Mirrors the USB-C watcher's pattern.
/// - `refresh()` re-walks the registry; `read()`-style consumers can call it
///   on every snapshot read.
/// - The factory in `WhatCableCore.IOThunderboltSwitch.from(...)` does the
///   actual property decoding so unit tests can run on hand-built dictionaries.
@MainActor
public final class IOIOThunderboltSwitchWatcher: ObservableObject {
    @Published public private(set) var switches: [IOThunderboltSwitch] = []

    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var interestNotifications: [UInt64: io_object_t] = [:]

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        // C callback bridge: capture self via Unmanaged so the IOKit
        // notification machinery can call us back. Same pattern as
        // AppleHPMInterfaceWatcher and USBPDSOPWatcher.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<IOIOThunderboltSwitchWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                // Drain the iterator so the kernel re-arms the notification,
                // then do a full re-walk so we pick up parent linkage and
                // sort consistently.
                while case let s = IOIteratorNext(iterator), s != 0 {
                    IOObjectRelease(s)
                }
                watcher.refresh()
            }
        }

        let matching = IOServiceMatching("IOIOThunderboltSwitch")
        var iter: io_iterator_t = 0
        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            matching,
            cb,
            selfPtr,
            &iter
        ) == KERN_SUCCESS {
            matchIterator = iter
            // Drain the initial set the kernel hands back so the notification
            // re-arms. The actual model build happens in refresh().
            while case let s = IOIteratorNext(iter), s != 0 {
                IOObjectRelease(s)
            }
            refresh()
        }
    }

    public func stop() {
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        for (_, n) in interestNotifications { IOObjectRelease(n) }
        interestNotifications.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        switches.removeAll()
    }

    /// Re-walk every `IOIOThunderboltSwitch` service. Cheap to call on every
    /// snapshot read, mirroring `AppleHPMInterfaceWatcher.refresh()`. Property
    /// changes (link-state moves) tend to arrive via interest notifications
    /// but we don't rely on them for correctness.
    public func refresh() {
        let matching = IOServiceMatching("IOIOThunderboltSwitch")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            if !switches.isEmpty { switches = [] }
            return
        }
        defer { IOObjectRelease(iter) }

        // First pass: build a list of (service, props, parent entry ID) so
        // we can resolve parent UIDs in a second pass once every switch has
        // been parsed.
        //
        // The parent linkage is keyed by registry entry ID (the stable
        // 64-bit identifier IOKit assigns per registry object), not by the
        // raw `io_service_t` mach-port value. Different IOKit calls can
        // hand back different mach-port handles for the same registry
        // object, so a port-handle keyed lookup would silently miss and
        // collapse the topology to "host only".
        struct RawEntry {
            let service: io_service_t
            let className: String
            // UID extracted up-front so we can build the UID lookup table in
            // the first pass without a second IOKit call. The full property
            // read happens in the second pass via per-key reads.
            let uid: Int64?
            let entryID: UInt64
            let parentEntryID: UInt64  // 0 if no IOIOThunderboltSwitch parent
        }

        var raw: [RawEntry] = []
        defer {
            for entry in raw {
                IOObjectRelease(entry.service)
            }
        }

        while case let service = IOIteratorNext(iter), service != 0 {
            // Read everything we need before deciding to keep or release.
            var className = "<unknown>"
            var nameBuf = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(service, &nameBuf) == KERN_SUCCESS {
                className = String(cString: nameBuf)
            }

            // Read keys individually rather than fetching the full property
            // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
            // can abort the process from inside IOCFUnserializeBinary when
            // the kernel returns a malformed serialised properties blob,
            // typically when the service is being torn down mid-read. The
            // per-key call has no such failure path. See issue #181.
            func readProp(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // Extract UID now so we can build the UID lookup table in the
            // first pass. The full IOThunderboltSwitch.from(read:) call
            // happens in the second pass while the service is still alive.
            let uid = (readProp("UID") as? NSNumber)?.int64Value

            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)

            // Walk up to the nearest IOIOThunderboltSwitch ancestor (skipping
            // adapter / port intermediaries). On Apple Silicon, downstream
            // switches sit below their parent switch in the IOService plane,
            // so this gives us the parent linkage for free. We resolve the
            // parent's registry entry ID immediately and release the
            // ancestor handle so we don't have to track its lifetime.
            let parentEntryID = parentSwitchEntryID(of: service)

            raw.append(RawEntry(
                service: service,
                className: className,
                uid: uid,
                entryID: entryID,
                parentEntryID: parentEntryID
            ))
        }

        // Build a UID lookup keyed by registry entry ID. Stable across
        // separate IOKit calls, unlike the raw mach-port handle.
        var uidByEntryID: [UInt64: Int64] = [:]
        for entry in raw {
            if let uid = entry.uid {
                uidByEntryID[entry.entryID] = uid
            }
        }

        var rebuilt: [IOThunderboltSwitch] = []
        rebuilt.reserveCapacity(raw.count)

        for entry in raw {
            // If UID was unreadable in the first pass, skip -- from() would
            // return nil for the same reason and we'd waste parsePorts + all
            // other per-key reads getting there.
            guard let uid = entry.uid else { continue }

            let ports = parsePorts(of: entry.service)
            let parentUID: Int64? = entry.parentEntryID != 0
                ? uidByEntryID[entry.parentEntryID]
                : nil

            // The service is still alive here (released by the defer above
            // after this loop finishes), so per-key reads are safe.
            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry.service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // Pass the UID read in the first pass so from() does not make a
            // second IOKit round-trip for the same key.
            if let model = IOThunderboltSwitch.from(
                uid: uid,
                read: read,
                className: entry.className,
                ports: ports,
                parentSwitchUID: parentUID
            ) {
                rebuilt.append(model)
                registerInterest(for: entry.service, entryID: entry.entryID)
            }
        }

        // Stable order: host roots first (Depth=0), then by Route String, then UID.
        rebuilt.sort { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.routeString != rhs.routeString { return lhs.routeString < rhs.routeString }
            return lhs.id < rhs.id
        }

        if rebuilt != switches { switches = rebuilt }
    }

    /// Walk port children of a switch service. Returns the parsed ports
    /// in registry order. Skips non-port children (driver shims sometimes
    /// hang off a switch service).
    private func parsePorts(of switchService: io_service_t) -> [IOThunderboltPort] {
        var ports: [IOThunderboltPort] = []
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(switchService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return ports
        }
        defer { IOObjectRelease(childIter) }

        while case let child = IOIteratorNext(childIter), child != 0 {
            defer { IOObjectRelease(child) }

            // Class name must contain "Port" to qualify; this filters out
            // the adapter shims (AppleThunderboltUSBDownAdapter etc.) which
            // are driver matches rather than registry-backed ports.
            var classBuf = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(child, &classBuf) == KERN_SUCCESS else { continue }
            let className = String(cString: classBuf)
            guard className.contains("Port") else { continue }

            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(child, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if let port = IOThunderboltPort.from(read: read) {
                ports.append(port)
            }
        }
        ports.sort { $0.portNumber < $1.portNumber }
        return ports
    }

    /// Walk up the IOService plane and return the registry entry ID of the
    /// nearest ancestor whose class is an IOIOThunderboltSwitch. Returns `0`
    /// if no such ancestor is found. The walker manages all IOKit handle
    /// lifetimes internally so callers don't have to track ownership.
    ///
    /// Returning the entry ID (a stable 64-bit identifier per registry
    /// object) rather than the raw service handle avoids a class of bug
    /// where two `io_service_t` values for the same registry object
    /// compare unequal because IOKit can hand back distinct mach-port
    /// handles for the same underlying entry.
    private func parentSwitchEntryID(of service: io_service_t) -> UInt64 {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<32 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return 0
            }
            // Move ownership into `current` for the next iteration / cleanup.
            IOObjectRelease(current)
            current = parent

            var classBuf = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(current, &classBuf) == KERN_SUCCESS {
                let name = String(cString: classBuf)
                // Match the abstract prefix; covers Type3 / Type5 / Type7 /
                // IntelJHL8440 / IntelJHL9580 / future variants.
                if name.hasPrefix("IOIOThunderboltSwitch") {
                    var entryID: UInt64 = 0
                    if IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS {
                        return entryID
                    }
                    return 0
                }
            }
        }
        return 0
    }

    /// Subscribe to property changes on a switch service. Apple's IOKit
    /// fires `kIOMessageServicePropertyChange` when link state moves
    /// (e.g. dock cable plugged), so this gives us a refresh trigger
    /// without polling. Same pattern as `AppleHPMInterfaceWatcher.registerInterest`.
    private func registerInterest(for service: io_service_t, entryID: UInt64) {
        guard let notifyPort, interestNotifications[entryID] == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let watcher = Unmanaged<IOIOThunderboltSwitchWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in watcher.refresh() }
        }
        var notification: io_object_t = 0
        let result = IOServiceAddInterestNotification(
            notifyPort,
            service,
            kIOGeneralInterest,
            cb,
            selfPtr,
            &notification
        )
        if result == KERN_SUCCESS {
            interestNotifications[entryID] = notification
        }
    }
}
