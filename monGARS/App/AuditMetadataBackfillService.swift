import Foundation
import SwiftData

@MainActor
enum AuditMetadataBackfillService {
    static func run(context: ModelContext) {
        do {
            var changed = false
            changed = try backfillApprovals(context: context) || changed
            changed = try backfillToolCalls(context: context) || changed
            if changed {
                try context.safeSave()
            }
        } catch {
            context.insert(AgentTraceRecord(
                runID: UUID(),
                stepIndex: 0,
                phase: "auditBackfill",
                message: "Audit metadata backfill failed: \(DiagnosticsRedactor.redact(error.localizedDescription, maxLength: 240))"
            ))
            try? context.safeSave()
        }
    }

    private static func backfillApprovals(context: ModelContext) throws -> Bool {
        let records = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        var changed = false

        for approval in records {
            let hadMissingMetadata = approval.toolName.isEmpty
                || approval.normalizedArgumentsJSON == "{}"
                || approval.payloadHash.isEmpty
                || approval.userVisibleDiff.isEmpty
                || approval.expiresAt.timeIntervalSince(approval.createdAt) < 0
                || approval.expiresAt.timeIntervalSince(approval.createdAt) > 86_400

            guard hadMissingMetadata else { continue }

            if approval.toolName.isEmpty {
                approval.toolName = approval.actionName
            }
            approval.sessionID = approval.runID

            let legacyInput = approval.userVisibleDiff.isEmpty ? approval.reason : approval.userVisibleDiff
            let arguments = approval.normalizedArgumentsJSON == "{}"
                ? ApprovalTupleHasher.normalizedArguments(toolName: approval.toolName, input: legacyInput, target: approval.target)
                : ApprovalTupleHasher.normalizedJSON(approval.normalizedArgumentsJSON)
            approval.normalizedArgumentsJSON = arguments

            approval.riskLevelRawValue = ApprovalPolicy.normalizedRisk(approval.riskLevelRawValue).rawValue
            if approval.userVisibleDiff.isEmpty {
                approval.userVisibleDiff = approval.reason
            }
            approval.expiresAt = ApprovalPolicy.expirationDate(from: approval.createdAt)
            approval.payloadHash = ApprovalTupleHasher.payloadHash(
                toolName: approval.toolName,
                target: approval.target,
                normalizedArgumentsJSON: approval.normalizedArgumentsJSON,
                riskLevel: approval.riskLevelRawValue,
                sessionID: approval.sessionID
            )
            changed = true
        }

        return changed
    }

    private static func backfillToolCalls(context: ModelContext) throws -> Bool {
        let records = try context.fetch(FetchDescriptor<ToolCallRecord>())
        var changed = false

        for call in records {
            let missingArguments = call.normalizedArgumentsJSON == "{}"
            let missingHash = call.payloadHash.isEmpty
            guard missingArguments || missingHash else { continue }

            call.sessionID = call.runID
            if missingArguments {
                call.normalizedArgumentsJSON = ApprovalTupleHasher.normalizedArguments(
                    toolName: call.toolName,
                    input: call.input,
                    target: call.target
                )
            } else {
                call.normalizedArgumentsJSON = ApprovalTupleHasher.normalizedJSON(call.normalizedArgumentsJSON)
            }
            call.payloadHash = ApprovalTupleHasher.payloadHash(
                toolName: call.toolName,
                target: call.target,
                normalizedArgumentsJSON: call.normalizedArgumentsJSON,
                riskLevel: call.riskLevel,
                sessionID: call.sessionID
            )
            if isBestEffortLegacy(call), call.errorCategory == nil {
                call.errorCategory = "legacy_audit_hash_best_effort"
            }
            changed = true
        }

        return changed
    }

    private static func isBestEffortLegacy(_ call: ToolCallRecord) -> Bool {
        call.input.contains("[REDACTED]")
            || call.input.contains("[TRUNCATED]")
            || call.target?.contains("[REDACTED]") == true
            || call.target?.contains("[TRUNCATED]") == true
    }
}
