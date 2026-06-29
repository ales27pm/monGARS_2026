import SwiftUI

struct ApprovalMetadataCard: View {
    let approval: ApprovalPresentation
    let resolve: (Bool) -> Void

    private var expired: Bool { Date() > approval.expiresAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(approval.toolName, systemImage: expired ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Text(approval.riskLevel.rawValue.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(expired ? Color.red.opacity(0.16) : Color.orange.opacity(0.16))
                    .clipShape(Capsule())
            }

            Text(approval.userVisibleDiff)
                .font(.caption)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                metadataRow("Target", approval.target ?? "local")
                metadataRow("Payload", approval.payloadHashPreview + "...")
                metadataRow("Session", approval.sessionPreview)
                metadataRow("Expires", expired ? "expired" : approval.expiresAt.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(approval.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    resolve(true)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(expired)

                Button(role: .destructive) {
                    resolve(false)
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
