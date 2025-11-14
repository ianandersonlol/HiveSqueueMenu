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
        .frame(width: 360)
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
        Group {
            if !hasFetchedOnce {
                Text("No data yet. Refresh to see your jobs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else if monitor.jobs.isEmpty {
                Text("No active jobs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(monitor.jobs.prefix(AppConfig.maxVisibleJobs))) { job in
                            JobRow(job: job)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 250)
            }
        }
    }
}

struct StatBubble: View {
    let color: Color
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color.gradient)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline)
            Spacer(minLength: 10)
            Text("\(count)")
                .bold()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct JobRow: View {
    let job: SlurmJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text("#\(job.id)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                PartitionPill(text: job.partition)
                Spacer()
                StateBadge(state: job.displayState)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct PartitionPill: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct StateBadge: View {
    let state: JobState

    var body: some View {
        Text(state.label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(stateColor.opacity(0.15), in: Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch state {
        case .running:
            return .green
        case .pending:
            return .orange
        case .other:
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
