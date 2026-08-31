import AppKit
import SwiftUI

struct SlurmMenuView: View {
    @ObservedObject var monitor: SlurmMonitor
    @State private var now = Date()
    private let refreshTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let panelWidth: CGFloat = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topBar
            if let issue = monitor.issue {
                ErrorBanner(
                    title: issue.title,
                    message: issue.message,
                    actionTitle: issue.kind == .notConfigured ? "Open Settings" : "Retry",
                    action: {
                        if issue.kind == .notConfigured {
                            openSettings()
                        } else {
                            monitor.fetch(force: true)
                        }
                    }
                )
            }
            jobsSection
            footerBar
        }
        .padding(16)
        .frame(width: panelWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(8)
        .onReceive(refreshTicker) { date in
            now = date
        }
    }

    private var hasSuccessfulFetch: Bool {
        monitor.lastSuccessfulFetchDate != nil
    }

    @Environment(\.openSettings) private var openSettings

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Slurm Queue")
                    .font(.title2.weight(.bold))
                    .bold()
                Text(monitor.host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                refreshStatusText
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

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
            } else if let lastSuccess = monitor.lastSuccessfulFetchDate {
                Text("Last successful refresh \(lastSuccess, style: .relative)")
            } else if let lastAttempt = monitor.lastFetchDate {
                Text("Last refresh attempt \(lastAttempt, style: .relative)")
            } else {
                Text("Press refresh to load jobs.")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Queue")
                    .font(.title3.weight(.semibold))
                Spacer()
                if hasSuccessfulFetch, let last = monitor.lastSuccessfulFetchDate {
                    Text("Updated \(last, style: .relative)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !hasSuccessfulFetch {
                JobsPlaceholder(text: initialPlaceholderText)
            } else if monitor.totalJobCount > 0 && monitor.jobs.isEmpty {
                JobsPlaceholder(text: "Queue counts loaded, but detailed rows were not available. Refresh again to retry the detailed view.")
            } else if monitor.jobs.isEmpty {
                JobsPlaceholder(text: "You have no running or queued jobs.")
            } else {
                let visibleJobs = Array(monitor.jobs.prefix(AppConfig.maxVisibleJobs))
                Group {
                    if visibleJobs.count <= 4 {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(visibleJobs, id: \.renderIdentity) { job in
                                JobCardView(job: job)
                            }
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(visibleJobs, id: \.renderIdentity) { job in
                                    JobCardView(job: job)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: 420)
                    }
                }
                if monitor.totalJobCount > visibleJobs.count {
                    Text("Showing \(visibleJobs.count) of \(monitor.totalJobCount) jobs")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var initialPlaceholderText: String {
        if monitor.issue?.kind == .notConfigured {
            return "Configure your host, username, auth mode, and command in Preferences, then refresh."
        }
        if monitor.issue != nil {
            return "No successful data load yet. Fix the error above, then refresh again."
        }
        return "No data yet. Refresh to see your jobs."
    }

    private var footerBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                footerCounts
                Spacer(minLength: 8)
                footerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    footerCounts
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer(minLength: 0)
                    footerActions
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var footerCounts: some View {
        Group {
            QueueCountPill(color: .green, label: "Running", count: monitor.runningJobCount)
            QueueCountPill(color: .orange, label: "Pending", count: monitor.pendingJobCount)
            if monitor.otherJobCount > 0 {
                QueueCountPill(color: .blue, label: "Other", count: monitor.otherJobCount)
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button {
                openSettings()
            } label: {
                Label("Preferences", systemImage: "gearshape")
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Quit Hive Squeue Menu")
        }
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var monitor: SlurmMonitor

    var body: some View {
        HStack(spacing: 4) {
            MenuStatusIcon(
                runningCount: monitor.runningJobCount,
                pendingCount: monitor.pendingJobCount,
                otherCount: monitor.otherJobCount,
                isFetching: monitor.isFetching,
                issue: monitor.issue
            )
            Text(monitor.menuTitle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hive Slurm Queue")
        .accessibilityValue(Text(monitor.accessibilityStatus))
    }
}

struct MenuStatusIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runningCount: Int
    let pendingCount: Int
    let otherCount: Int
    let isFetching: Bool
    let issue: MonitorIssue?

    private let iconSize: CGFloat = 16
    private let badgeOffset: CGFloat = 3

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundTint)
                    .frame(width: iconSize, height: iconSize)

                MenuBarHiveArt()
                    .frame(width: iconSize, height: iconSize)

                if isFetching {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.blue, lineWidth: 1.7)
                        .frame(width: iconSize, height: iconSize)
                        .rotationEffect(.degrees(isFetching && !reduceMotion ? 360 : 0))
                        .animation(
                            reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
                            value: isFetching
                        )
                }
            }

            if issue != nil {
                Image(systemName: issue?.kind == .notConfigured ? "slider.horizontal.3" : "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.red.opacity(0.95), in: Circle())
                    .offset(x: badgeOffset, y: -badgeOffset)
            } else if totalJobs > 0, !isFetching {
                Text(totalJobs > 9 ? "9+" : "\(totalJobs)")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(badgeTint, in: Capsule())
                    .offset(x: badgeOffset, y: -badgeOffset)
            }
        }
        .frame(width: iconSize, height: iconSize)
    }

    private var totalJobs: Int {
        QueueCounts.saturatingAdd(
            QueueCounts.saturatingAdd(runningCount, pendingCount),
            otherCount
        )
    }

    private var backgroundTint: Color {
        if issue != nil {
            return Color.orange.opacity(0.22)
        }
        if isFetching {
            return Color.blue.opacity(0.16)
        }
        if runningCount > 0 {
            return Color.green.opacity(0.12)
        }
        if pendingCount > 0 {
            return Color.orange.opacity(0.12)
        }
        if otherCount > 0 {
            return Color.blue.opacity(0.12)
        }
        return Color.gray.opacity(0.08)
    }

    private var badgeTint: Color {
        if runningCount > 0 && pendingCount > 0 {
            return Color.orange.opacity(0.95)
        }
        if runningCount > 0 {
            return Color.green.opacity(0.92)
        }
        if pendingCount > 0 {
            return Color.orange.opacity(0.92)
        }
        return Color.blue.opacity(0.92)
    }
}

private struct MenuBarHiveArt: View {
    var body: some View {
        ZStack {
            Text("H")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.76, blue: 0.14),
                            Color(red: 0.95, green: 0.64, blue: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(x: -1, y: 0.2)

            Image(systemName: "hexagon.fill")
                .font(.system(size: 5.5, weight: .bold))
                .foregroundStyle(Color(red: 0.06, green: 0.22, blue: 0.43))
                .offset(x: 4.5, y: 3.8)
        }
    }
}

struct QueueCountPill: View {
    let color: Color
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(SlurmMonitor.abbreviatedJobCount(count))
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(count)")
    }
}

struct JobsPlaceholder: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JobCardView: View {
    let job: SlurmJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.displayName)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(job.compactMetadataLine)
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(job.runtimeBadgeDisplay)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(.secondary)
                    StateBadge(state: job.displayState)
                }
            }

            JobInlineFactRow(icon: "cpu", text: job.resourceLineDisplay)
            JobInlineFactRow(icon: "folder", text: job.pathLineDisplay)

            if let reason = job.stateReasonDisplay {
                JobInlineFactRow(icon: "info.circle", text: reason)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct JobInlineFactRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .padding(.top, 1)

            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(icon == "folder" ? .middle : .tail)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct StateBadge: View {
    let state: JobState

    var body: some View {
        Text(state.label)
            .font(.footnote.weight(.bold))
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
    let title: String
    let message: String
    var actionTitle = "Retry"
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.primary)
                
                if let action {
                    Button(actionTitle, action: action)
                        .font(.body.weight(.semibold))
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
