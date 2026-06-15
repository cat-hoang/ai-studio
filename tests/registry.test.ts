import { describe, expect, test } from 'bun:test';
import { getAdapter, listAdapters } from '../adapters/issue-sources/index.ts';

describe('adapter registry', () => {
  test('resolves the github-issues adapter', () => {
    expect(getAdapter('github-issues')).not.toBeNull();
  });

  test('normalizes underscores to hyphens (config.yaml uses github_issues)', () => {
    expect(getAdapter('github_issues')).toBe(getAdapter('github-issues')!);
  });

  test('is case-insensitive', () => {
    expect(getAdapter('GitHub-Issues')).toBe(getAdapter('github-issues')!);
  });

  test('returns null for unknown and removed adapters', () => {
    expect(getAdapter('bitbucket')).toBeNull();
    // Only GitHub is supported — these adapters were removed.
    expect(getAdapter('linear')).toBeNull();
    expect(getAdapter('jira')).toBeNull();
    expect(getAdapter('file')).toBeNull();
    expect(getAdapter('ediprod')).toBeNull();
  });

  test('lists only the github-issues adapter', () => {
    expect(listAdapters()).toEqual(['github-issues']);
  });
});
