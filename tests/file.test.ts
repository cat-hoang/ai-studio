import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileAdapter } from '../adapters/issue-sources/file.ts';
import type { AdapterConfig } from '../adapters/issue-sources/types.ts';

let tmpDir: string;

function cfg(file: string): AdapterConfig {
  return { adapterName: 'file', staffId: 'tester', section: { path: file } };
}

function writeFixture(name: string, contents: string): string {
  const p = path.join(tmpDir, name);
  fs.writeFileSync(p, contents, 'utf8');
  return p;
}

beforeAll(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'autotask-file-'));
});

afterAll(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe('file.fetchStartable', () => {
  test('warns when the file is missing', async () => {
    const res = await fileAdapter.fetchStartable(cfg(path.join(tmpDir, 'nope.json')));
    expect(res.issues).toEqual([]);
    expect(res.warnings[0]).toContain('not found');
  });

  test('warns on invalid JSON', async () => {
    const p = writeFixture('bad.json', '{ not json');
    const res = await fileAdapter.fetchStartable(cfg(p));
    expect(res.issues).toEqual([]);
    expect(res.warnings[0]).toContain('failed to parse');
  });

  test('warns when the top-level value is not an array', async () => {
    const p = writeFixture('obj.json', '{"issueId":"X"}');
    const res = await fileAdapter.fetchStartable(cfg(p));
    expect(res.issues).toEqual([]);
    expect(res.warnings[0]).toContain('expected a JSON array');
  });

  test('normalizes shorthand fields and infers taskType from the title', async () => {
    const p = writeFixture(
      'issues.json',
      JSON.stringify([
        { jobNumber: 'TASK-001', summary: 'Fix the crash', zone: 2 },
        { id: 'TASK-002', title: 'Add a feature', type: 'feature' },
        'not an object',
      ]),
    );

    const res = await fileAdapter.fetchStartable(cfg(p));

    expect(res.warnings).toEqual([]);
    expect(res.issues).toHaveLength(3);
    expect(res.issues[0]).toMatchObject({
      issueId: 'TASK-001',
      taskType: 'bugfix', // inferred from "Fix"
      zone: 2,
      source: 'file',
    });
    expect(res.issues[1]).toMatchObject({ issueId: 'TASK-002', taskType: 'feature' });
    // Non-object entries fall back to a safe placeholder.
    expect(res.issues[2].issueId).toBe('FILE-3');
  });
});

describe('file adapter remote ops are no-ops', () => {
  test('claim / appendNote / updateStatus resolve without error', async () => {
    const c = cfg(path.join(tmpDir, 'whatever.json'));
    await expect(fileAdapter.claim('X', c)).resolves.toBeUndefined();
    await expect(fileAdapter.appendNote('X', 'note', c)).resolves.toBeUndefined();
    await expect(fileAdapter.updateStatus('X', 'done', c)).resolves.toBeUndefined();
  });
});
