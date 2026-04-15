/**
 * Linear adapter.
 *
 * Config section (config.yaml / config.local.yaml):
 *
 *   issue_source:
 *     adapter: linear
 *     linear:
 *       team_key: ENG             # Linear team identifier key (required)
 *       state: Todo               # Issue state name to filter by (default: Todo)
 *       assignee: me              # "me" or a specific user email/id (default: me)
 *       api_key_env: LINEAR_API_KEY  # env var containing the API key (default: LINEAR_API_KEY)
 *       per_page: "50"            # max issues per request (default: 50)
 *
 * Uses the Linear GraphQL API: https://api.linear.app/graphql
 */
import type { IssueSourceAdapter, AdapterConfig, FetchResult, Issue, IssueStatus } from './types.ts';

const LINEAR_API = 'https://api.linear.app/graphql';
const ADAPTER = 'linear';

export const linearAdapter: IssueSourceAdapter = {
  async fetchStartable(config: AdapterConfig): Promise<FetchResult> {
    const { section, staffId } = config;
    const warnings: string[] = [];

    const teamKey = section['team_key'] ?? '';
    if (!teamKey) {
      return {
        warnings: [`${ADAPTER}: team_key not configured — set issue_source.linear.team_key`],
        issues: [],
      };
    }

    const token = resolveToken(section);
    if (!token) {
      const envName = section['api_key_env'] ?? 'LINEAR_API_KEY';
      return { warnings: [`${ADAPTER}: ${envName} environment variable is not set`], issues: [] };
    }

    const stateName = section['state'] ?? 'Todo';
    const assigneeMode = section['assignee'] ?? 'me';
    const first = parseInt(section['per_page'] ?? '50', 10);

    const assigneeFilter =
      assigneeMode === 'me'
        ? '{ assignee: { isMe: { eq: true } } }'
        : `{ assignee: { email: { eq: "${assigneeMode}" } } }`;

    const query = `
      query FetchStartable($teamKey: String!, $stateName: String!, $first: Int!) {
        issues(
          first: $first
          filter: {
            team: { key: { eq: $teamKey } }
            state: { name: { in: [$stateName] } }
            ${assigneeFilter !== '{ assignee: { isMe: { eq: true } } }' ? assigneeFilter : 'assignee: { isMe: { eq: true } }'}
          }
          orderBy: priority
        ) {
          nodes {
            id
            identifier
            title
            description
            priority
            url
            state { name type }
            team { key name }
            labels { nodes { name } }
            assignee { email displayName }
          }
        }
      }
    `;

    let nodes: LinearIssue[];
    try {
      const res = await fetch(LINEAR_API, {
        method: 'POST',
        headers: {
          Authorization: token,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ query, variables: { teamKey, stateName, first } }),
      });

      if (!res.ok) {
        return {
          warnings: [`${ADAPTER}: API error ${res.status} ${res.statusText}`],
          issues: [],
        };
      }

      const json = (await res.json()) as { data?: { issues?: { nodes: LinearIssue[] } }; errors?: unknown[] };

      if (json.errors?.length) {
        const msg = JSON.stringify(json.errors).slice(0, 300);
        return { warnings: [`${ADAPTER}: GraphQL errors — ${msg}`], issues: [] };
      }

      nodes = json.data?.issues?.nodes ?? [];
    } catch (err: unknown) {
      return { warnings: [`${ADAPTER}: network error — ${errMsg(err)}`], issues: [] };
    }

    const issues: Issue[] = nodes.map(n => linearIssueToIssue(n, staffId));
    return { warnings, issues };
  },

  async claim(issueId: string, config: AdapterConfig): Promise<void> {
    // Linear: transition issue to "In Progress" state
    const { section } = config;
    const token = resolveToken(section);
    if (!token) throw new Error(`${ADAPTER}: API key not set`);

    // Fetch the "In Progress" state id for this team
    const teamKey = section['team_key'] ?? '';
    const inProgressStateId = await resolveStateId(token, teamKey, 'In Progress');
    if (!inProgressStateId) {
      throw new Error(`${ADAPTER}: could not resolve "In Progress" state id for team ${teamKey}`);
    }

    await updateIssueState(token, issueId, inProgressStateId);
  },

  async appendNote(issueId: string, note: string, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const token = resolveToken(section);
    if (!token) throw new Error(`${ADAPTER}: API key not set`);

    const mutation = `
      mutation AddComment($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
          success
        }
      }
    `;

    const res = await fetch(LINEAR_API, {
      method: 'POST',
      headers: { Authorization: token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: mutation, variables: { issueId, body: note } }),
    });

    if (!res.ok) throw new Error(`${ADAPTER}: appendNote failed — HTTP ${res.status}`);
  },

  async updateStatus(issueId: string, status: IssueStatus, config: AdapterConfig): Promise<void> {
    const { section } = config;
    const token = resolveToken(section);
    if (!token) throw new Error(`${ADAPTER}: API key not set`);

    const teamKey = section['team_key'] ?? '';
    const linearStateName = STATUS_STATE_MAP[status] ?? status;
    const stateId = await resolveStateId(token, teamKey, linearStateName);
    if (!stateId) {
      throw new Error(`${ADAPTER}: could not resolve state "${linearStateName}" for team ${teamKey}`);
    }

    await updateIssueState(token, issueId, stateId);
  },
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

