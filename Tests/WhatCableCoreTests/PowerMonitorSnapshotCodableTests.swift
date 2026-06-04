import Foundation
import Testing
@testable import WhatCableCore

struct PowerMonitorSnapshotCodableTests {

    @Test("Round-trips with the per-port metering capability bit")
    func roundTripsCapabilityBit() throws {
        let snapshot = PowerMonitorSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            systemSample: PowerSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                      systemVoltageIn: 5000, systemCurrentIn: 1000, systemPowerIn: 5000),
            portSamples: [],
            resistanceEstimate: nil,
            perPortMeteringSupported: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: data)
        #expect(decoded.perPortMeteringSupported)
        #expect(decoded == snapshot)
    }

    @Test("Decodes a legacy snapshot missing newer keys without throwing")
    func decodesLegacyJSONWithDefaults() throws {
        // A snapshot as an older build would have encoded it: no perPortMetering
        // Supported, no hasContract, no battery fields. Must default, not throw.
        let legacy = """
        {
            "timestamp": 1700000000,
            "systemSample": { "timestamp": 1700000000, "systemVoltageIn": 0, "systemCurrentIn": 0, "systemPowerIn": 0 },
            "portSamples": []
        }
        """
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.perPortMeteringSupported == false)
        #expect(decoded.hasContract == false)
        #expect(decoded.externalConnected == true)   // desktop-friendly default
        #expect(decoded.batteryInstalled == false)
    }
}
