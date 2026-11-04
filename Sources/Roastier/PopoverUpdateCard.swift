import RoastierKit
import SwiftUI

/// What the popover's update card shows; `nil` when there is nothing to act on.
enum UpdateCardPhase: Equatable {
    case available(AppUpdateRelease)
    case downloading(AppUpdateRelease, progress: Double)
    case preparing(AppUpdateRelease)
    case ready(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case failed(AppUpdateFailure, AppUpdateRelease?)

    @MainActor
    init?(_ updates: AppUpdateManager) {
        switch updates.downloadState {
        case .downloading(let release, let progress):
            self = .downloading(release, progress: progress)
        case .staging(let release):
            self = .preparing(release)
        case .readyToInstall(let stagedUpdate):
            self = .ready(stagedUpdate.release)
        case .installing(let stagedUpdate):
            self = .installing(stagedUpdate.release)
        case .failed(let failure):
            self = .failed(failure, updates.latestRelease)
        case .idle:
            guard case .updateAvailable(let release) = updates.status else {
                return nil
            }
            self = .available(release)
        }
    }

    var release: AppUpdateRelease? {
        switch self {
        case .available(let release),
             .downloading(let release, _),
             .preparing(let release),
             .ready(let release),
             .installing(let release):
            release
        case .failed(_, let release):
            release
        }
    }
}

/// The popover's update status and action. It sits on the popover's glass, so it draws no background of its own.
struct PopoverUpdateCard: View {
    let phase: UpdateCardPhase
    let updates: AppUpdateManager

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .frame(width: 16)
            // Everything but the icon shares one column, so the link and progress bar line up with the title.
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if case .failed(let failure, _) = phase {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .downloading(_, let progress) = phase {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Download progress")
                }
                if phase.release != nil || action != nil {
                    HStack {
                        if let release = phase.release {
                            Link("Release notes", destination: release.htmlURL)
                                .font(.caption)
                        }
                        Spacer()
                        actionButton
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private extension PopoverUpdateCard {
    var title: String {
        switch phase {
        case .available(let release):
            "Roastier \(release.version) available"
        case .downloading(let release, _):
            "Downloading Roastier \(release.version)"
        case .preparing(let release):
            "Preparing Roastier \(release.version)"
        case .ready(let release):
            "Roastier \(release.version) is ready"
        case .installing:
            "Restarting to update…"
        case .failed:
            "Update failed"
        }
    }

    @ViewBuilder
    var icon: some View {
        switch phase {
        case .available, .downloading:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .preparing, .installing:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    enum Action {
        case download
        case restart
        case retry
    }

    var action: Action? {
        switch phase {
        case .available:
            .download
        case .ready:
            .restart
        case .failed:
            .retry
        case .downloading, .preparing, .installing:
            nil
        }
    }

    @ViewBuilder
    var actionButton: some View {
        switch action {
        case .download:
            Button("Download", action: check)
                .buttonStyle(.glass)
                .disabled(updates.isChecking)
        case .retry:
            Button("Retry", action: check)
                .buttonStyle(.glass)
                .disabled(updates.isChecking)
        case .restart:
            Button("Restart to Update") {
                Task {
                    await updates.installDownloadedUpdate()
                }
            }
            .buttonStyle(.glassProminent)
        case nil:
            EmptyView()
        }
    }

    func check() {
        Task {
            await updates.forceCheck()
        }
    }
}
