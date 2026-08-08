import SwiftUI

// MARK: - Drive Speed (F-043 / NFeat-121)
//
// Read & write throughput benchmark for internal and external drives,
// reporting both average (sustained) and optimal (peak) speeds.

@MainActor
final class DriveSpeedViewModel: ObservableObject {
    @Published var volumes: [DriveVolume] = []
    @Published var selectedVolumeID: String?
    @Published var size: DriveTestSize = .standard

    @Published var isRunning = false
    @Published var phaseText = ""
    @Published var percent: Double = 0
    @Published var liveMBps: Double = 0
    @Published var result: DriveSpeedResult?
    @Published var errorMessage: String?

    private let tester = DriveSpeedTester()
    private var task: Task<Void, Never>?

    var selectedVolume: DriveVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    func loadVolumes() {
        Task {
            let vols = await tester.availableVolumes()
            self.volumes = vols
            if selectedVolumeID == nil || !vols.contains(where: { $0.id == selectedVolumeID }) {
                self.selectedVolumeID = vols.first?.id
            }
        }
    }

    func run() {
        guard let volume = selectedVolume, !isRunning else { return }
        errorMessage = nil
        result = nil
        isRunning = true
        percent = 0
        liveMBps = 0
        phaseText = "Preparing…"

        task = Task {
            do {
                let res = try await tester.run(volume: volume, size: size) { [weak self] p in
                    Task { @MainActor in self?.apply(p) }
                }
                await MainActor.run {
                    self.result = res
                    self.isRunning = false
                    self.percent = 1
                    self.phaseText = "Done"
                }
            } catch is CancellationError {
                await MainActor.run { self.finishCancelled() }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                    self.phaseText = ""
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finishCancelled() {
        isRunning = false
        phaseText = ""
        percent = 0
    }

    private func apply(_ progress: DriveSpeedProgress) {
        switch progress {
        case .preparing:
            phaseText = "Preparing…"
        case let .writing(pass, of, pct, mbps):
            phaseText = "Writing · pass \(pass)/\(of)"
            percent = pct
            liveMBps = mbps
        case let .reading(pass, of, pct, mbps):
            phaseText = "Reading · pass \(pass)/\(of)"
            percent = pct
            liveMBps = mbps
        case .done(let res):
            result = res
            isRunning = false
            phaseText = "Done"
            percent = 1
        }
    }
}

struct DriveSpeedView: View {
    @StateObject private var vm = DriveSpeedViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                volumePicker
                sizePicker
                controls
                if let err = vm.errorMessage { errorBanner(err) }
                if vm.isRunning { progressCard }
                if let result = vm.result { resultsSection(result) }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .background(Color.haloSurface)
        .onAppear { vm.loadVolumes() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drive Speed Test")
                .font(HaloFont.display(18, weight: .bold))
                .foregroundColor(.haloText)
            Text("Benchmark read & write throughput for internal and external drives. Uncached I/O with a full device flush — reports sustained average and peak (optimal) speeds.")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Volume picker

    private var volumePicker: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("DRIVE")
                    .font(HaloFont.body(10, weight: .semibold))
                    .foregroundColor(.haloText2)
                if vm.volumes.isEmpty {
                    Text("No writable volumes found.")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                } else {
                    ForEach(vm.volumes) { vol in
                        volumeRow(vol)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func volumeRow(_ vol: DriveVolume) -> some View {
        let selected = vm.selectedVolumeID == vol.id
        return Button {
            vm.selectedVolumeID = vol.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: vol.iconName)
                    .foregroundColor(selected ? .haloAccent : .haloText2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vol.name).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                        HaloBadge(text: vol.kindLabel, color: vol.isInternal ? .haloAccent : .haloGreen)
                    }
                    Text("\(byteString(vol.freeBytes)) free of \(byteString(vol.totalBytes))")
                        .font(HaloFont.body(11)).foregroundColor(.haloText2)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.haloAccent)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(selected ? Color.haloAccent.opacity(0.08) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(vm.isRunning)
    }

    // MARK: Size picker

    private var sizePicker: some View {
        HStack(spacing: 8) {
            ForEach(DriveTestSize.allCases) { s in
                Button {
                    vm.size = s
                } label: {
                    VStack(spacing: 2) {
                        Text(s.rawValue).font(HaloFont.body(12, weight: .semibold))
                        Text(s.subtitle).font(HaloFont.body(9))
                    }
                    .foregroundColor(vm.size == s ? .haloText : .haloText2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(vm.size == s ? Color.haloSurface2 : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(vm.size == s ? Color.haloBorder2 : Color.haloBorder, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(vm.isRunning)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            HaloPrimaryButton(vm.isRunning ? "Testing…" : "Run Speed Test",
                              icon: "speedometer",
                              isLoading: vm.isRunning) {
                vm.run()
            }
            .disabled(vm.selectedVolume == nil || vm.isRunning)

            if vm.isRunning {
                HaloGhostButton("Cancel", icon: "stop.fill") { vm.cancel() }
            }
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(vm.phaseText).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                    Spacer()
                    Text(String(format: "%.0f MB/s", vm.liveMBps))
                        .font(HaloFont.mono(13)).foregroundColor(.haloAccent)
                }
                ProgressView(value: vm.percent)
                    .tint(.haloAccent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Results

    private func resultsSection(_ r: DriveSpeedResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                speedCard(title: "Write", icon: "arrow.down.to.line",
                          average: r.writeAverageMBps, optimal: r.writeOptimalMBps,
                          accent: .haloAmber)
                speedCard(title: "Read", icon: "arrow.up.to.line",
                          average: r.readAverageMBps, optimal: r.readOptimalMBps,
                          accent: .haloGreen)
            }
            HaloCard {
                HStack {
                    metaItem("Volume", r.volumeName)
                    Divider().frame(height: 26).background(Color.haloBorder)
                    metaItem("Data", byteString(r.fileSizeBytes))
                    Divider().frame(height: 26).background(Color.haloBorder)
                    metaItem("Passes", "\(r.passes)")
                    Divider().frame(height: 26).background(Color.haloBorder)
                    metaItem("Samples", "\(r.sampleCount)")
                    Spacer()
                }
                .padding(14)
            }
        }
    }

    private func speedCard(title: String, icon: String,
                           average: Double, optimal: Double, accent: Color) -> some View {
        HaloCard(accentTop: accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundColor(accent)
                    Text(title).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f", average))
                        .font(HaloFont.display(30)).foregroundColor(.haloText)
                    + Text(" MB/s avg").font(HaloFont.body(12)).foregroundColor(.haloText2)
                }
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundColor(accent)
                    Text(String(format: "Optimal %.0f MB/s", optimal))
                        .font(HaloFont.body(12)).foregroundColor(.haloText2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metaItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(HaloFont.body(9, weight: .semibold)).foregroundColor(.haloText2)
            Text(value).font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.haloRed)
            Text(message).font(HaloFont.body(12)).foregroundColor(.haloText)
            Spacer()
        }
        .padding(12)
        .background(Color.haloRed.opacity(0.1))
        .cornerRadius(10)
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