interface LinearIssue {
  id: string;
  identifier: string;
  title: string;
  description?: string | null;
  priority: number; // 0=no priority, 1=urgent, 2=high, 3=medium, 4=low
  url: string;
  state?: { name: string; type: string };
  team?: { key: string; name: string };
  labels?: { nodes: Array<{ name: string }> };
  assignee?: { email: string; displayName: string } | null;
}

function linearIssueToIssue(n: LinearIssue, staffId: string): Issue {
  const labelNames = n.labels?.nodes.map(l => l.name) ?? [];
  const taskType = inferTaskType(n.title, labelNames);

  return {
    jobNumber: n.identifier,
    jobGuid: n.id,
    taskSequence: '',
    taskType,
    assignee: n.assignee?.email ?? staffId,
    startableTasks: [{ taskSequence: '', taskType, taskDescription: n.title }],
    summary: n.title,
    description: (n.description ?? n.title).slice(0, 500),
    zone: priorityToZone(n.priority),
    source: ADAPTER,
    sources: [ADAPTER],
    jobUrl: n.url,
  };
}

function resolveToken(section: Record<string, string>): string {
  const envName = section['api_key_env'] ?? 'LINEAR_API_KEY';
  return process.env[envName] ?? '';
}

async function resolveStateId(token: string, teamKey: string, stateName: string): Promise<string | null> {
  const q = `
    query StatesForTeam($teamKey: String!) {
      teams(filter: { key: { eq: $teamKey } }) {
        nodes {
          states { nodes { id name } }
        }
      }
    }
  `;

  const res = await fetch(LINEAR_API, {
    method: 'POST',
    headers: { Authorization: token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q, variables: { teamKey } }),
  });

  if (!res.ok) return null;
  const json = (await res.json()) as { data?: { teams?: { nodes: Array<{ states: { nodes: Array<{ id: string; name: string }> } }> } } };
  const states = json.data?.teams?.nodes[0]?.states?.nodes ?? [];
  return states.find(s => s.name.toLowerCase() === stateName.toLowerCase())?.id ?? null;
}

async function updateIssueState(token: string, issueId: string, stateId: string): Promise<void> {
  const mutation = `
    mutation UpdateState($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: { stateId: $stateId }) {
        success
      }
    }
  `;

  const res = await fetch(LINEAR_API, {
    method: 'POST',
    headers: { Authorization: token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: mutation, variables: { issueId, stateId } }),
  });

  if (!res.ok) throw new Error(`${ADAPTER}: updateIssueState failed — HTTP ${res.status}`);
}

function priorityToZone(priority: number): number {
  switch (priority) {
    case 1: return 1; // urgent
    case 2: return 2; // high
    case 3: return 3; // medium
    default: return 0;
  }
}

function inferTaskType(title: string, labels: string[]): string {
  const combined = [title, ...labels].map(s => s.toLowerCase()).join(' ');
  if (combined.includes('bug') || combined.includes('fix')) return 'bugfix';
  if (combined.includes('feature') || combined.includes('enhancement')) return 'feature';
  if (combined.includes('investigation') || combined.includes('research')) return 'investigation';
  if (combined.includes('refactor')) return 'refactor';
  if (combined.includes('test')) return 'test';
  return 'feature';
}

const STATUS_STATE_MAP: Record<string, string> = {
  claimed: 'In Progress',
  'in-design': 'In Progress',
  'in-progress': 'In Progress',
  'in-review': 'In Review',
  done: 'Done',
};

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
