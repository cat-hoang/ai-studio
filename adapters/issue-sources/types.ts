/**
 * Shared types for the Ratatosk issue-source adapter layer.
 *
 * All adapters (GitHub Issues, Linear, Jira, file) produce Issues
 * in this canonical shape — the same shape that get-ratatosk-startable-jobs.ps1
 * and the dashboard consume.
 */

/** A sub-task belonging to a parent issue. */
export interface StartableTask {
  taskSequence: string;
  taskType: string;
  taskDescription?: string;
  taskZone?: number | null;
}

/**
 * Canonical issue representation shared across all adapters.
 * Field names intentionally mirror the existing `startableJobs` JSON schema so
 * that callers require no changes when switching adapters.
 */
export interface Issue {
  /** Human-readable identifier (e.g. "GH-123", "LIN-456", "WI01234567") */
  jobNumber: string;
  /** System-internal ID / GUID */
  jobGuid: string;
  /** Primary task sequence number; empty string for non-task-based systems */
  taskSequence: string;
  /** Issue type: feature | bugfix | investigation | refactor | test | … */
  taskType: string;
  /** Username of the assignee */
  assignee: string;
  /** Ordered list of startable sub-tasks */
  startableTasks: StartableTask[];
  /** Short title */
  summary: string;
  /** Longer description (truncated to ~500 chars if needed) */
  description: string;
  /** Priority zone: 0 = not set, lower = higher priority */
  zone: number;
  /** Name of the adapter that produced this record (e.g. "github-issues") */
  source: string;
  /** All sources that contributed (for merged/deduped results) */
  sources: string[];
  /** Web URL to view the issue */
  jobUrl: string;
}

/** Result returned by IssueSourceAdapter.fetchStartable(). */
export interface FetchResult {
  warnings: string[];
  issues: Issue[];
}

/**
 * Runtime config passed to every adapter method.
 * Built by query-issue-source.ts from the merged YAML config.
 */
export interface AdapterConfig {
  /** Which adapter is active */
  adapterName: string;
  /** Runtime config: resolved staff ID / username (from config or env) */
  staffId: string;
  /** Flat key:value pairs from the adapter's named YAML sub-section */
  section: Record<string, string>;
}

/** Status values passed to IssueSourceAdapter.updateStatus(). */
export type IssueStatus =
  | 'claimed'
  | 'in-design'
  | 'in-progress'
  | 'in-review'
  | 'done'
  | string; // adapters may accept additional system-specific values

/**
 * Interface every issue-source adapter must implement.
 * Only fetchStartable is required for Phase 1; the others default to no-ops.
 */
export interface IssueSourceAdapter {
  /** Fetch all issues that are ready to be claimed and worked on. */
  fetchStartable(config: AdapterConfig): Promise<FetchResult>;
  /** Claim an issue — assign to self and mark it as taken. */
  claim(issueId: string, config: AdapterConfig): Promise<void>;
  /** Append a note / comment to the issue. */
  appendNote(issueId: string, note: string, config: AdapterConfig): Promise<void>;
  /** Update the issue status (label, state field, etc.). */
  updateStatus(issueId: string, status: IssueStatus, config: AdapterConfig): Promise<void>;
}
