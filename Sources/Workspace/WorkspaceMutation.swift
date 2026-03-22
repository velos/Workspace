import Foundation

/// Whether a workspace mutation was previewed or executed.
public enum MutationMode: String, Sendable, Codable {
    /// The workspace mutation was only previewed.
    case preview
    /// The workspace mutation was executed against the backing filesystem.
    case execution
}

/// The failure handling strategy used when applying a workspace mutation.
public enum MutationFailurePolicy: String, Sendable, Codable {
    /// Restore the original state when any execution step fails.
    case rollback
    /// Stop at the first failure and leave any already-applied changes in place.
    case failFast
    /// Continue after failures and report all failed steps.
    case bestEffort
}

/// The execution status for a planned or applied workspace change.
public enum MutationStatus: String, Sendable, Codable {
    /// The change was only planned during preview.
    case planned
    /// The change was successfully applied.
    case applied
    /// The change failed while being applied.
    case failed
    /// The change was applied, then reverted due to rollback.
    case rolledBack
    /// The change was never attempted because execution stopped earlier.
    case skipped
}
