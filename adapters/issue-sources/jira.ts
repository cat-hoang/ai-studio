/**
 * Jira adapter.
 *
 * Config section (config.yaml / config.local.yaml):
 *
 *   issue_source:
 *     adapter: jira
 *     jira:
 *       base_url: https://yourorg.atlassian.net   # required
 *       project_key: ENG                          # required
 *       status: "To Do"                           # JQL status filter (default: "To Do")
 *       assignee: currentUser()                   # JQL assignee clause (default: currentUser())
 *       jql: ""                                   # optional full JQL override (ignores project/status/assignee)
 *       token_env: JIRA_TOKEN                     # env var for Jira API token (default: JIRA_TOKEN)
 *       email_env: JIRA_EMAIL                     # env var for account email used in basic auth (default: JIRA_EMAIL)
 *       per_page: "50"                            # max results (default: 50)
 *
 * Auth: HTTP Basic using email:token (Atlassian cloud standard).
 */
import type { IssueSourceAdapter, AdapterConfig, FetchResult, Issue, IssueStatus } from './types.ts';

const ADAPTER = 'jira';

export const jiraAdapter: IssueSourceAdapter = {
  async fetchStartable(config: AdapterConfig): Promise<FetchResult> {
    const { section, staffId } = config;
    const warnings: string[] = [];

    const baseUrl = (section['base_url'] ?? '').replace(/\/$/, '');
    if (!baseUrl) {
      return {
        warnings: [`${ADAPTER}: base_url not configured — set issue_source.jira.base_url`],
        issues: [],
      };
    }

    const projectKey = section['project_key'] ?? '';
    const auth = resolveAuth(section);
    if (!auth) {
      const tokenEnv = section['token_env'] ?? 'JIRA_TOKEN';
      const emailEnv = section['email_env'] ?? 'JIRA_EMAIL';
      return {
        warnings: [`${ADAPTER}: credentials not set — ensure ${emailEnv} and ${tokenEnv} env vars are set`],
        issues: [],
      };
    }

    const maxResults = parseInt(section['per_page'] ?? '50', 10);

    let jql: string;
    if (section['jql']) {
      jql = section['jql'];
    } else {
      if (!projectKey) {
        return {
          warnings: [`${ADAPTER}: project_key not configured — set issue_source.jira.project_key`],
          issues: [],
        };
      }
      const status = section['status'] ?? 'To Do';
      const assignee = section['assignee'] ?? 'currentUser()';
      jql = `project = "${projectKey}" AND status = "${status}" AND assignee = ${assignee} ORDER BY priority ASC`;
    }

    let rawIssues: JiraIssue[];
    try {
      const params = new URLSearchParams({
        jql,
        maxResults: String(maxResults),
        fields: 'summary,description,issuetype,priority,status,assignee,labels',
      });

      const res = await fetch(`${baseUrl}/rest/api/3/search?${params}`, {
        headers: {
          Authorization: `Basic ${auth}`,
          Accept: 'application/json',
        },
      });

      if (!res.ok) {
        const body = await res.text().catch(() => '');
        return {
          warnings: [`${ADAPTER}: API error ${res.status} ${res.statusText} — ${body.slice(0, 200)}`],
          issues: [],
        };
      }

      const json = (await res.json()) as { issues?: JiraIssue[] };
      rawIssues = json.issues ?? [];
    } catch (err: unknown) {
      return { warnings: [`${ADAPTER}: network error — ${errMsg(err)}`], issues: [] };
    }

    const issues: Issue[] = rawIssues.map(i => jiraIssueToIssue(i, baseUrl, staffId));
    return { warnings, issues };
  },

  async claim(issueId: string, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const baseUrl = (section['base_url'] ?? '').replace(/\/$/, '');
    const auth = resolveAuth(section);
    if (!baseUrl || !auth) throw new Error(`${ADAPTER}: credentials or base_url missing`);

    const jiraKey = parseJiraKey(issueId);

    // Transition to "In Progress"
    const transitionId = await resolveTransitionId(baseUrl, auth, jiraKey, 'In Progress');
    if (!transitionId) {
      throw new Error(`${ADAPTER}: could not find "In Progress" transition for ${jiraKey}`);
    }

    const res = await fetch(`${baseUrl}/rest/api/3/issue/${jiraKey}/transitions`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ transition: { id: transitionId } }),
    });

    if (!res.ok) throw new Error(`${ADAPTER}: claim transition failed for ${jiraKey} — HTTP ${res.status}`);
  },

  async appendNote(issueId: string, note: string, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const baseUrl = (section['base_url'] ?? '').replace(/\/$/, '');
    const auth = resolveAuth(section);
    if (!baseUrl || !auth) throw new Error(`${ADAPTER}: credentials or base_url missing`);

    const jiraKey = parseJiraKey(issueId);

    // Jira Cloud uses Atlassian Document Format (ADF) for comment bodies
    const body = {
      body: {
        version: 1,
        type: 'doc',
        content: [{ type: 'paragraph', content: [{ type: 'text', text: note }] }],
      },
    };

    const res = await fetch(`${baseUrl}/rest/api/3/issue/${jiraKey}/comment`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) throw new Error(`${ADAPTER}: appendNote failed for ${jiraKey} — HTTP ${res.status}`);
  },

  async updateStatus(issueId: string, status: IssueStatus, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const baseUrl = (section['base_url'] ?? '').replace(/\/$/, '');
    const auth = resolveAuth(section);
    if (!baseUrl || !auth) throw new Error(`${ADAPTER}: credentials or base_url missing`);

    const jiraKey = parseJiraKey(issueId);
    const jiraStatus = STATUS_TRANSITION_MAP[status] ?? status;

    const transitionId = await resolveTransitionId(baseUrl, auth, jiraKey, jiraStatus);
    if (!transitionId) {
      throw new Error(`${ADAPTER}: could not find transition "${jiraStatus}" for ${jiraKey}`);
    }

    const res = await fetch(`${baseUrl}/rest/api/3/issue/${jiraKey}/transitions`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ transition: { id: transitionId } }),
    });

    if (!res.ok) {
      throw new Error(`${ADAPTER}: updateStatus failed for ${jiraKey} — HTTP ${res.status}`);
    }
  },
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

