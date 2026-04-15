/**
 * Minimal YAML reader for adapter config sections.
 * Parses simple scalar key:value pairs from indented YAML blocks.
 * Does NOT support anchors, multi-line values, or complex types.
 */
import fs from 'fs';

/**
 * Read all direct-child key:value pairs under a nested YAML section path.
 *
 * @example
 * // config.yaml:
 * //   issue_source:
 * //     adapter: github-issues
 * //     github_issues:
 * //       repo: owner/repo
 * //       token_env: GITHUB_TOKEN
 * readYamlSectionValues('/path/config.yaml', 'issue_source', 'github_issues')
 * // → { repo: 'owner/repo', token_env: 'GITHUB_TOKEN' }
 */
export function readYamlSectionValues(
  filePath: string,
  ...sectionPath: string[]
): Record<string, string> {
  if (!fs.existsSync(filePath)) return {};

  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  return walkSectionPath(lines, sectionPath, 0, -1);
}

/**
 * Read direct-child key:value pairs from a merged set of YAML files.
 * Values in later files override earlier files (local overrides base).
 */
export function readMergedSectionValues(
  filePaths: string[],
  ...sectionPath: string[]
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const fp of filePaths) {
    Object.assign(result, readYamlSectionValues(fp, ...sectionPath));
  }
  return result;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function walkSectionPath(
  lines: string[],
  path: string[],
  startIdx: number,
  parentIndent: number,
): Record<string, string> {
  if (path.length === 0) {
    return extractSectionValues(lines, startIdx, parentIndent);
  }

  const [head, ...tail] = path;

  for (let i = startIdx; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const indent = leadingSpaces(line);

    // If we've come back up to parent indent without finding the section, stop.
    if (parentIndent >= 0 && indent <= parentIndent) break;

    // Match a section header: `  head:` with no (or empty) value
    const m = trimmed.match(/^([^:]+):\s*(.*)$/);
    if (!m) continue;

    const key = m[1].trim();
    const value = m[2].split('#')[0].trim().replace(/^["']|["']$/g, '');

    if (key === head && !value) {
      // Found the section header — recurse into it
      return walkSectionPath(lines, tail, i + 1, indent);
    }
  }

  return {};
}

function extractSectionValues(
  lines: string[],
  startIdx: number,
  sectionIndent: number,
): Record<string, string> {
  const result: Record<string, string> = {};
  let childIndent = -1;

  for (let i = startIdx; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const indent = leadingSpaces(line);

    // Left the section
    if (indent <= sectionIndent) break;

    // Determine the direct-child indent level from the first real line
    if (childIndent < 0) childIndent = indent;

    // Only process direct children (skip deeper nesting)
    if (indent !== childIndent) continue;

    const m = trimmed.match(/^([^:]+):\s*(.*)$/);
    if (!m) continue;

    let value = m[2].split('#')[0].trim();
    value = value.replace(/^["']|["']$/g, '');

    result[m[1].trim()] = value;
  }

  return result;
}

function leadingSpaces(line: string): number {
  return (line.match(/^(\s*)/) ?? ['', ''])[1].length;
}
