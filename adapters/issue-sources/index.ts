/**
 * Adapter registry — maps adapter names to their implementations.
 *
 * Add new adapters here. The name must match the value used in
 * config.yaml under `issue_source.adapter`.
 */
import { githubIssuesAdapter } from './github-issues.ts';
import { linearAdapter } from './linear.ts';
import { jiraAdapter } from './jira.ts';
import { fileAdapter } from './file.ts';
import { ediprodAdapter } from './ediprod.ts';
import type { IssueSourceAdapter } from './types.ts';

export * from './types.ts';

const registry: Record<string, IssueSourceAdapter> = {
  'github-issues': githubIssuesAdapter,
  'linear': linearAdapter,
  'jira': jiraAdapter,
  'file': fileAdapter,
  'ediprod': ediprodAdapter,
};

/**
 * Look up an adapter by name (case-insensitive).
 * Returns null if the name is not registered.
 */
export function getAdapter(name: string): IssueSourceAdapter | null {
  const normalized = name.toLowerCase().replace(/_/g, '-');
  return registry[normalized] ?? null;
}

/** Return all registered adapter names. */
export function listAdapters(): string[] {
  return Object.keys(registry);
}