interface JiraIssue {
  id: string;
  key: string;
  fields: {
    summary: string;
    description?: unknown;
    issuetype?: { name: string };
    priority?: { name: string };
    status?: { name: string };
    assignee?: { emailAddress: string; displayName: string } | null;
    labels?: string[];
  };
}

function jiraIssueToIssue(i: JiraIssue, baseUrl: string, staffId: string): Issue {
  const f = i.fields;
  const labelNames = f.labels ?? [];
  const taskType = inferTaskType(f.issuetype?.name ?? '', labelNames);

  // Jira description may be ADF (object) or plain text (string) depending on API version
  const desc = extractText(f.description)?.slice(0, 500) ?? f.summary;

  return {
    issueId: i.key,
    jobGuid: i.id,
    taskType,
    assignee: f.assignee?.emailAddress ?? staffId,
    startableTasks: [{ taskType, taskDescription: f.summary }],
    summary: f.summary,
    description: desc,
    zone: priorityToZone(f.priority?.name ?? ''),
    source: ADAPTER,
    sources: [ADAPTER],
    jobUrl: `${baseUrl}/browse/${i.key}`,
  };
}

/** Extract plain text from a Jira ADF document or plain string. */
function extractText(desc: unknown): string | null {
  if (!desc) return null;
  if (typeof desc === 'string') return desc;

  // ADF: walk the content tree extracting text nodes
  const texts: string[] = [];
  function walk(node: unknown): void {
    if (!node || typeof node !== 'object') return;
    const n = node as Record<string, unknown>;
    if (n['type'] === 'text' && typeof n['text'] === 'string') texts.push(n['text']);
    if (Array.isArray(n['content'])) n['content'].forEach(walk);
  }
  walk(desc);
  return texts.join(' ') || null;
}

function resolveAuth(section: Record<string, string>): string | null {
  const tokenEnv = section['token_env'] ?? 'JIRA_TOKEN';
  const emailEnv = section['email_env'] ?? 'JIRA_EMAIL';
  const token = process.env[tokenEnv] ?? '';
  const email = process.env[emailEnv] ?? '';
  if (!token || !email) return null;
  return Buffer.from(`${email}:${token}`).toString('base64');
}

function parseJiraKey(issueId: string): string {
  // issueId should already be the Jira key (e.g. "ENG-123") for Jira adapter
  return issueId;
}

async function resolveTransitionId(
  baseUrl: string,
  auth: string,
  issueKey: string,
  targetName: string,
): Promise<string | null> {
  const res = await fetch(`${baseUrl}/rest/api/3/issue/${issueKey}/transitions`, {
    headers: { Authorization: `Basic ${auth}`, Accept: 'application/json' },
  });
  if (!res.ok) return null;

  const json = (await res.json()) as { transitions?: Array<{ id: string; name: string }> };
  const t = (json.transitions ?? []).find(
    t => t.name.toLowerCase() === targetName.toLowerCase(),
  );
  return t?.id ?? null;
}

function priorityToZone(priority: string): number {
  switch (priority.toLowerCase()) {
    case 'highest':
    case 'critical': return 1;
    case 'high': return 2;
    case 'medium': return 3;
    default: return 0;
  }
}

function inferTaskType(issueType: string, labels: string[]): string {
  const combined = [issueType, ...labels].map(s => s.toLowerCase()).join(' ');
  if (combined.includes('bug')) return 'bugfix';
  if (combined.includes('feature') || combined.includes('story')) return 'feature';
  if (combined.includes('investigation') || combined.includes('spike')) return 'investigation';
  if (combined.includes('refactor') || combined.includes('tech debt')) return 'refactor';
  if (combined.includes('test')) return 'test';
  return 'feature';
}

const STATUS_TRANSITION_MAP: Record<string, string> = {
  claimed: 'In Progress',
  'in-design': 'In Progress',
  'in-progress': 'In Progress',
  'in-review': 'In Review',
  done: 'Done',
};

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
