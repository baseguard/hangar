import HangarKit
import HangarSupport
import SwiftUI

struct JobView: View {
    static let textWidth: CGFloat = 460

    let job: CreationJob
    let select: (UUID?) -> Void
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: Metrics.openSpacing) {
            OSBadge(os: job.os, size: Metrics.iconSize)
            JobHeadline(job: job)
            if job.error == nil {
                JobProgress(progress: job.progress)
                    .frame(maxWidth: Self.textWidth)
                CancelJobButton(job: job, confirmingCancel: $confirmingCancel, select: select)
            } else {
                FailedJobActions(job: job, select: select)
            }
        }
        .scenePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(job.name)
        .navigationSubtitle(job.error == nil ? "Creating" : "Failed")
    }
}

private struct JobHeadline: View {
    let job: CreationJob

    var body: some View {
        VStack {
            Text(job.error == nil ? "Creating “\(job.name)”" : "Couldn't Create “\(job.name)”")
                .font(.title2.weight(.semibold))
            Text(job.error ?? job.progress.phase)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: JobView.textWidth)
        }
    }
}

private struct JobProgress: View {
    let progress: CreationProgress

    var body: some View {
        VStack(spacing: Metrics.spacing) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(progress.detail ?? " ")
                Spacer()
                if let fraction = progress.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

private struct CancelJobButton: View {
    @Environment(VMStore.self) private var store
    let job: CreationJob
    @Binding var confirmingCancel: Bool
    let select: (UUID?) -> Void

    var body: some View {
        Button("Cancel", role: .cancel) { confirmingCancel = true }
            .controlSize(.large)
            .confirmationDialog(
                "Stop creating “\(job.name)”?", isPresented: $confirmingCancel, titleVisibility: .visible
            ) {
                Button("Stop Creating") {
                    store.cancelJob(job.id)
                    select(nil)
                }
            } message: {
                Text("What was set up so far is removed. Downloads are kept, so trying again is faster.")
            }
    }
}

private struct FailedJobActions: View {
    @Environment(VMStore.self) private var store
    let job: CreationJob
    let select: (UUID?) -> Void

    var body: some View {
        HStack {
            Button("Remove") {
                store.dismissJob(job.id)
                select(nil)
            }
            Button("Try Again") { select(store.retryJob(job.id)) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }
}
