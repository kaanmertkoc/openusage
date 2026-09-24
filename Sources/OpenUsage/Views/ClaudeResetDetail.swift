import SwiftUI

/// Account-scoped Claude reset timeline. Hover reads status; only the second, explicit button click
/// calls confirm(). Separate grant identities avoid confusing resets that share an expiry date.
struct ClaudeResetDetail: View {
    let service: ClaudeResetClaimService
    var onHoverChange: (Bool) -> Void
    var onPinChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.displayName).font(.headline)
            if let message = service.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("claudeReset.result")
            }
            if service.isClaiming {
                HStack { ProgressView().controlSize(.small); Text("Resetting…") }
            } else if let selection = service.confirmation {
                confirmation(selection)
            } else if service.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Checking Resets…") }
            } else {
                if service.unresolved != nil {
                    Text("A previous reset request has an unconfirmed result. Retrying reuses that request.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry Same Request") { service.prepareRetry() }
                        .accessibilityIdentifier("claudeReset.retry")
                } else if service.status?.eligible == false || (service.status != nil && service.grants.isEmpty) {
                    Text("No resets available for this account.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(service.grants.enumerated()), id: \.element.id) { index, grant in
                        grantRow(grant, number: index + 1)
                    }
                }
                Button("Refresh Status") { Task { await service.load() } }
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 290)
        .task { await service.load() }
        .onHover(perform: onHoverChange)
        .onChange(of: service.confirmation != nil || service.isClaiming) { _, active in onPinChange(active) }
        .onDisappear {
            service.cancel()
            onPinChange(false)
        }
    }

    private func grantRow(_ grant: ClaudeResetStatus.Grant, number: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)").font(.caption.weight(.medium))
                .foregroundStyle(.white).frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(grant.label.isEmpty ? "Usage Limit Reset" : grant.label).font(.subheadline.weight(.medium))
                Text("\(grant.resetsLeft) available · \(grant.limitsDescription)").font(.caption)
                if let end = grant.endsAt {
                    Text("Expires \(end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No expiry reported").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = service.unavailableReason(grant) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Use") { service.prepare(grantID: grant.id) }
                .disabled(service.unavailableReason(grant) != nil)
                .accessibilityIdentifier("claudeReset.use.\(grant.id)")
        }
    }

    private func confirmation(_ selection: ClaudeResetClaimService.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use This Reset?").font(.subheadline.weight(.semibold))
            Text("Use one reset for \(service.displayName). This cannot be undone.")
            Text("Limits: \(selection.limits.map { ClaudeResetStatus.Grant.limitNames[$0] ?? $0 }.joined(separator: ", "))")
            Text("Your weekly reset day stays the same.").foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { service.cancel() }
                Spacer()
                Button("Confirm Reset") { Task { await service.confirm() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("claudeReset.confirm")
            }
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
