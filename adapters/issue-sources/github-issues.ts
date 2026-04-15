/**
 * GitHub Issues adapter.
 *
 * Config section (config.yaml / config.local.yaml):
 *
 *   issue_source:
 *     adapter: github-issues
 *     github_issues:
 *       repo: owner/repo           # required
 *       labels: ready-for-dev      # comma-separated label filter (optional)
 *       assignee: me               # "me" or a specific username (optional)
 *       token_env: GITHUB_TOKEN    # env var containing the PAT (default: GITHUB_TOKEN)
 *       per_page: "50"             # max issues to fetch per request (default: 50)
 */
import type { IssueSourceAdapter, AdapterConfig, FetchResult, Issue, IssueStatus } from './types.ts';

const GITHUB_API = 'https://api.github.com';
const ADAPTER = 'github-issues';

export const githubIssuesAdapter: IssueSourceAdapter = {
  async fetchStartable(config: AdapterConfig): Promise<FetchResult> {
    const { section, staffId } = config;
    const warnings: string[] = [];

    const repo = section['repo'] ?? '';
    if (!repo) {
      return {
        warnings: [`${ADAPTER}: repo not configured — set issue_source.github_issues.repo`],
        issues: [],
      };
    }

    const token = resolveToken(section);
    if (!token) {
      const envName = section['token_env'] ?? 'GITHUB_TOKEN';
      return {
        warnings: [`${ADAPTER}: ${envName} environment variable is not set`],
        issues: [],
      };
    }

    const perPage = parseInt(section['per_page'] ?? '50', 10);
    const params = new URLSearchParams({ state: 'open', per_page: String(perPage) });

    const labels = section['labels'] ?? '';
    if (labels) params.set('labels', labels);

    const assignee = section['assignee'] ?? 'me';
    if (assignee) params.set('assignee', assignee);

    let rawIssues: GHIssue[];
    try {
      const res = await fetch(`${GITHUB_API}/repos/${repo}/issues?${params}`, {
        headers: githubHeaders(token),
      });

      if (!res.ok) {
        const body = await res.text().catch(() => '');
        return {
          warnings: [`${ADAPTER}: API error ${res.status} ${res.statusText} — ${body.slice(0, 200)}`],
          issues: [],
        };
      }

      rawIssues = (await res.json()) as GHIssue[];
    } catch (err: unknown) {
      return { warnings: [`${ADAPTER}: network error — ${errMsg(err)}`], issues: [] };
    }

    // The issues endpoint also returns PRs; exclude them
    const issues: Issue[] = rawIssues
      .filter(i => !i.pull_request)
      .map(i => ghIssueToIssue(i, staffId));

    return { warnings, issues };
  },

  async claim(issueId: string, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const { repo, token } = requireRepoAndToken(section, issueId);
    const num = parseNumber(issueId);

    const res = await fetch(`${GITHUB_API}/repos/${repo}/issues/${num}/labels`, {
      method: 'POST',
      headers: { ...githubHeaders(token), 'Content-Type': 'application/json' },
      body: JSON.stringify({ labels: ['in-progress'] }),
    });

    if (!res.ok) {
      throw new Error(`${ADAPTER}: claim failed for ${issueId} — HTTP ${res.status}`);
    }
  },

  async appendNote(issueId: string, note: string, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const { repo, token } = requireRepoAndToken(section, issueId);
    const num = parseNumber(issueId);

    const res = await fetch(`${GITHUB_API}/repos/${repo}/issues/${num}/comments`, {
      method: 'POST',
      headers: { ...githubHeaders(token), 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: note }),
    });

    if (!res.ok) {
      throw new Error(`${ADAPTER}: appendNote failed for ${issueId} — HTTP ${res.status}`);
    }
  },

  async updateStatus(issueId: string, status: IssueStatus, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const { repo, token } = requireRepoAndToken(section, issueId);
    const num = parseNumber(issueId);

    const label = STATUS_LABEL_MAP[status] ?? status;

    const res = await fetch(`${GITHUB_API}/repos/${repo}/issues/${num}/labels`, {
      method: 'POST',
      headers: { ...githubHeaders(token), 'Content-Type': 'application/json' },
      body: JSON.stringify({ labels: [label] }),
    });

    if (!res.ok) {
      throw new Error(`${ADAPTER}: updateStatus failed for ${issueId} — HTTP ${res.status}`);
    }
  },
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

interface GHIssue {
  id: number;
  number: number;
  title: string;
  body?: string | null;
  html_url: string;
  pull_request?: unknown;
  assignee?: { login: string } | null;
  labels?: Array<{ name: string } | string>;
}

function ghIssueToIssue(i: GHIssue, staffId: string): Issue {
  const labelNames = (i.labels ?? []).map(l => (typeof l === 'string' ? l : l.name ?? ''));
  const taskType = inferTaskType(labelNames);
  const desc = (i.body ?? i.title ?? '').slice(0, 500);

  return {
    jobNumber: `GH-${i.number}`,
    jobGuid: String(i.id),
    taskSequence: '',
    taskType,
    staffCode: i.assignee?.login ?? staffId,
    startableTasks: [{ taskSequence: '', taskType, taskDescription: i.title }],
    summary: i.title ?? '',
    description: desc,
    zone: inferZone(labelNames),
    source: ADAPTER,
    sources: [ADAPTER],
    jobUrl: i.html_url ?? '',
  };
}

function githubHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
}

function resolveToken(section: Record<string, string>): string {
  const envName = section['token_env'] ?? 'GITHUB_TOKEN';
  return process.env[envName] ?? '';
}

function requireRepoAndToken(section: Record<string, string>, issueId: string) {
  const repo = section['repo'] ?? '';
  const token = resolveToken(section);
  if (!repo || !token) {
    throw new Error(`${ADAPTER}: repo or token not configured (issue: ${issueId})`);
  }
  return { repo, token };
}

function parseNumber(issueId: string): string {
  return issueId.replace(/^GH-/i, '');
}

function inferTaskType(labels: string[]): string {
  const lower = labels.map(l => l.toLowerCase());
  if (lower.some(l => l.includes('bug') || l.includes('fix'))) return 'bugfix';
  if (lower.some(l => l.includes('feature') || l.includes('enhancement'))) return 'feature';
  if (lower.some(l => l.includes('investigation') || l.includes('research'))) return 'investigation';
  if (lower.some(l => l.includes('refactor'))) return 'refactor';
  if (lower.some(l => l.includes('test'))) return 'test';
  return 'feature';
}

function inferZone(labels: string[]): number {
  const lower = labels.map(l => l.toLowerCase());
  if (lower.some(l => l === 'p0' || l.includes('critical'))) return 1;
  if (lower.some(l => l === 'p1' || l.includes('high'))) return 2;
  if (lower.some(l => l === 'p2' || l.includes('medium'))) return 3;
  return 0;
}

const STATUS_LABEL_MAP: Record<string, string> = {
  claimed: 'claimed',
  'in-design': 'in-design',
  'in-progress': 'in-progress',
  'in-review': 'in-review',
  done: 'done',
};

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
