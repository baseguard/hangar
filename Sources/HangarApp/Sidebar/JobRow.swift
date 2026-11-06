import HangarKit
import HangarSupport
import SwiftUI

struct JobRow: View {
    let job: CreationJob

    var body: some View {
        HStack {
            OSBadge(os: job.os)
                .opacity(job.error == nil ? 0.55 : 0.35)
                .overlay {
                    if job.error == nil {
                        ProgressView(value: job.progress.fraction ?? 0)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                            .opacity(job.progress.fraction == nil ? 0 : 1)
                    }
                }
            VStack(alignment: .leading) {
                Text(job.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(job.error == nil ? job.progress.phase : "Couldn't create")
                    .font(.caption)
                    .foregroundStyle(job.error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            Spacer()
            if job.error != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if job.progress.fraction == nil {
                ProgressView().controlSize(.mini)
            }
        }
    }
}
