import fs from 'fs';
import path from 'path';

/** Read a simple top-level YAML `key: value` pair. Last occurrence wins. */
export function readYamlKey(filePath: string, key: string): string | null {
  if (!fs.existsSync(filePath)) return null;
  const raw = fs.readFileSync(filePath, 'utf8');
  const lines = raw.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^([^:]+):\s*(.*)$/);
    if (!m) continue;
    if (m[1].trim() === key) {
      let value = m[2].trim();
      if (value.indexOf('#') >= 0) value = value.split('#', 1)[0].trim();
      value = value.replace(/^\"|\"$/g, '').replace(/^\'|\'$/g, '');
      return value;
    }
  }
  return null;
}

/** Read a YAML list value like ["A", "B"] or A, B */
export function readYamlList(filePath: string, key: string): string[] {
  const raw = readYamlKey(filePath, key);
  if (!raw) return [];
  const stripped = raw.trim();
  if (stripped.startsWith('[') && stripped.endsWith(']')) {
    const inner = stripped.slice(1, -1);
    return inner.split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
  }
  return stripped.split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
}

/** Resolve the Ratatosk repo root (parent of tools/) */
export function repoRoot(): string {
  return path.resolve(__dirname, '..');
}

/** Get the config file path (prefers config.local.yaml over config.yaml) */
export function configPaths(): { local: string; base: string; effective: string } {
  const root = repoRoot();
  const local = path.join(root, 'config.local.yaml');
  const base = path.join(root, 'config.yaml');
  const effective = fs.existsSync(local) ? local : base;
  return { local, base, effective };
}

/**
 * Read a config key with local override fallback.
 * Checks config.local.yaml first, then config.yaml.
 */
export function readConfigKey(key: string): string | null {
  const { local, base } = configPaths();
  return readYamlKey(local, key) ?? readYamlKey(base, key);
}

/**
 * Resolve the absolute path to the mcp-ediprod repository.
 * Priority: mcp_ediprod_root config > {git_source_root}/mcp-ediprod
 */
export function resolveMcpEdiprodRoot(): string {
  const explicit = readConfigKey('mcp_ediprod_root');
  if (explicit) return explicit;

  const gitRoot = readConfigKey('git_source_root');
  if (!gitRoot) {
    throw new Error('Cannot resolve mcp-ediprod path: neither mcp_ediprod_root nor git_source_root is configured.');
  }

  // git_source_root may be relative to repo root
  const resolved = path.isAbsolute(gitRoot) ? gitRoot : path.resolve(repoRoot(), gitRoot);
  return path.join(resolved, 'mcp-ediprod');
}
