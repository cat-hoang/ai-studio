import { afterEach, describe, expect, test } from 'bun:test';
import { githubIssuesAdapter } from '../adapters/issue-sources/github-issues.ts';
import type { AdapterConfig } from '../adapters/issue-sources/types.ts';
import { installFetchMock, jsonResponse, type FetchMock } from './fetch-mock.ts';

// A raw token (ghp_ prefix) is used directly by resolveToken, so no env var needed.
function cfg(section: Record<string, string> = {}): AdapterConfig {
  return {
    adapterName: 'github-issues',
    staffId: 'tester',
    section: { repo: 'octo/repo', token_env: 'ghp_faketoken', ...section },
  };
}

let mock: FetchMock | undefined;
afterEach(() => mock?.stop());

describe('github-issues.fetchStartable', () => {
  test('warns when repo is not configured', async () => {
    const res = await githubIssuesAdapter.fetchStartable(cfg({ repo: '' }));
    expect(res.issues).toEqual([]);
    expect(res.warnings[0]).toContain('repo not configured');
  });

  test('warns when the token cannot be resolved', async () => {
    const prev = process.env['MISSING_TOKEN'];
    delete process.env['MISSING_TOKEN'];
    const res = await githubIssuesAdapter.fetchStartable(cfg({ token_env: 'MISSING_TOKEN' }));
    expect(res.issues).toEqual([]);
    expect(res.warnings[0]).toContain('MISSING_TOKEN');
    if (prev !== undefined) process.env['MISSING_TOKEN'] = prev;
  });

  test('filters out pull requests and maps labels to taskType/zone', async () => {
    mock = installFetchMock(() =>
      jsonResponse([
        { id: 1, number: 10, title: 'Fix login bug', labels: [{ name: 'bug' }, { name: 'p1' }] },
        { id: 2, number: 11, title: 'Add export', labels: [{ name: 'enhancement' }] },
        { id: 3, number: 12, title: 'A PR', pull_request: { url: 'x' }, labels: [] },
      ]),
    );

    const res = await githubIssuesAdapter.fetchStartable(cfg());

    expect(res.issues.map(i => i.issueId)).toEqual(['GH-10', 'GH-11']);
    expect(res.issues[0]).toMatchObject({ taskType: 'bugfix', zone: 2, source: 'github-issues' });
    expect(res.issues[1]).toMatchObject({ taskType: 'feature', zone: 0 });
  });

  test('surfaces API errors as warnings', async () => {
    mock = installFetchMock(() => jsonResponse({ message: 'Not Found' }, false, 404));
    const res = await githubIssuesAdapter.fetchStartable(cfg());
    expect(res.issues).toEqual([]);
    expect(res.warnings[0]).toContain('404');
  });
});

describe('github-issues status labels (regression: #1 label accumulation)', () => {
  test('claim adds in-progress and removes every other managed status label', async () => {
    mock = installFetchMock(() => jsonResponse({}));

    await githubIssuesAdapter.claim('GH-5', cfg());

    const posts = mock.callsOfMethod('POST');
    const deletes = mock.callsOfMethod('DELETE');

    // Exactly one POST, applying the new label.
    expect(posts).toHaveLength(1);
    expect(posts[0].url).toContain('/repos/octo/repo/issues/5/labels');
    expect(posts[0].body).toEqual({ labels: ['in-progress'] });

    // Every other status label is deleted; the new one is never deleted.
    const deletedLabels = deletes.map(d => decodeURIComponent(d.url.split('/labels/')[1]));
    expect(deletedLabels.sort()).toEqual(['claimed', 'done', 'in-design', 'in-review']);
    expect(deletedLabels).not.toContain('in-progress');
  });

  test('updateStatus(done) adds done and clears the prior status labels', async () => {
    mock = installFetchMock(() => jsonResponse({}));

    await githubIssuesAdapter.updateStatus('GH-7', 'done', cfg());

    const posts = mock!.callsOfMethod('POST');
    const deletes = mock!.callsOfMethod('DELETE');

    expect(posts[0].body).toEqual({ labels: ['done'] });
    const deletedLabels = deletes.map(d => decodeURIComponent(d.url.split('/labels/')[1]));
    expect(deletedLabels.sort()).toEqual(['claimed', 'in-design', 'in-progress', 'in-review']);
    expect(deletedLabels).not.toContain('done');
  });

  test('does not delete stale labels when the POST fails', async () => {
    mock = installFetchMock(call =>
      call.method === 'POST' ? jsonResponse({}, false, 500) : jsonResponse({}),
    );

    await expect(githubIssuesAdapter.updateStatus('GH-9', 'in-review', cfg())).rejects.toThrow(
      /updateStatus failed/,
    );
    expect(mock.callsOfMethod('DELETE')).toHaveLength(0);
  });
});
