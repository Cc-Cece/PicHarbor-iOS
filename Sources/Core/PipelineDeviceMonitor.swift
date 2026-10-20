import Foundation
import Darwin
import os

enum PipelineDeviceMonitor {
    static func read(home: URL, memoryWarningUntil: TimeInterval) -> PipelineConditions {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        let process = ProcessInfo.processInfo
        let disk = (try? FileManager.default.attributesOfFileSystem(forPath: home.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return PipelineConditions(machine: machine, memoryGB: Int((process.physicalMemory + 500_000_000) / 1_000_000_000),
                                  availableMemory: UInt64(os_proc_available_memory()), processors: process.activeProcessorCount,
                                  thermal: process.thermalState.rawValue, lowPower: process.isLowPowerModeEnabled,
                                  memoryWarning: process.systemUptime < memoryWarningUntil, freeDisk: disk)
    }
}
