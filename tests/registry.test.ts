import { describe, expect, test } from 'bun:test';
import { getAdapter, listAdapters } from '../adapters/issue-sources/index.ts';

describe('adapter registry', () => {
  test('resolves canonical hyphenated names', () => {
    expect(getAdapter('github-issues')).not.toBeNull();
    expect(getAdapter('linear')).not.toBeNull();
    expect(getAdapter('jira')).not.toBeNull();
    expect(getAdapter('file')).not.toBeNull();
    expect(getAdapter('ediprod')).not.toBeNull();
  });

  test('normalizes underscores to hyphens (config.yaml uses github_issues)', () => {
    expect(getAdapter('github_issues')).toBe(getAdapter('github-issues')!);
  });

  test('is case-insensitive', () => {
    expect(getAdapter('GitHub-Issues')).toBe(getAdapter('github-issues')!);
  });

  test('returns null for unknown adapters', () => {
    expect(getAdapter('bitbucket')).toBeNull();
  });

  test('lists every registered adapter', () => {
    expect(listAdapters().sort()).toEqual(
      ['ediprod', 'file', 'github-issues', 'jira', 'linear'].sort(),
    );
  });
});
