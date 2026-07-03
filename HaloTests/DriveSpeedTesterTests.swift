import Testing
import Foundation
@testable import Halo

// MARK: - DriveSpeedTester Tests  (F-043 / NFeat-121)

@Suite("DriveSpeedTester")
struct DriveSpeedTesterTests {

    @Test("Test-size byte amounts are correct and ordered")
    func testSizeBytes() {
        #expect(DriveTestSize.quick.bytes == 128 * 1_000_000)
        #expect(DriveTestSize.standard.bytes == 512 * 1_000_000)
        #expect(DriveTestSize.thorough.bytes == 1_000 * 1_000_000)
        #expect(DriveTestSize.quick.bytes < DriveTestSize.standard.bytes)
        #expect(DriveTestSize.standard.bytes < DriveTestSize.thorough.bytes)
    }

    @Test("Enumerates at least the internal boot volume")
    func testAvailableVolumes() async {
        let tester = DriveSpeedTester()
        let volumes = await tester.availableVolumes()
        #expect(!volumes.isEmpty)
        // The boot volume is internal; at least one internal volume must exist.
        #expect(volumes.contains { $0.isInternal })
        // Internal volumes are sorted ahead of external ones.
        if let firstExternalIndex = volumes.firstIndex(where: { !$0.isInternal }) {
            let internalAfter = volumes[(firstExternalIndex + 1)...].contains { $0.isInternal }
            #expect(!internalAfter, "Internal volumes should all precede external ones")
        }
    }

    @Test("Benchmark on internal volume yields positive average and optimal speeds")
    func testRunProducesPositiveSpeeds() async throws {
        let tester = DriveSpeedTester()
        let volumes = await tester.availableVolumes()
        guard let internalVol = volumes.first(where: { $0.isInternal }) else {
            Issue.record("No internal volume to benchmark")
            return
        }

        let result = try await tester.run(volume: internalVol, size: .quick) { _ in }

        #expect(result.writeAverageMBps > 0)
        #expect(result.readAverageMBps > 0)
        // Optimal (peak) is never slower than the sustained average.
        #expect(result.writeOptimalMBps >= result.writeAverageMBps)
        #expect(result.readOptimalMBps >= result.readAverageMBps)
        #expect(result.sampleCount > 0)
        #expect(result.fileSizeBytes == DriveTestSize.quick.bytes)
    }

    @Test("Insufficient free space throws before writing")
    func testInsufficientSpaceGuard() async {
        let tester = DriveSpeedTester()
        // A volume that claims only ~1 KB free — the guard must reject a 128 MB
        // Quick test before touching the disk.
        let tiny = DriveVolume(
            id: "/tmp/halo-tiny",
            name: "TinyVol",
            url: FileManager.default.temporaryDirectory,
            isInternal: true,
            isRemovable: false,
            totalBytes: 1_000_000,
            freeBytes: 1_000
        )
        await #expect(throws: DriveSpeedError.self) {
            _ = try await tester.run(volume: tiny, size: .quick) { _ in }
        }
    }

    @Test("Cancellation stops a run")
    func testCancellation() async {
        let tester = DriveSpeedTester()
        let volumes = await tester.availableVolumes()
        guard let vol = volumes.first(where: { $0.isInternal }) else { return }

        let task = Task {
            try await tester.run(volume: vol, size: .thorough) { _ in }
        }
        task.cancel()
        let didThrow: Bool
        do { _ = try await task.value; didThrow = false }
        catch { didThrow = true }
        #expect(didThrow, "Cancelled run should throw")
    }
}
