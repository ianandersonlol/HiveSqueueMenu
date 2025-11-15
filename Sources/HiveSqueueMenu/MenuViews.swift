import AppKit
import SwiftUI

struct SlurmMenuView: View {
    @ObservedObject var monitor: SlurmMonitor
    @State private var now = Date()
    private let refreshTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            refreshControls
            if let error = monitor.error {
                ErrorBanner(message: error, retryAction: { monitor.fetch(force: true) })
            }
            statsSection
            Divider().overlay(Color.white.opacity(0.1))
            jobsSection
            Divider().overlay(Color.white.opacity(0.1))
            preferencesButton
        }
        .padding(16)
        .frame(width: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(8)
        .onReceive(refreshTicker) { date in
            now = date
        }
    }

    private var hasFetchedOnce: Bool {
        monitor.lastFetchDate != nil
    }

    @Environment(\.openSettings) private var openSettings

    private var preferencesButton: some View {
        Button("Preferences…") {
            openSettings()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Slurm Status")
                .font(.title3)
                .bold()
            Text(monitor.host)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var refreshControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                monitor.fetch()
            } label: {
                Label {
                    Text(monitor.isFetching ? "Refreshing…" : "Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(refreshDisabled)

            refreshStatusText
        }
    }

    private var refreshDisabled: Bool {
        monitor.isFetching || monitor.timeUntilNextAllowedRefresh(from: now) != nil
    }

    @ViewBuilder
    private var refreshStatusText: some View {
        Group {
            if monitor.isFetching {
                Text("Fetching latest job list…")
            } else if let remaining = monitor.timeUntilNextAllowedRefresh(from: now) {
                Text("Next refresh available in \(Int(ceil(remaining)))s")
            } else if let last = monitor.lastFetchDate {
                Text("Last refreshed \(last, style: .relative)")
            } else {
                Text("Press refresh to load jobs.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statsSection: some View {
        HStack(spacing: 12) {
            StatBubble(
                color: .green,
                label: "Running",
                count: monitor.runningJobs.count
            )
            StatBubble(
                color: .orange,
                label: "Pending",
                count: monitor.pendingJobs.count
            )
        }
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Jobs")
                    .font(.headline)
                Spacer()
                if hasFetchedOnce, let last = monitor.lastFetchDate {
                    Text("Updated \(last, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !hasFetchedOnce {
                JobsPlaceholder(text: "No data yet. Refresh to see your jobs.")
            } else if monitor.jobs.isEmpty {
                JobsPlaceholder(text: "You have no running or queued jobs.")
            } else {
                let visibleJobs = Array(monitor.jobs.prefix(AppConfig.maxVisibleJobs))
                ScrollView(.horizontal, showsIndicators: false) {
                    JobTableView(jobs: visibleJobs)
                        .frame(minWidth: JobTableLayout.minimumWidth, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity)
                if monitor.jobs.count > visibleJobs.count {
                    Text("Showing \(visibleJobs.count) of \(monitor.jobs.count) jobs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatBubble: View {
    let color: Color
    let label: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct JobsPlaceholder: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JobTableView: View {
    let jobs: [SlurmJob]
    private var lastJobId: Int? { jobs.last?.id }

    var body: some View {
        VStack(spacing: 0) {
            JobTableHeader()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
            Divider()
                .overlay(Color.white.opacity(0.08))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(jobs) { job in
                        JobTableRow(job: job)
                        if job.id != lastJobId {
                            Divider()
                                .overlay(Color.white.opacity(0.05))
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(minWidth: JobTableLayout.minimumWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum JobTableLayout {
    static let idWidth: CGFloat = 70
    static let partitionWidth: CGFloat = 85
    static let elapsedWidth: CGFloat = 90
    static let cpuWidth: CGFloat = 60
    static let memoryWidth: CGFloat = 80
    static let gpuWidth: CGFloat = 60
    static let stateWidth: CGFloat = 95
    static let nameMinWidth: CGFloat = 220
    static let columnSpacing: CGFloat = 12
    static let minimumWidth: CGFloat =
        idWidth + partitionWidth + elapsedWidth + cpuWidth +
        memoryWidth + gpuWidth + stateWidth + nameMinWidth +
        columnSpacing * 7
}

struct JobTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("ID")
                .frame(width: JobTableLayout.idWidth, alignment: .leading)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Partition")
                .frame(width: JobTableLayout.partitionWidth, alignment: .leading)
            Text("Elapsed")
                .frame(width: JobTableLayout.elapsedWidth, alignment: .trailing)
            Text("CPU")
                .frame(width: JobTableLayout.cpuWidth, alignment: .trailing)
            Text("Memory")
                .frame(width: JobTableLayout.memoryWidth, alignment: .leading)
            Text("GPU")
                .frame(width: JobTableLayout.gpuWidth, alignment: .trailing)
            Text("State")
                .frame(width: JobTableLayout.stateWidth, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }
}

struct JobTableRow: View {
    let job: SlurmJob

    var body: some View {
        HStack(spacing: 12) {
            Text(job.formattedId)
                .font(.system(.body, design: .monospaced))
                .frame(width: JobTableLayout.idWidth, alignment: .leading)
            Text(job.displayName)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(job.partitionDisplay)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: JobTableLayout.partitionWidth, alignment: .leading)
            Text(job.formattedElapsedTime)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: JobTableLayout.elapsedWidth, alignment: .trailing)
            Text(job.cpuSummary)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: JobTableLayout.cpuWidth, alignment: .trailing)
            Text(job.memorySummary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(width: JobTableLayout.memoryWidth, alignment: .leading)
            Text(job.gpuSummary)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: JobTableLayout.gpuWidth, alignment: .trailing)
            StateBadge(state: job.displayState)
                .frame(width: JobTableLayout.stateWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct StateBadge: View {
    let state: JobState

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var stateColor: Color {
        switch state {
        case .running:
            return .green
        case .pending:
            return .orange
        case .completing, .configuring:
            return .blue
        case .completed:
            return .gray
        case .failed:
            return .red
        case .cancelled:
            return .purple
        case .suspended:
            return .teal
        case .unknown:
            return .blue
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var retryAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                
                if let retryAction {
                    Button("Retry", action: retryAction)
                        .font(.footnote)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// #Preview {
//     let connection = ConnectionSettings(host: "hive-preview", username: "icanders", identityFilePath: nil, password: nil)
//     let monitor = SlurmMonitor(connection: connection)
//     monitor.jobs = [
//         SlurmJob(id: 42, name: "train_model", partition: "gpu", state: "RUNNING"),
//         SlurmJob(id: 99, name: "data-prep", partition: "cpu", state: "PENDING")
//     ]
//     monitor.error = "This is a preview error message to test the banner."
    
//     return SlurmMenuView(monitor: monitor)
//         .frame(width: 360)
//         .padding()
//         .background(.black)
//         .environment(\.colorScheme, .dark)
// }
