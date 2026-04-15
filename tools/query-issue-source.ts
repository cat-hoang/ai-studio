/**
 * query-issue-source.ts
 *
 * Bun entry point for the generic issue-source adapter layer.
 * Called by get-ratatosk-startable-jobs.ps1 when `issue_source.adapter` is
 * configured to something other than "ediprod".
 *
 * Outputs a single JSON object to stdout in the canonical shape that the PS1
 * script (and dashboard) expect:
 *
 *   {
 *     "fetchedAt":     "<ISO-8601>",
 *     "warnings":      [...],
 *     "startableJobs": [...],   ← Issue[] mapped to the startableJobs schema
 *     "error":         ""
 *   }
 */
import path from 'path';
import fs from 'fs';
import { getAdapter, listAdapters } from '../adapters/issue-sources/index.ts';
import { readMergedSectionValues } from '../adapters/issue-sources/yaml-reader.ts';
import type { Issue } from '../adapters/issue-sources/types.ts';

// ---------------------------------------------------------------------------
// Config helpers
// ---------------------------------------------------------------------------

function repoRoot(): string {
  return path.resolve(import.meta.dirname, '..');
}

function configPaths(): { base: string; local: string } {
  const root = repoRoot();
  return {
    base: path.join(root, 'config.yaml'),
    local: path.join(root, 'config.local.yaml'),
  };
}

/** Read a flat top-level YAML key from merged config, last occurrence wins. */
function readKey(key: string): string {
  const { base, local } = configPaths();
  for (const fp of [local, base]) {
    if (!fs.existsSync(fp)) continue;
    const lines = fs.readFileSync(fp, 'utf8').split(/\r?\n/);
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line || line.startsWith('#')) continue;
      const m = line.match(/^([^:]+):\s*(.*)$/);
      if (!m || m[1].trim() !== key) continue;
      let v = m[2].split('#')[0].trim();
      v = v.replace(/^["']|["']$/g, '');
      if (v) return v;
    }
  }
  return '';
}

/** Read the `adapter:` key nested under `issue_source:` in merged config. */
function readIssueSourceAdapter(): string {
  const { base, local } = configPaths();
  const section = readMergedSectionValues([base, local], 'issue_source');
  return (section['adapter'] ?? '').trim();
}

/** Read adapter-specific sub-section, e.g. `issue_source.github_issues`. */
function readAdapterSection(adapterName: string): Record<string, string> {
  const { base, local } = configPaths();
  // Sub-section key uses underscores (github_issues, linear, jira, file, ediprod)
  const subKey = adapterName.replace(/-/g, '_');
  return readMergedSectionValues([base, local], 'issue_source', subKey);
}

// ---------------------------------------------------------------------------
// Output shape
// ---------------------------------------------------------------------------

interface OutputPayload {
  fetchedAt: string;
  warnings: string[];
  startableJobs: Issue[];
  error: string;
}

function errorOutput(message: string): OutputPayload {
  return {
    fetchedAt: new Date().toISOString(),
    warnings: [],
    startableJobs: [],
    error: message,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const adapterName = readIssueSourceAdapter();

  if (!adapterName) {
    process.stdout.write(
      JSON.stringify(
        errorOutput(
          'issue_source.adapter is not configured. ' +
          `Available adapters: ${listAdapters().join(', ')}`,
        ),
        null,
        2,
      ),
    );
    process.exit(1);
  }

  const adapter = getAdapter(adapterName);
  if (!adapter) {
    process.stdout.write(
      JSON.stringify(
        errorOutput(
          `Unknown adapter "${adapterName}". ` +
          `Available adapters: ${listAdapters().join(', ')}`,
        ),
        null,
        2,
      ),
    );
    process.exit(1);
  }

  const section = readAdapterSection(adapterName);
  // staffId: prefer new generic key, fall back to legacy staff_code
  const staffId = readKey('staff_id') || readKey('staff_code');

  let result;
  try {
    result = await adapter.fetchStartable({ adapterName, staffId, section });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    process.stdout.write(JSON.stringify(errorOutput(`${adapterName} adapter threw: ${msg}`), null, 2));
    process.exit(1);
  }

  const payload: OutputPayload = {
    fetchedAt: new Date().toISOString(),
    warnings: result.warnings,
    startableJobs: result.issues,
    error: '',
  };

  process.stdout.write(JSON.stringify(payload, null, 2));
  process.exit(0);
}

main().catch(err => {
  const msg = err instanceof Error ? err.message : String(err);
  process.stdout.write(JSON.stringify(errorOutput(`Unhandled error: ${msg}`), null, 2));
  process.exit(1);
});
