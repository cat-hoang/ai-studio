/**
 * File adapter — reads issues from a local JSON file.
 *
 * Useful for offline testing, demos, and custom pipelines that write issues
 * to a known file location.
 *
 * Config section (config.yaml / config.local.yaml):
 *
 *   issue_source:
 *     adapter: file
 *     file:
 *       path: issues.json         # path to the issues file (relative to autotask root or absolute)
 *
 * File format — array of Issue objects (same schema as the canonical Issue type),
 * or a simplified shorthand:
 *
 *   [
 *     {
 *       "jobNumber": "TASK-001",
 *       "summary": "Add login page",
 *       "description": "Implement the OAuth2 login page",
 *       "taskType": "feature",
 *       "zone": 2,
 *       "jobUrl": "https://tracker.example.com/TASK-001"
 *     }
 *   ]
 *
 * All Issue fields not present in the file default to safe empty values.
 * The file is read fresh on each fetchStartable call (no caching).
 */
import fs from 'fs';
import path from 'path';
import type { IssueSourceAdapter, AdapterConfig, FetchResult, Issue, IssueStatus } from './types.ts';

const ADAPTER = 'file';

export const fileAdapter: IssueSourceAdapter = {
  async fetchStartable(config: AdapterConfig): Promise<FetchResult> {
    const { section } = config;

    const filePath = resolveFilePath(section['path'] ?? 'issues.json');

    if (!fs.existsSync(filePath)) {
      return {
        warnings: [`${ADAPTER}: issues file not found at ${filePath}`],
        issues: [],
      };
    }

    let raw: unknown;
    try {
      raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (err: unknown) {
      return {
        warnings: [`${ADAPTER}: failed to parse ${filePath} — ${errMsg(err)}`],
        issues: [],
      };
    }

    if (!Array.isArray(raw)) {
      return {
        warnings: [`${ADAPTER}: expected a JSON array in ${filePath}`],
        issues: [],
      };
    }

    const issues: Issue[] = raw.map((item, idx) => normalizeIssue(item, idx));
    return { warnings: [], issues };
  },

  async claim(_issueId: string, _config: AdapterConfig): Promise<void> {
    // File adapter: no remote system to update — no-op
  },

  async appendNote(_issueId: string, _note: string, _config: AdapterConfig): Promise<void> {
    // File adapter: no remote comments — no-op
  },

  async updateStatus(_issueId: string, _status: IssueStatus, _config: AdapterConfig): Promise<void> {
    // File adapter: no remote status — no-op
  },
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function resolveFilePath(filePath: string): string {
  if (path.isAbsolute(filePath)) return filePath;
  // Resolve relative to the autotask repo root (parent of adapters/)
  const repoRoot = path.resolve(import.meta.dirname, '..', '..');
  return path.join(repoRoot, filePath);
}

function normalizeIssue(item: unknown, idx: number): Issue {
  if (!item || typeof item !== 'object') {
    return emptyIssue(`FILE-${idx + 1}`);
  }

  const r = item as Record<string, unknown>;

  const issueId = str(r['issueId']) || str(r['jobNumber']) || str(r['id']) || str(r['key']) || `FILE-${idx + 1}`;
  const taskType = str(r['taskType']) || str(r['type']) || inferTaskTypeFromTitle(str(r['summary']) || '');

  return {
    issueId,
    jobGuid: str(r['jobGuid']) || str(r['guid']) || issueId,
    taskSequence: str(r['taskSequence']) || undefined,
    taskType,
    assignee: str(r['assignee']) || str(r['staffCode']) || '',
    startableTasks: Array.isArray(r['startableTasks'])
      ? r['startableTasks'] as Issue['startableTasks']
      : [{ taskType, taskDescription: str(r['summary']) || '' }],
    summary: str(r['summary']) || str(r['title']) || issueId,
    description: str(r['description']) || str(r['summary']) || '',
    zone: typeof r['zone'] === 'number' ? r['zone'] : parseInt(str(r['zone']) || '0', 10) || 0,
    source: ADAPTER,
    sources: [ADAPTER],
    jobUrl: str(r['jobUrl']) || str(r['url']) || '',
  };
}

function emptyIssue(issueId: string): Issue {
  return {
    issueId,
    jobGuid: issueId,
    taskType: 'feature',
    assignee: '',
    startableTasks: [{ taskType: 'feature', taskDescription: '' }],
    summary: issueId,
    description: '',
    zone: 0,
    source: ADAPTER,
    sources: [ADAPTER],
    jobUrl: '',
  };
}

function str(v: unknown): string {
  if (v == null) return '';
  return String(v);
}

function inferTaskTypeFromTitle(title: string): string {
  const lower = title.toLowerCase();
  if (lower.includes('bug') || lower.includes('fix')) return 'bugfix';
  if (lower.includes('feature') || lower.includes('enhancement')) return 'feature';
  if (lower.includes('investigation')) return 'investigation';
  if (lower.includes('refactor')) return 'refactor';
  if (lower.includes('test')) return 'test';
  return 'feature';
}

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
