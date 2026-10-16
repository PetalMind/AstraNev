#if os(iOS)
import MapLibre
import Metal

/// Actual sampled command-buffer GPU time, separate from CPU encoding and
/// callback cadence. This measures the shared map buffer, not an isolated model.
nonisolated final class MapRenderDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var lastGPURequest = 0.0
    private var gpu: [(time: Double, milliseconds: Double)] = []
    private var cpu: [Double] = []
    private var encoding: [Double] = []
    private var intervals: [Double] = []
    private var previousFrame = 0.0
    private var lastReport = 0.0

    func sample(_ buffer: MTLCommandBuffer) {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard now - lastGPURequest >= 1 else { lock.unlock(); return }
        lastGPURequest = now
        lock.unlock()
        buffer.addCompletedHandler { [weak self] completed in
            let start = completed.gpuStartTime, end = completed.gpuEndTime
            guard let self, completed.status == .completed, start > 0, end > start else { return }
            self.lock.lock()
            self.gpu.append((ProcessInfo.processInfo.systemUptime, (end - start) * 1_000))
            self.gpu = Array(self.gpu.suffix(16))
            self.lock.unlock()
        }
        #endif
    }

    func frame(_ stats: MLNRenderingStats) -> String? {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let elapsed = now - previousFrame
        previousFrame = now
        // Idle maps do not request frames. Do not report that idle time as slow FPS.
        if elapsed > 0, elapsed < 0.25 { intervals.append(elapsed) }
        let cpuTime = stats.renderingTime * 1_000
        if cpuTime.isFinite, cpuTime >= 0 { cpu.append(cpuTime) }
        if stats.encodingTime.isFinite, stats.encodingTime >= 0 { encoding.append(stats.encodingTime * 1_000) }
        encoding = Array(encoding.suffix(600))
        intervals = Array(intervals.suffix(600)); cpu = Array(cpu.suffix(600))
        guard now - lastReport >= 10 else { return nil }
        lastReport = now
        let recentGPU = gpu.filter { now - $0.time < 10 }.map(\.milliseconds)
        func mean(_ values: [Double]) -> String {
            values.isEmpty ? "brak danych" : String(format: "%.2f", locale: Locale(identifier: "pl_PL"), values.reduce(0, +) / Double(values.count))
        }
        let cadence = intervals.count >= 5 ? String(format: "%.1f", locale: Locale(identifier: "pl_PL"),
            Double(intervals.count) / intervals.reduce(0, +)) : "brak aktywnego przebiegu"
        let report = "Mapa: CPU renderowania średnio ms=\(mean(cpu)), CPU kodowania średnio ms=\(mean(encoding)), GPU bufora średnio ms=\(mean(recentGPU)), próbki GPU=\(recentGPU.count), rytm aktywnych klatek/s=\(cadence), wywołania rysowania=\(stats.numDrawCalls), pamięć tekstur=\(stats.memTextures), pamięć buforów=\(stats.memBuffers)"
        cpu.removeAll(keepingCapacity: true); encoding.removeAll(keepingCapacity: true); intervals.removeAll(keepingCapacity: true)
        return report
        #else
        return nil
        #endif
    }
}
#endif
