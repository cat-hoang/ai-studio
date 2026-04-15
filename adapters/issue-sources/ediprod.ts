/**
 * ediProd legacy adapter — thin TypeScript wrapper around the existing
 * query-bm-startable.ts + PAVE API pipeline.
 *
 * This adapter is NOT invoked by the PS1 script (the PS1 handles ediprod
 * natively via its existing OData/PAVE flow). This module exists so that
 * TypeScript callers (e.g. future orchestrator code) can invoke ediprod
 * through the same IssueSourceAdapter interface as every other backend.
 *
 * When issue_source.adapter is set to "ediprod" in config.yaml, the PS1
 * get-ratatosk-startable-jobs.ps1 falls through to its built-in ediprod path
 * and this file is NOT executed.
 *
 * Config section (config.yaml / config.local.yaml):
 *   issue_source:
 *     adapter: ediprod
 *     ediprod:
 *       staff_code: ABC             # overrides top-level staff_code
 *       board_name: "My Board"      # overrides top-level board_name
 */
import path from 'path';
import type { IssueSourceAdapter, AdapterConfig, FetchResult, Issue, IssueStatus } from './types.ts';

const ADAPTER = 'ediprod';

export const ediprodAdapter: IssueSourceAdapter = {
  async fetchStartable(config: AdapterConfig): Promise<FetchResult> {
    const { section } = config;

    // Resolve paths
    const repoRoot = path.resolve(import.meta.dirname, '..', '..');
    const scriptPath = path.join(repoRoot, 'tools', 'query-bm-startable.ts');

    // Delegate to the existing BM OData script via bun subprocess
    const proc = Bun.spawn(['bun', scriptPath], {
      env: process.env,
      cwd: repoRoot,
      stdout: 'pipe',
      stderr: 'ignore',
    });

    const rawOutput = await new Response(proc.stdout).text();
    await proc.exited;

    if (proc.exitCode !== 0) {
      return {
        warnings: [`${ADAPTER}: query-bm-startable.ts exited with code ${proc.exitCode}`],
        issues: [],
      };
    }

    // Parse the JSON blob (strip any pino log lines before it)
    const parsed = extractJsonWithKey(rawOutput, 'results');
    if (!parsed) {
      return {
        warnings: [`${ADAPTER}: query-bm-startable.ts produced no parseable output`],
        issues: [],
      };
    }

    const items: unknown[] = parsed['results'] ?? parsed['Results'] ?? [];
    const staffCode = section['staff_code'] ?? config.staffId ?? '';

    const issues: Issue[] = items
      .filter((r): r is Record<string, unknown> => !!r && typeof r === 'object')
      .map(r => bmResultToIssue(r, staffCode));

    return { warnings: [], issues };
  },

  async claim(_issueId: string, _config: AdapterConfig): Promise<void> {
    // ediProd claim is handled by the edi CLI (edi task claim).
    // Workers call the edi CLI directly; this adapter no-ops for claim.
  },

  async appendNote(issueId: string, note: string, _config: AdapterConfig): Promise<void> {
    const repoRoot = path.resolve(import.meta.dirname, '..', '..');
    const scriptPath = path.join(repoRoot, 'tools', 'ratatosk-task-notes.ts');

    const proc = Bun.spawn(
      ['bun', scriptPath, '--action', 'append', '--task', issueId, '--note', note],
      { env: process.env, cwd: repoRoot, stdout: 'ignore', stderr: 'ignore' },
    );
    await proc.exited;

    if (proc.exitCode !== 0) {
      throw new Error(`${ADAPTER}: appendNote failed for ${issueId} (exit ${proc.exitCode})`);
    }
  },

  async updateStatus(_issueId: string, _status: IssueStatus, _config: AdapterConfig): Promise<void> {
    // ediProd status is managed via `edi task suspend` only (per hard rules).
    // Workers handle this directly; this adapter no-ops to avoid violating those rules.
  },
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function bmResultToIssue(r: Record<string, unknown>, staffCode: string): Issue {
  const jobNumber = str(r['jobNumber']);
  const taskType = str(r['type']) || 'feature';
  const desc = str(r['description']) || str(r['jobSummary']);

  return {
    jobNumber,
    jobGuid: str(r['parentJobPk']) || jobNumber,
    taskSequence: str(r['sequence']),
    taskType,
    staffCode: str(r['assignedStaff']) || staffCode,
    startableTasks: [{ taskSequence: str(r['sequence']), taskType, taskDescription: desc }],
    summary: str(r['jobSummary']) || desc,
    description: desc,
    zone: 0,
    source: ADAPTER,
    sources: [ADAPTER],
    jobUrl: '',
  };
}

function extractJsonWithKey(output: string, key: string): Record<string, unknown> | null {
  // Scan for a JSON object line that contains the given key
  let depth = 0;
  let inObj = false;
  const collected: string[] = [];

  for (const line of output.split('\n')) {
    if (!inObj) {
      if (line.trimStart().startsWith('{')) {
        inObj = true;
        collected.length = 0;
        depth = 0;
      } else {
        continue;
      }
    }
    collected.push(line);
    for (const ch of line) {
      if (ch === '{') depth++;
      else if (ch === '}') depth--;
    }
    if (depth <= 0) {
      const candidate = collected.join('\n');
      if (candidate.includes(`"${key}"`)) {
        try {
          return JSON.parse(candidate) as Record<string, unknown>;
        } catch {
          // corrupted chunk — keep scanning
        }
      }
      inObj = false;
    }
  }
  return null;
}

function str(v: unknown): string {
  if (v == null) return '';
  return String(v);
}
