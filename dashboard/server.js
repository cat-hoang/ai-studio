const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { exec, execFile } = require('child_process');

// --- Config ---
const AUTOTASK_DIR = path.resolve(process.env.AUTOTASK_ROOT || path.join(__dirname, '..'));
const CONFIG_PATH = path.join(AUTOTASK_DIR, 'config.yaml');
const LOCAL_CONFIG_PATH = path.join(AUTOTASK_DIR, 'config.local.yaml');
const STATE_PATH = path.join(AUTOTASK_DIR, 'temp', 'state.json');
const DASHBOARD_DIR = path.join(AUTOTASK_DIR, 'dashboard');
const COMPLETED_STATUSES = new Set(['done', 'completed', 'complete', 'success', 'succeeded']);
const COMPLETED_PHASES = new Set(['done', 'completed', 'complete']);
const FAILED_STATUSES = new Set(['failed', 'error']);
const FAILED_PHASES = new Set(['failed', 'error']);
const DEFAULT_EMAIL_POLLING_INTERVAL_MS = 30000;
const DEFAULT_TEAMS_CHAT_POLLING_INTERVAL_MS = 10000;
const DEFAULT_STARTABLE_JOBS_POLLING_INTERVAL_MS = 30000;
const DEFAULT_STARTABLE_JOBS_FETCH_TIMEOUT_MS = 120000;
const DEFAULT_POLLER_STALE_GRACE_MS = 30000;
const DEFAULT_WORKER_STALE_GRACE_MS = 1800000;
const DEFAULT_MAX_CONCURRENT_WORKERS = 3;
const DEFAULT_AUTONOMY_MODE = 'suggestions-only';
const DEFAULT_AUTONOMY_MAX_WORKERS_PER_REPO_GROUP = 1;
const DEFAULT_AUTONOMY_MAX_LAUNCHES_PER_CYCLE = 1;
const ATTENTION_LIMIT = 10;

function readPort() {
  try {
    const raw = readConfigContent();
    const match = raw.match(/dashboard_port:\s*(\d+)/);
    return match ? parseInt(match[1], 10) : 3210;
  } catch {
    return 3210;
  }
}

function readConfigContent() {
  const chunks = [];
  for (const configPath of [CONFIG_PATH, LOCAL_CONFIG_PATH]) {
    try {
      chunks.push(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, ''));
    } catch {
      // ignore missing file
    }
  }

  return chunks.join('\n');
}

function readLocalConfigContent() {
  try {
    return fs.readFileSync(LOCAL_CONFIG_PATH, 'utf8').replace(/^\uFEFF/, '');
  } catch {
    return '';
  }
}

function writeLocalConfigContent(content) {
  fs.writeFileSync(LOCAL_CONFIG_PATH, String(content || '').replace(/^\uFEFF/, ''), 'utf8');
}

function escapeRegex(value) {
  return String(value || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function formatConfigScalar(value) {
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number' && Number.isFinite(value)) return String(Math.trunc(value));
  return `"${String(value || '').replace(/"/g, '\\"')}"`;
}

function upsertLocalConfigValue(key, value) {
  const raw = readLocalConfigContent();
  const lines = raw ? raw.split(/\r?\n/) : [];
  const matcher = new RegExp(`^(\\s*${escapeRegex(key)}:\\s*)([^#]*?)(\\s+#.*)?$`);
  let replaced = false;
  const updatedLines = lines.map(line => {
    const match = line.match(matcher);
    if (!match) return line;
    replaced = true;
    return `${match[1]}${formatConfigScalar(value)}${match[3] || ''}`.trimEnd();
  });

  if (!replaced) {
    if (updatedLines.length > 0 && updatedLines[updatedLines.length - 1].trim() !== '') {
      updatedLines.push('');
    }
    updatedLines.push(`${key}: ${formatConfigScalar(value)}`);
  }

  writeLocalConfigContent(updatedLines.join(os.EOL));
}

function readConfigTextValue(key) {
  const raw = readConfigContent();
  const matches = [...raw.matchAll(new RegExp(String.raw`${key}:\s*"?([^"\r\n]*)"?`, 'g'))];
  if (matches.length === 0) return '';
  return matches[matches.length - 1][1].trim().replace(/^['"]|['"]$/g, '');
}

function readConfigNumberValue(key, fallback) {
  const raw = readConfigContent();
  const matches = [...raw.matchAll(new RegExp(String.raw`${key}:\s*(\d+)`, 'g'))];
  return matches.length > 0 ? parseInt(matches[matches.length - 1][1], 10) : fallback;
}

function readConfigBooleanValue(key, fallback) {
  const raw = readConfigContent();
  const matches = [...raw.matchAll(new RegExp(String.raw`${key}:\s*(true|false)`, 'gi'))];
  if (matches.length === 0) return fallback;
  return String(matches[matches.length - 1][1]).toLowerCase() === 'true';
}

function readConfigListBlockValue(key) {
  const raw = readConfigContent();
  const lines = raw.split(/\r?\n/);
  const items = [];
  let inSection = false;
  let baseIndent = 0;

  for (const rawLine of lines) {
    const line = rawLine.trimEnd();
    if (!inSection) {
      const match = rawLine.match(new RegExp(`^(?<indent>\\s*)${key}:\\s*$`));
      if (match) {
        inSection = true;
        baseIndent = (match.groups && match.groups.indent ? match.groups.indent.length : 0);
      }
      continue;
    }

    if (!line.trim()) continue;
    const currentIndent = (rawLine.match(/^(\s*)/) || [''])[0].length;
    if (currentIndent <= baseIndent && /^[^#\s].*:\s*/.test(line)) break;

    const itemMatch = line.match(/^\s*-\s*(?<value>.+?)\s*$/);
    if (itemMatch && itemMatch.groups && itemMatch.groups.value) {
      items.push(itemMatch.groups.value.trim().replace(/^['"]|['"]$/g, ''));
    }
  }

  return uniqueStrings(items);
}

function readConfigMapListBlockValue(key) {
  const raw = readConfigContent();
  const lines = raw.split(/\r?\n/);
  const result = {};
  let inSection = false;
  let baseIndent = 0;
  let currentMapKey = '';

  for (const rawLine of lines) {
    const line = rawLine.trimEnd();
    if (!inSection) {
      const match = rawLine.match(new RegExp(`^(?<indent>\\s*)${key}:\\s*$`));
      if (match) {
        inSection = true;
        baseIndent = (match.groups && match.groups.indent ? match.groups.indent.length : 0);
      }
      continue;
    }

    if (!line.trim()) continue;
    const currentIndent = (rawLine.match(/^(\s*)/) || [''])[0].length;
    if (currentIndent <= baseIndent && /^[^#\s].*:\s*/.test(line)) break;

    const mapMatch = line.match(/^\s*(?<mapKey>[^:#]+):\s*$/);
    if (mapMatch && currentIndent > baseIndent) {
      currentMapKey = mapMatch.groups.mapKey.trim().replace(/^['"]|['"]$/g, '');
      if (!result[currentMapKey]) result[currentMapKey] = [];
      continue;
    }

    const itemMatch = line.match(/^\s*-\s*(?<value>.+?)\s*$/);
    if (currentMapKey && itemMatch && itemMatch.groups && itemMatch.groups.value) {
      result[currentMapKey].push(itemMatch.groups.value.trim().replace(/^['"]|['"]$/g, ''));
    }
  }

  for (const mapKey of Object.keys(result)) {
    result[mapKey] = uniqueStrings(result[mapKey]);
  }

  return result;
}

function runPowerShellFile(filePath, args, callback, options) {
  const powershellArgs = ['-NoProfile', '-File', filePath, ...(args || [])];
  execFile('pwsh', powershellArgs, {
    windowsHide: true,
    maxBuffer: 4 * 1024 * 1024,
    ...(options || {}),
  }, callback);
}

function createEmptyState() {
  return { workers: [], waitingQueue: [], completedJobs: [], failedJobs: [], autoStartPreferences: {} };
}

function readRawState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_PATH, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return createEmptyState();
  }
}

function writeState(state) {
  fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true });
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2), 'utf8');
}

function getStateEtag() {
  try {
    return '"' + fs.statSync(STATE_PATH).mtimeMs + '"';
  } catch {
    return '"0"';
  }
}

function asArray(value) {
  if (Array.isArray(value)) return value;
  if (value === null || value === undefined) return [];
  return [value];
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function firstNonEmptyString() {
  for (const value of arguments) {
    if (isNonEmptyString(value)) return value.trim();
  }
  return '';
}

function getTeamsChatTargetMode() {
  return firstNonEmptyString(readConfigTextValue('teams_chat_target_mode'), 'self').toLowerCase();
}

function isTeamsChatTargetConfigured(targetMode = getTeamsChatTargetMode()) {
  if (targetMode === 'self') return true;
  return isNonEmptyString(readConfigTextValue('teams_chat_target'));
}

function isTeamsChatConfigured() {
  return readConfigBooleanValue('teams_chat_enabled', false) && isTeamsChatTargetConfigured();
}

function shouldExposeTeamsPoller() {
  return readConfigBooleanValue('teams_chat_enabled', false)
    || readConfigBooleanValue('teams_chat_command_polling_enabled', false)
    || isNonEmptyString(readConfigTextValue('teams_chat_target'))
    || isNonEmptyString(readConfigTextValue('teams_chat_email'));
}

function getTeamsNotificationChannelLabel() {
  const webhookConfigured = isNonEmptyString(readConfigTextValue('teams_webhook_url'));
  const chatConfigured = isTeamsChatConfigured();
  if (chatConfigured && webhookConfigured) return 'chat + webhook';
  if (chatConfigured) return 'chat';
  if (webhookConfigured) return 'webhook';
  return 'not configured';
}

function uniqueStrings(values) {
  return [...new Set(values.filter(isNonEmptyString).map(value => value.trim()))];
}

function asNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseTimestamp(value) {
  if (!isNonEmptyString(value)) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function formatAgeMinutes(value) {
  if (!Number.isFinite(value) || value < 0) return '';
  const mins = Math.floor(value / 60000);
  const hrs = Math.floor(mins / 60);
  const remainingMins = mins % 60;
  if (hrs > 0) return `${hrs}h ${remainingMins}m`;
  return `${remainingMins}m`;
}

function getSequenceSortValue(value) {
  if (!isNonEmptyString(value)) return Number.MAX_SAFE_INTEGER;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : Number.MAX_SAFE_INTEGER;
}

function normalizeTaskSequence(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number') return String(value);
  return firstNonEmptyString(value);
}

function getTaskKey(issueId, taskSequence) {
  const resolvedIssueId = firstNonEmptyString(issueId);
  const resolvedTaskSequence = normalizeTaskSequence(taskSequence);
  return resolvedTaskSequence ? `${resolvedIssueId}::${resolvedTaskSequence}` : resolvedIssueId;
}

function getTaskKeyFromJob(job) {
  const id = firstNonEmptyString(job && job.issueId, job && job.jobNumber);
  return getTaskKey(id, job && job.taskSequence);
}

function compareJobs(left, right) {
  return firstNonEmptyString(left && (left.issueId || left.jobNumber)).localeCompare(firstNonEmptyString(right && (right.issueId || right.jobNumber)));
}

function compareJobsByCompletedAt(left, right) {
  const leftTime = firstNonEmptyString(left && left.completedAt, left && left.lastUpdated, '');
  const rightTime = firstNonEmptyString(right && right.completedAt, right && right.lastUpdated, '');
  if (leftTime !== rightTime) return leftTime > rightTime ? -1 : 1;
  return compareJobs(left, right);
}

function tokenizeText() {
  const tokens = [];
  for (const value of arguments) {
    if (!isNonEmptyString(value)) continue;
    const spacedValue = value.replace(/([a-z0-9])([A-Z])/g, '$1 $2');
    for (const part of spacedValue.split(/[^A-Za-z0-9]+/)) {
      const normalizedPart = String(part || '').trim().toLowerCase();
      if (normalizedPart.length >= 2 && !tokens.includes(normalizedPart)) {
        tokens.push(normalizedPart);
      }
    }
  }
  return tokens;
}

function getProductRepoKeywords(groupName, repos) {
  let keywords = tokenizeText(groupName, ...(repos || []));
  const normalizedGroupName = String(groupName || '').trim().toLowerCase();
  if (normalizedGroupName === 'rating') {
    keywords = uniqueStrings([...keywords, 'rating', 'rate', 'rates', 'glow', 'ucg', 'mapping']);
  } else if (normalizedGroupName === 'cargowise') {
    keywords = uniqueStrings([...keywords, 'cw', 'cargowise', 'customs', 'commodity', 'enterprise', 'masterfiles', 'database', 'schema', 'sql']);
  } else if (normalizedGroupName === 'ratesservice') {
    keywords = uniqueStrings([...keywords, 'ratesservice', 'service', 'native', 'api', 'quote']);
  }
  return keywords;
}

function readBatchingConfig() {
  const defaultRepos = readConfigListBlockValue('default_repos');
  // Prefer generic repo_groups; fall back to legacy product_repo_mapping for backward compat
  const repoGroups = readConfigMapListBlockValue('repo_groups');
  const productRepoMapping = Object.keys(repoGroups).length > 0
    ? repoGroups
    : readConfigMapListBlockValue('product_repo_mapping');
  return { defaultRepos, productRepoMapping };
}

function readAutonomyConfig() {
  const configuredMode = firstNonEmptyString(readConfigTextValue('autonomy_mode'), DEFAULT_AUTONOMY_MODE).toLowerCase();
  const mode = ['suggestions-only', 'auto'].includes(configuredMode)
    ? configuredMode
    : DEFAULT_AUTONOMY_MODE;

  return {
    mode,
    maxConcurrentWorkers: Math.max(1, readConfigNumberValue('max_concurrent_workers', DEFAULT_MAX_CONCURRENT_WORKERS)),
    maxWorkersPerRepoGroup: Math.max(1, readConfigNumberValue('autonomy_max_workers_per_repo_group', DEFAULT_AUTONOMY_MAX_WORKERS_PER_REPO_GROUP)),
  };
}

function getAutoStartPreferences(state) {
  const preferences = state && typeof state === 'object' ? state.autoStartPreferences : null;
  return preferences && typeof preferences === 'object' && !Array.isArray(preferences)
    ? preferences
    : {};
}

function isNeverAutoStart(state, issueId, taskSequence = '') {
  const preference = getAutoStartPreferences(state)[getTaskKey(issueId, taskSequence)];
  if (preference === true) return true;
  return !!(preference && typeof preference === 'object' && preference.neverAutoStart === true);
}

function normalizeUserInputRecord(record) {
  if (!record || typeof record !== 'object') return null;

  return {
    requestId: firstNonEmptyString(record.requestId),
    question: firstNonEmptyString(record.question),
    questionType: firstNonEmptyString(record.questionType, record.kind),
    severity: firstNonEmptyString(record.severity),
    answerMode: firstNonEmptyString(record.answerMode),
    state: firstNonEmptyString(record.state),
    resolutionState: firstNonEmptyString(record.resolutionState, record.state),
    requestedAt: firstNonEmptyString(record.requestedAt),
    respondedAt: firstNonEmptyString(record.respondedAt, record.receivedAt),
    consumedAt: firstNonEmptyString(record.consumedAt),
    response: firstNonEmptyString(record.response),
    source: firstNonEmptyString(record.source),
    responder: firstNonEmptyString(record.responder),
    messageId: firstNonEmptyString(record.messageId),
    options: asArray(record.options).filter(option => typeof option === 'string'),
  };
}

function normalizeTaskRecord(task) {
  if (!task || typeof task !== 'object') return null;
  const taskSequence = firstNonEmptyString(task.taskSequence, task.sequence);
  const taskType = firstNonEmptyString(task.taskType, task.type) || 'unknown';
  if (!taskSequence && taskType === 'unknown') return null;
  const taskDescription = firstNonEmptyString(task.taskDescription, task.description);
  const result = { taskSequence, taskType };
  if (taskDescription) result.taskDescription = taskDescription;
  return result;
}

function normalizeTaskRecords(tasks) {
  const seen = new Set();
  return asArray(tasks)
    .map(normalizeTaskRecord)
    .filter(Boolean)
    .filter(task => {
      const key = `${task.taskSequence}::${task.taskType}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function resolveAutotaskPath(value) {
  if (!isNonEmptyString(value)) return '';
  const trimmed = value.trim();
  return path.isAbsolute(trimmed) ? trimmed : path.join(AUTOTASK_DIR, trimmed);
}

function normalizeJob(job) {
  if (!job || typeof job !== 'object') return null;

  const summary = firstNonEmptyString(job.summary, job.title, job.description, job.name);
  const description = firstNonEmptyString(job.description, job.summary, job.title, job.name);
  const sources = uniqueStrings([
    ...asArray(job.sources),
    job.source,
  ]);
  const prUrls = uniqueStrings([
    ...asArray(job.prUrls),
    ...asArray(job.prs),
    job.prUrl,
  ]);
  const subAgentCount = Number.isFinite(Number(job.subAgentCount))
    ? Number(job.subAgentCount)
    : asArray(job.subAgents).length;

  return {
    ...job,
    issueId: firstNonEmptyString(job.issueId, job.jobNumber),
    jobNumber: firstNonEmptyString(job.issueId, job.jobNumber),
    jobGuid: firstNonEmptyString(job.jobGuid),
    taskSequence: firstNonEmptyString(job.taskSequence),
    taskType: firstNonEmptyString(job.taskType) || 'unknown',
    startableTasks: normalizeTaskRecords(job.startableTasks),
    summary,
    description,
    source: firstNonEmptyString(job.source, sources[0]),
    sources,
    queuedVia: firstNonEmptyString(job.queuedVia),
    queuedAt: firstNonEmptyString(job.queuedAt),
    startedAt: firstNonEmptyString(job.startedAt),
    completedAt: firstNonEmptyString(job.completedAt),
    zone: asNumber(job.zone, 0),
    status: firstNonEmptyString(job.status),
    phase: firstNonEmptyString(job.phase),
    activityStatus: firstNonEmptyString(job.activityStatus),
    activityMessage: firstNonEmptyString(job.activityMessage),
    error: firstNonEmptyString(job.error),
    finalReportSummary: firstNonEmptyString(job.finalReportSummary),
    finalReportPath: firstNonEmptyString(job.finalReportPath),
    finalReportedAt: firstNonEmptyString(job.finalReportedAt),
    lastHeartbeatAt: firstNonEmptyString(job.lastHeartbeatAt),
    cleanupBlockedAt: firstNonEmptyString(job.cleanupBlockedAt),
    cleanupBlockedReason: firstNonEmptyString(job.cleanupBlockedReason),
    workspacePath: firstNonEmptyString(job.workspacePath, job.workspace),
    repoGroup: firstNonEmptyString(job.repoGroup),
    repos: uniqueStrings(asArray(job.repos)),
    batchSelectionMode: firstNonEmptyString(job.batchSelectionMode),
    batchSelectionReason: firstNonEmptyString(job.batchSelectionReason),
    userInputRequest: normalizeUserInputRecord(job.userInputRequest),
    lastUserInput: normalizeUserInputRecord(job.lastUserInput),
    prUrls,
    prUrl: prUrls[0] || '',
    logs: asArray(job.logs).filter(log => typeof log === 'string'),
    subAgentCount,
    jobUrl: firstNonEmptyString(job.jobUrl),
  };
}

function mergeJobs(existing, incoming) {
  if (!existing) return incoming;

  const sources = uniqueStrings([...(existing.sources || []), ...(incoming.sources || []), existing.source, incoming.source]);
  const prUrls = uniqueStrings([...(existing.prUrls || []), ...(incoming.prUrls || [])]);
  const startableTasks = normalizeTaskRecords([...(existing.startableTasks || []), ...(incoming.startableTasks || [])]);

  return {
    ...existing,
    ...incoming,
    summary: firstNonEmptyString(incoming.summary, existing.summary),
    description: firstNonEmptyString(incoming.description, existing.description),
    taskType: firstNonEmptyString(incoming.taskType, existing.taskType) || 'unknown',
    startableTasks,
    jobGuid: firstNonEmptyString(incoming.jobGuid, existing.jobGuid),
    source: firstNonEmptyString(incoming.source, existing.source, sources[0]),
    sources,
    queuedVia: firstNonEmptyString(incoming.queuedVia, existing.queuedVia),
    queuedAt: firstNonEmptyString(incoming.queuedAt, existing.queuedAt),
    startedAt: firstNonEmptyString(incoming.startedAt, existing.startedAt),
    completedAt: firstNonEmptyString(incoming.completedAt, existing.completedAt),
    zone: asNumber(incoming.zone, asNumber(existing.zone, 0)),
    status: firstNonEmptyString(incoming.status, existing.status),
    phase: firstNonEmptyString(incoming.phase, existing.phase),
    activityStatus: firstNonEmptyString(incoming.activityStatus, existing.activityStatus),
    activityMessage: firstNonEmptyString(incoming.activityMessage, existing.activityMessage),
    error: firstNonEmptyString(incoming.error, existing.error),
    finalReportSummary: firstNonEmptyString(incoming.finalReportSummary, existing.finalReportSummary),
    finalReportPath: firstNonEmptyString(incoming.finalReportPath, existing.finalReportPath),
    finalReportedAt: firstNonEmptyString(incoming.finalReportedAt, existing.finalReportedAt),
    lastHeartbeatAt: firstNonEmptyString(incoming.lastHeartbeatAt, existing.lastHeartbeatAt),
    cleanupBlockedAt: firstNonEmptyString(incoming.cleanupBlockedAt, existing.cleanupBlockedAt),
    cleanupBlockedReason: firstNonEmptyString(incoming.cleanupBlockedReason, existing.cleanupBlockedReason),
    workspacePath: firstNonEmptyString(incoming.workspacePath, existing.workspacePath),
    repoGroup: firstNonEmptyString(incoming.repoGroup, existing.repoGroup),
    repos: uniqueStrings([...(existing.repos || []), ...(incoming.repos || [])]),
    batchSelectionMode: firstNonEmptyString(incoming.batchSelectionMode, existing.batchSelectionMode),
    batchSelectionReason: firstNonEmptyString(incoming.batchSelectionReason, existing.batchSelectionReason),
    taskSequence: firstNonEmptyString(incoming.taskSequence, existing.taskSequence),
    userInputRequest: incoming.userInputRequest || existing.userInputRequest || null,
    lastUserInput: incoming.lastUserInput || existing.lastUserInput || null,
    prUrls,
    prUrl: prUrls[0] || '',
    logs: [...(existing.logs || []), ...(incoming.logs || [])],
    subAgentCount: Math.max(existing.subAgentCount || 0, incoming.subAgentCount || 0),
    jobUrl: firstNonEmptyString(incoming.jobUrl, existing.jobUrl),
  };
}

function mergeJobCollection(items) {
  const jobs = new Map();
  asArray(items)
    .map(normalizeJob)
    .filter(Boolean)
    .forEach(job => {
      const taskKey = getTaskKeyFromJob(job);
      jobs.set(taskKey, mergeJobs(jobs.get(taskKey), job));
    });
  return [...jobs.values()].sort(compareJobs);
}

function expandStartableJobs(items) {
  const expanded = [];
  for (const item of asArray(items)) {
    const job = normalizeJob(item);
    if (!job) continue;

    const tasks = normalizeTaskRecords(job.startableTasks);
    if (tasks.length === 0) {
      expanded.push(job);
      continue;
    }

    for (const task of tasks) {
      const taskDesc = firstNonEmptyString(task && task.taskDescription);
      expanded.push(normalizeJob({
        ...job,
        taskSequence: firstNonEmptyString(task && task.taskSequence, job.taskSequence),
        taskType: firstNonEmptyString(task && task.taskType, job.taskType),
        description: taskDesc || job.description,
        startableTasks: [task],
      }));
    }
  }

  return mergeJobCollection(expanded);
}

function getWorkerBucket(job) {
  const status = (job.status || '').toLowerCase();
  const phase = (job.phase || '').toLowerCase();

  if (FAILED_STATUSES.has(status) || FAILED_PHASES.has(phase)) return 'failed';
  if (COMPLETED_STATUSES.has(status) || COMPLETED_PHASES.has(phase)) return 'completed';
  return 'workers';
}

function normalizeState(rawState) {
  const sourceState = rawState && typeof rawState === 'object' ? rawState : createEmptyState();
  const waitingQueue = new Map();
  const workers = new Map();
  const completedJobs = new Map();
  const failedJobs = new Map();

  function store(targetMap, job) {
    if (!job || !(job.issueId || job.jobNumber)) return;
    const taskKey = getTaskKeyFromJob(job);
    targetMap.set(taskKey, mergeJobs(targetMap.get(taskKey), job));
  }

  function routeToBucket(bucket, job) {
    if (!job || !(job.issueId || job.jobNumber)) return;

    if (bucket === 'completed') {
      const taskKey = getTaskKeyFromJob(job);
      workers.delete(taskKey);
      failedJobs.delete(taskKey);
      store(completedJobs, job);
      return;
    }

    if (bucket === 'failed') {
      const taskKey = getTaskKeyFromJob(job);
      workers.delete(taskKey);
      completedJobs.delete(taskKey);
      store(failedJobs, job);
      return;
    }

    const taskKey = getTaskKeyFromJob(job);
    completedJobs.delete(taskKey);
    failedJobs.delete(taskKey);
    store(workers, job);
  }

  asArray(sourceState.completedJobs)
    .map(normalizeJob)
    .filter(Boolean)
    .forEach(job => routeToBucket('completed', job));

  asArray(sourceState.failedJobs)
    .map(normalizeJob)
    .filter(Boolean)
    .forEach(job => routeToBucket('failed', job));

  asArray(sourceState.workers)
    .map(normalizeJob)
    .filter(Boolean)
    .forEach(job => routeToBucket(getWorkerBucket(job), job));

  asArray(sourceState.waitingQueue)
    .map(normalizeJob)
    .filter(Boolean)
    .forEach(job => store(waitingQueue, job));

  const occupiedJobs = new Set([
    ...workers.keys(),
    ...completedJobs.keys(),
    ...failedJobs.keys(),
  ]);

  return {
    ...sourceState,
    waitingQueue: [...waitingQueue.values()].filter(job => !occupiedJobs.has(getTaskKeyFromJob(job))).sort(compareJobs),
    workers: [...workers.values()].sort(compareJobs),
    completedJobs: [...completedJobs.values()].sort(compareJobsByCompletedAt),
    failedJobs: [...failedJobs.values()].sort(compareJobsByCompletedAt),
  };
}

function resolveJobRepoSelection(job, batchingConfig) {
  const explicitRepos = uniqueStrings(asArray(job && job.repos));
  if (explicitRepos.length > 0) {
    return {
      repoGroup: firstNonEmptyString(job && job.repoGroup, 'custom'),
      repos: explicitRepos,
      selectionMode: 'explicit-repos',
      reason: 'Using repos recorded on the job.',
    };
  }

  const explicitRepoGroup = firstNonEmptyString(
    job && job.repoGroup,
    job && job.product,
    job && job.productArea,
    job && job.batchRepoGroup
  );

  if (explicitRepoGroup) {
    for (const [groupName, repos] of Object.entries((batchingConfig && batchingConfig.productRepoMapping) || {})) {
      if (groupName.toLowerCase() === explicitRepoGroup.toLowerCase()) {
        return {
          repoGroup: groupName,
          repos: uniqueStrings(repos),
          selectionMode: 'explicit-group',
          reason: `Using configured repo group '${groupName}' recorded on the job.`,
        };
      }
    }
  }

  const jobTokens = tokenizeText(
    firstNonEmptyString(job && job.taskType),
    firstNonEmptyString(job && job.summary),
    firstNonEmptyString(job && job.description),
    firstNonEmptyString(job && job.source)
  );

  let bestMatch = { repoGroup: '', repos: [], score: 0, matchedTokens: [] };
  for (const [groupName, repos] of Object.entries((batchingConfig && batchingConfig.productRepoMapping) || {})) {
    if (!Array.isArray(repos) || repos.length === 0) continue;
    const keywords = getProductRepoKeywords(groupName, repos);
    const matchedTokens = keywords.filter(keyword => jobTokens.includes(keyword));
    if (matchedTokens.length > bestMatch.score) {
      bestMatch = {
        repoGroup: groupName,
        repos: uniqueStrings(repos),
        score: matchedTokens.length,
        matchedTokens: uniqueStrings(matchedTokens),
      };
    }
  }

  if (bestMatch.repoGroup && bestMatch.score >= 2) {
    return {
      repoGroup: bestMatch.repoGroup,
      repos: bestMatch.repos,
      selectionMode: 'heuristic-group',
      reason: `Inferred repo group '${bestMatch.repoGroup}' from task signals: ${bestMatch.matchedTokens.join(', ')}.`,
    };
  }

  const fallbackRepos = uniqueStrings(
    (batchingConfig && batchingConfig.defaultRepos && batchingConfig.defaultRepos.length > 0)
      ? batchingConfig.defaultRepos
      : Object.values((batchingConfig && batchingConfig.productRepoMapping) || {}).flat()
  );

  return {
    repoGroup: '',
    repos: fallbackRepos,
    selectionMode: fallbackRepos.length > 0 ? 'default-repos' : 'unresolved',
    reason: fallbackRepos.length > 0
      ? 'Falling back to default repos because no repo-group match was strong enough.'
      : 'No repo selection could be resolved from config.',
  };
}

function getWorkspaceCost(job, repoCount) {
  const relativeWorkspacePath = firstNonEmptyString(job && job.workspacePath, (job && (job.issueId || job.jobNumber)) ? path.join('workspaces', job.issueId || job.jobNumber) : '');
  const resolvedWorkspacePath = resolveAutotaskPath(relativeWorkspacePath);
  if (resolvedWorkspacePath && fs.existsSync(resolvedWorkspacePath)) {
    return { label: 'reuse workspace', score: 18, path: relativeWorkspacePath };
  }

  if (repoCount <= 1) return { label: 'light workspace', score: 10, path: relativeWorkspacePath };
  if (repoCount <= 2) return { label: 'medium workspace', score: 6, path: relativeWorkspacePath };
  return { label: 'heavy workspace', score: 0, path: relativeWorkspacePath };
}

function buildRepoGroupCounts(jobs, batchingConfig) {
  const counts = new Map();
  for (const job of asArray(jobs)) {
    const selection = resolveJobRepoSelection(job, batchingConfig);
    const repoKey = firstNonEmptyString(selection.repoGroup, selection.repos.join('|'), firstNonEmptyString(job && (job.issueId || job.jobNumber)));
    counts.set(repoKey, (counts.get(repoKey) || 0) + 1);
  }
  return counts;
}

function buildBatchingHints(job, batchingConfig, repoGroupCounts) {
  const selection = resolveJobRepoSelection(job, batchingConfig);
  const repoKey = firstNonEmptyString(selection.repoGroup, selection.repos.join('|'), firstNonEmptyString(job && (job.issueId || job.jobNumber)));
  const overlapCount = Math.max(0, (repoGroupCounts.get(repoKey) || 0) - 1);
  const repoCount = selection.repos.length;
  const workspaceCost = getWorkspaceCost(job, repoCount);
  const zone = asNumber(job && job.zone, 0);
  const retryCount = asNumber(job && job.retryCount, 0);
  const prCount = asArray(job && job.prUrls).length;
  const queuedVia = firstNonEmptyString(job && job.queuedVia).toLowerCase();

  let completionValue = zone > 0 ? Math.max(8, 28 - (zone * 5)) : 12;
  completionValue += Math.min(12, retryCount * 6);
  completionValue += Math.min(14, prCount * 7);
  if (queuedVia.includes('dashboard') || queuedVia.includes('manual')) completionValue += 8;
  if (queuedVia.includes('email')) completionValue += 4;

  const overlapBonus = Math.min(15, overlapCount * 5);
  const repoPenalty = Math.max(0, repoCount - 2) * 4;
  const launchScore = completionValue + workspaceCost.score + overlapBonus - repoPenalty;
  const reasons = [];
  if (selection.repoGroup) reasons.push(`shared ${selection.repoGroup} repo lane`);
  if (overlapCount > 0) reasons.push(`${overlapCount} related queued/startable job${overlapCount === 1 ? '' : 's'}`);
  reasons.push(workspaceCost.label);
  if (prCount > 0) reasons.push(`${prCount} existing PR${prCount === 1 ? '' : 's'}`);
  if (retryCount > 0) reasons.push(`retry #${retryCount}`);
  if (zone > 0) reasons.push(`zone ${zone}`);

  return {
    repoGroup: selection.repoGroup,
    repos: selection.repos,
    selectionMode: selection.selectionMode,
    selectionReason: selection.reason,
    overlapCount,
    workspaceLabel: workspaceCost.label,
    completionValue,
    launchScore,
    reasons,
  };
}

function compareJobsByBatching(left, right) {
  const leftScore = asNumber(left && left.batching && left.batching.launchScore, Number.MIN_SAFE_INTEGER);
  const rightScore = asNumber(right && right.batching && right.batching.launchScore, Number.MIN_SAFE_INTEGER);
  if (leftScore !== rightScore) return rightScore - leftScore;
  return compareJobs(left, right);
}

function applyBatchingHints(jobs, batchingConfig, repoGroupCounts) {
  return asArray(jobs)
    .map(job => {
      const batching = buildBatchingHints(job, batchingConfig, repoGroupCounts);
      return {
        ...job,
        repoGroup: firstNonEmptyString(job && job.repoGroup, batching.repoGroup),
        repos: uniqueStrings([...(job && job.repos ? asArray(job.repos) : []), ...batching.repos]),
        batchSelectionMode: firstNonEmptyString(job && job.batchSelectionMode, batching.selectionMode),
        batchSelectionReason: firstNonEmptyString(job && job.batchSelectionReason, batching.selectionReason),
        batching,
      };
    })
    .sort(compareJobsByBatching);
}

let startableJobsCache = [];
let startableJobsWarnings = [];
let lastStartablePollAt = '';
let lastStartablePollError = '';
let startablePollerLog = { status: 'skipped', jobCount: 0, message: 'Not polled yet', lastPollAt: '' };
let startableJobsPollTimer = null;
let startableJobsPollInFlight = false;
let teamsCommandPollerLog = { status: 'skipped', jobCount: 0, message: 'Not polled yet', lastPollAt: '' };
let teamsCommandPollTimer = null;
let teamsCommandPollInFlight = false;
const terminalNotificationInFlight = new Set();
let autoLaunchStatus = {
  mode: DEFAULT_AUTONOMY_MODE,
  state: 'idle',
  detail: 'Autonomy not evaluated yet.',
  lastDecisionAt: '',
  lastActionAt: '',
  lastJobNumber: '',
};
const emailPollStatus = createPollerStatus('email', DEFAULT_EMAIL_POLLING_INTERVAL_MS);
const teamsCommandPollStatus = createPollerStatus('teams', DEFAULT_TEAMS_CHAT_POLLING_INTERVAL_MS);
const startablePollStatus = createPollerStatus('startable', DEFAULT_STARTABLE_JOBS_POLLING_INTERVAL_MS);

function getTrackedTaskKeys(state) {
  return new Set([
    ...asArray(state.waitingQueue),
    ...asArray(state.workers),
    ...asArray(state.completedJobs),
    ...asArray(state.failedJobs),
  ]
    .map(job => getTaskKeyFromJob(job))
    .filter(Boolean));
}

function getWorkerStaleGraceMs() {
  return readConfigNumberValue('worker_stale_grace_ms', DEFAULT_WORKER_STALE_GRACE_MS);
}

function getUserInputAttentionSeverity(request) {
  const severity = firstNonEmptyString(request && request.severity).toLowerCase();
  if (severity === 'critical') return 'error';
  if (severity === 'high') return 'warning';
  return 'info';
}

function describeUserInputRequest(request) {
  const taxonomy = [
    firstNonEmptyString(request && request.questionType),
    firstNonEmptyString(request && request.severity),
  ].filter(Boolean).join(' / ');

  const question = firstNonEmptyString(request && request.question, 'Worker is blocked waiting for an answer.');
  return taxonomy ? `${taxonomy}: ${question}` : question;
}

function getPausedResumeCandidates(state) {
  return asArray(state.workers).filter(job => {
    const status = firstNonEmptyString(job && job.status).toLowerCase();
    const activityStatus = firstNonEmptyString(job && job.activityStatus).toLowerCase();
    const hasPendingInput = !!(job && job.userInputRequest && job.userInputRequest.state === 'pending');
    return !hasPendingInput && (status === 'paused' || activityStatus === 'paused');
  });
}

function decorateJob(job, bucketName) {
  const lastHeartbeatAt = firstNonEmptyString(job && job.lastHeartbeatAt, job && job.lastUpdated, job && job.startedAt);
  const cleanupBlockedReason = firstNonEmptyString(
    job && job.cleanupBlockedReason,
    /cleanup blocked/i.test(firstNonEmptyString(job && job.activityMessage)) ? firstNonEmptyString(job && job.activityMessage) : ''
  );
  const heartbeat = parseTimestamp(lastHeartbeatAt);
  const staleGraceMs = getWorkerStaleGraceMs();
  const ageMs = heartbeat ? Date.now() - heartbeat.getTime() : Number.NaN;
  const status = firstNonEmptyString(job && job.status).toLowerCase();
  const activityStatus = firstNonEmptyString(job && job.activityStatus).toLowerCase();
  const isPauseLike = status === 'paused' || activityStatus === 'awaiting-user-input';
  const isStale = bucketName === 'workers' && !isPauseLike && Number.isFinite(ageMs) && ageMs > staleGraceMs;

  return {
    ...job,
    bucketName,
    lastHeartbeatAt,
    cleanupBlockedReason,
    cleanupBlockedAt: firstNonEmptyString(job && job.cleanupBlockedAt),
    staleAgeMs: Number.isFinite(ageMs) ? ageMs : null,
    isStale,
  };
}

function buildAttentionItems(state) {
  const items = [];
  const severityRank = { error: 0, warning: 1, info: 2 };

  for (const job of asArray(state.workers)) {
    if (job.isStale) {
      items.push({
        severity: 'warning',
        kind: 'stale-worker',
        jobNumber: job.jobNumber,
        jobUrl: job.jobUrl,
        title: `${job.jobNumber} looks stale`,
        detail: `No heartbeat for ${formatAgeMinutes(job.staleAgeMs)} while ${firstNonEmptyString(job.activityStatus, job.phase, job.status, 'running')}.`,
        actionLabel: 'Open tab',
      });
    }

    if (job.userInputRequest && job.userInputRequest.state === 'pending') {
      items.push({
        severity: getUserInputAttentionSeverity(job.userInputRequest),
        kind: 'awaiting-input',
        jobNumber: job.jobNumber,
        jobUrl: job.jobUrl,
        title: `${job.jobNumber} is waiting for input`,
        detail: describeUserInputRequest(job.userInputRequest),
        actionLabel: 'Reply',
      });
    }

    if (firstNonEmptyString(job.activityStatus).toLowerCase() === 'blocked') {
      items.push({
        severity: 'warning',
        kind: 'blocked-worker',
        jobNumber: job.jobNumber,
        jobUrl: job.jobUrl,
        title: `${job.jobNumber} is blocked`,
        detail: firstNonEmptyString(job.activityMessage, 'Worker reported a blocked state.'),
        actionLabel: 'Inspect',
      });
    }

    const status = firstNonEmptyString(job.status).toLowerCase();
    const activityStatus = firstNonEmptyString(job.activityStatus).toLowerCase();
    if ((status === 'paused' || activityStatus === 'paused') && !(job.userInputRequest && job.userInputRequest.state === 'pending')) {
      items.push({
        severity: 'info',
        kind: 'resume-candidate',
        jobNumber: job.jobNumber,
        jobUrl: job.jobUrl,
        title: `${job.jobNumber} is ready to resume`,
        detail: firstNonEmptyString(job.activityMessage, 'Prefer resuming paused work before opening a fresh workspace.'),
        actionLabel: 'Inspect',
      });
    }
  }

  for (const job of [...asArray(state.completedJobs), ...asArray(state.failedJobs)]) {
    if (firstNonEmptyString(job.cleanupBlockedReason)) {
      items.push({
        severity: 'error',
        kind: 'cleanup-blocked',
        jobNumber: job.jobNumber,
        jobUrl: job.jobUrl,
        title: `${job.jobNumber} cleanup is blocked`,
        detail: firstNonEmptyString(job.cleanupBlockedReason),
        actionLabel: 'Retry cleanup',
      });
    }

    if (job.bucketName === 'failedJobs' && !firstNonEmptyString(job.finalReportedAt)) {
      items.push({
        severity: 'warning',
        kind: 'notification-pending',
        jobNumber: job.jobNumber,
        jobUrl: job.jobUrl,
        title: `${job.jobNumber} still needs failure reporting`,
        detail: 'Final failure notification has not been confirmed yet.',
        actionLabel: 'Inspect',
      });
    }
  }

  return items
    .sort((left, right) => (severityRank[left.severity] ?? 99) - (severityRank[right.severity] ?? 99) || left.title.localeCompare(right.title))
    .slice(0, ATTENTION_LIMIT);
}

function buildHealthChecks(state, attentionItems) {
  const autonomy = readAutonomyConfig();
  const workerCli = firstNonEmptyString(readConfigTextValue('worker_cli'), 'claude');
  const teamsWebhookConfigured = isNonEmptyString(readConfigTextValue('teams_webhook_url'));
  const teamsChatConfigured = isTeamsChatConfigured();
  const teamsConfigured = teamsWebhookConfigured || teamsChatConfigured;
  const emailConfigured = isNonEmptyString(readConfigTextValue('smtp_from')) && isNonEmptyString(readConfigTextValue('smtp_to'));
  const staleWorkers = asArray(state.workers).filter(job => job.isStale).length;
  const cleanupBlocked = [...asArray(state.completedJobs), ...asArray(state.failedJobs)].filter(job => firstNonEmptyString(job.cleanupBlockedReason)).length;
  const pausedResumeCandidates = getPausedResumeCandidates(state).length;

  return {
    status: staleWorkers > 0 || cleanupBlocked > 0 ? 'degraded' : 'ready',
    workerCli,
    autonomyMode: autonomy.mode,
    maxConcurrentWorkers: autonomy.maxConcurrentWorkers,
    autoLaunch: {
      state: autoLaunchStatus.state,
      detail: autoLaunchStatus.detail,
      lastDecisionAt: autoLaunchStatus.lastDecisionAt,
      lastActionAt: autoLaunchStatus.lastActionAt,
      lastJobNumber: autoLaunchStatus.lastJobNumber,
    },
    notifications: {
      teamsConfigured,
      teamsWebhookConfigured,
      teamsChatConfigured,
      teamsChannel: getTeamsNotificationChannelLabel(),
      emailConfigured,
    },
    staleWorkers,
    cleanupBlocked,
    pausedResumeCandidates,
    neverAutoStartCount: Object.values(getAutoStartPreferences(state)).filter(value => value && typeof value === 'object' && value.neverAutoStart === true).length,
    attentionCount: attentionItems.length,
  };
}

function buildPersistedState(sourceState, normalizedState) {
  return {
    ...sourceState,
    waitingQueue: normalizedState.waitingQueue,
    workers: normalizedState.workers,
    completedJobs: normalizedState.completedJobs,
    failedJobs: normalizedState.failedJobs,
  };
}

function persistNormalizedBucketsIfNeeded(sourceState, normalizedState) {
  const persistedState = buildPersistedState(sourceState, normalizedState);
  const bucketNames = ['waitingQueue', 'workers', 'completedJobs', 'failedJobs'];
  const changed = bucketNames.some(name => JSON.stringify(asArray(sourceState[name])) !== JSON.stringify(asArray(persistedState[name])));
  if (changed) {
    // Re-read from disk and re-normalize to avoid overwriting concurrent changes
    // from external writers (e.g. PowerShell heartbeats, finalize scripts).
    const freshState = readRawState();
    const freshPersisted = buildPersistedState(freshState, normalizeState(freshState));
    const stillChanged = bucketNames.some(name => JSON.stringify(asArray(freshState[name])) !== JSON.stringify(asArray(freshPersisted[name])));
    if (stillChanged) {
      writeState(freshPersisted);
    }
  }
  return persistedState;
}

function getTerminalSummary(job) {
  return firstNonEmptyString(
    job.finalReportSummary,
    job.error,
    job.activityMessage,
    job.summary,
    job.description,
    'Worker reached terminal state without running the Autotask finalizer.'
  );
}

function markJobAsReported(jobNumber, taskSequence, bucketName, summary, timestamp, errorMessage) {
  const state = readRawState();
  const bucket = asArray(state[bucketName]);
  const targetKey = getTaskKey(jobNumber, taskSequence);
  const targetJob = bucket.find(job => getTaskKeyFromJob(job) === targetKey);
  if (!targetJob) return;

  targetJob.finalReportedAt = timestamp;
  targetJob.finalReportSummary = firstNonEmptyString(targetJob.finalReportSummary, summary);
  if (bucketName === 'failedJobs' && !firstNonEmptyString(targetJob.error)) {
    targetJob.error = firstNonEmptyString(errorMessage, summary);
  }

  writeState(state);
}

function ensureTerminalNotifications(state) {
  const failureScript = path.join(AUTOTASK_DIR, 'tools', 'send-task-failure-notifications.ps1');
  if (!fs.existsSync(failureScript)) return;

  for (const job of asArray(state.failedJobs)) {
    const jobNumber = firstNonEmptyString(job && job.jobNumber);
    const taskSequence = firstNonEmptyString(job && job.taskSequence);
    const taskKey = getTaskKey(jobNumber, taskSequence);
    if (!jobNumber || firstNonEmptyString(job && job.finalReportedAt) || terminalNotificationInFlight.has(taskKey)) {
      continue;
    }

    terminalNotificationInFlight.add(taskKey);
    const timestamp = new Date().toISOString();
    const summary = getTerminalSummary(job);
    const errorMessage = firstNonEmptyString(job && job.error, job && job.activityMessage, summary);
    const args = [
      '-JobNumber', jobNumber,
      '-JobGuid', firstNonEmptyString(job && job.jobGuid),
      '-TaskSequence', firstNonEmptyString(job && job.taskSequence),
      '-TaskType', firstNonEmptyString(job && job.taskType, 'unknown'),
      '-ErrorMessage', errorMessage,
      '-Zone', String(asNumber(job && job.zone, 0)),
      '-Logs', asArray(job && job.logs).filter(isNonEmptyString).join(os.EOL),
      '-Timestamp', timestamp,
    ];

    runPowerShellFile(failureScript, args, (err, stdout, stderr) => {
      terminalNotificationInFlight.delete(taskKey);
      if (err) {
        console.error('[terminal-notify] Failed to send failure notification for ' + jobNumber + (taskSequence ? (' task ' + taskSequence) : '') + ': ' + err.message);
        if (stderr && stderr.trim()) {
          console.error('[terminal-notify] Stderr: ' + stderr.trim());
        }
        return;
      }

      markJobAsReported(jobNumber, taskSequence, 'failedJobs', summary, timestamp, errorMessage);
    });
  }
}

function buildDashboardState(rawState) {
  const sourceState = rawState && typeof rawState === 'object' ? rawState : createEmptyState();
  const normalizedState = normalizeState(sourceState);
  const state = persistNormalizedBucketsIfNeeded(sourceState, normalizedState);
  ensureTerminalNotifications(state);
  const decoratedState = {
    ...state,
    waitingQueue: asArray(state.waitingQueue).map(job => decorateJob(job, 'waitingQueue')),
    workers: asArray(state.workers).map(job => decorateJob(job, 'workers')),
    completedJobs: asArray(state.completedJobs).map(job => decorateJob(job, 'completedJobs')),
    failedJobs: asArray(state.failedJobs).map(job => decorateJob(job, 'failedJobs')),
  };
  const attentionItems = buildAttentionItems(decoratedState);
  const healthChecks = buildHealthChecks(decoratedState, attentionItems);
  const trackedJobs = getTrackedTaskKeys(decoratedState);
  const batchingConfig = readBatchingConfig();
  const startableJobs = expandStartableJobs(startableJobsCache)
    .filter(job => !trackedJobs.has(getTaskKeyFromJob(job)));
  const withAutoStartPreference = startableJobs.map(job => ({
    ...job,
    neverAutoStart: isNeverAutoStart(state, firstNonEmptyString(job && job.jobNumber), firstNonEmptyString(job && job.taskSequence)),
  }));
  const repoGroupCounts = buildRepoGroupCounts([
    ...decoratedState.waitingQueue,
    ...withAutoStartPreference,
  ], batchingConfig);
  const waitingQueue = applyBatchingHints(decoratedState.waitingQueue, batchingConfig, repoGroupCounts);
  const startableJobsWithBatching = applyBatchingHints(withAutoStartPreference, batchingConfig, repoGroupCounts);

  return {
    ...decoratedState,
    waitingQueue,
    startableJobs: startableJobsWithBatching,
    startableJobsStatus: {
      lastPolledAt: lastStartablePollAt,
      lastError: lastStartablePollError,
      warnings: startableJobsWarnings,
      inFlight: startableJobsPollInFlight,
      pollerLog: startablePollerLog,
      poller: getPollerStatusSnapshot(startablePollStatus),
      autonomy: {
        mode: autoLaunchStatus.mode,
        state: autoLaunchStatus.state,
        detail: autoLaunchStatus.detail,
        lastDecisionAt: autoLaunchStatus.lastDecisionAt,
        lastActionAt: autoLaunchStatus.lastActionAt,
        lastJobNumber: autoLaunchStatus.lastJobNumber,
      },
      neverAutoStartCount: startableJobsWithBatching.filter(job => job.neverAutoStart).length,
    },
    pollers: {
      email: getPollerStatusSnapshot(emailPollStatus),
      ...(shouldExposeTeamsPoller() ? { teams: { ...getPollerStatusSnapshot(teamsCommandPollStatus), pollerLog: teamsCommandPollerLog } } : {}),
      startable: { ...getPollerStatusSnapshot(startablePollStatus), pollerLog: startablePollerLog },
    },
    attentionItems,
    healthChecks,
  };
}

function getStateEntry(state, jobNumber, taskSequence = '') {
  for (const bucketName of ['workers', 'completedJobs', 'failedJobs', 'waitingQueue']) {
    const bucket = asArray(state[bucketName]);
    const job = bucket.find(item => getTaskKey(firstNonEmptyString(item && item.jobNumber), firstNonEmptyString(item && item.taskSequence)) === getTaskKey(jobNumber, taskSequence));
    if (job) {
      return { bucketName, job };
    }
  }
  return null;
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => { data += chunk; });
    req.on('end', () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (e) {
        reject(new Error('Invalid JSON body'));
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store, no-cache, must-revalidate',
    Pragma: 'no-cache',
    Expires: '0',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
  res.end(body);
}

function sendError(res, statusCode, message) {
  sendJson(res, statusCode, { error: message });
}

function createPollerStatus(name, intervalMs) {
  return {
    name,
    intervalMs,
    running: false,
    timerActive: false,
    inFlight: false,
    lastAttemptAt: '',
    lastSuccessAt: '',
    lastError: '',
    disabledReason: '',
    warnings: [],
    consecutiveFailures: 0,
    reviveCount: 0,
  };
}

function setAutoLaunchStatus(update) {
  autoLaunchStatus = {
    ...autoLaunchStatus,
    ...(update || {}),
    mode: firstNonEmptyString(update && update.mode, autoLaunchStatus.mode, DEFAULT_AUTONOMY_MODE),
    lastDecisionAt: firstNonEmptyString(update && update.lastDecisionAt, new Date().toISOString()),
    detail: firstNonEmptyString(update && update.detail, autoLaunchStatus.detail),
    state: firstNonEmptyString(update && update.state, autoLaunchStatus.state, 'idle'),
    lastActionAt: firstNonEmptyString(update && update.lastActionAt, autoLaunchStatus.lastActionAt),
    lastJobNumber: firstNonEmptyString(update && update.lastJobNumber, autoLaunchStatus.lastJobNumber),
  };
}

function enqueueJobRecord(state, job, queuedVia) {
  const queuedJob = normalizeJob({
    ...job,
    jobNumber: firstNonEmptyString(job && job.jobNumber),
    queuedAt: new Date().toISOString(),
    queuedVia: firstNonEmptyString(queuedVia, 'auto-launcher'),
    source: firstNonEmptyString(job && job.source, 'startable-poller'),
  });
  if (!queuedJob) return null;

  if (!state.waitingQueue) state.waitingQueue = [];
  const queuedTaskKey = getTaskKeyFromJob(queuedJob);
  state.waitingQueue = asArray(state.waitingQueue).filter(item => getTaskKey(firstNonEmptyString(item && item.jobNumber), firstNonEmptyString(item && item.taskSequence)) !== queuedTaskKey);
  state.waitingQueue.push({
    jobNumber: queuedJob.jobNumber,
    jobGuid: queuedJob.jobGuid,
    taskSequence: queuedJob.taskSequence,
    taskType: queuedJob.taskType,
    summary: queuedJob.summary,
    description: queuedJob.description,
    zone: queuedJob.zone,
    source: queuedJob.source,
    sources: queuedJob.sources,
    repoGroup: queuedJob.repoGroup,
    repos: queuedJob.repos,
    batchSelectionMode: queuedJob.batchSelectionMode,
    batchSelectionReason: queuedJob.batchSelectionReason,
    queuedVia: queuedJob.queuedVia,
    queuedAt: queuedJob.queuedAt,
  });
  return queuedJob;
}

function maybeRunAutoLaunchCycle() {
  const autonomy = readAutonomyConfig();
  setAutoLaunchStatus({ mode: autonomy.mode, state: 'idle', detail: 'Evaluating startable work.' });
  if (autonomy.mode === 'suggestions-only') {
    setAutoLaunchStatus({ mode: autonomy.mode, state: 'idle', detail: 'Suggestions-only mode: no automatic launches.' });
    return;
  }

  const dashboardState = buildDashboardState(readRawState());
  if ((dashboardState.healthChecks && dashboardState.healthChecks.status) !== 'ready') {
    setAutoLaunchStatus({ mode: autonomy.mode, state: 'blocked', detail: 'System health is not ready, so auto-launch is paused.' });
    return;
  }
  if (asArray(dashboardState.workers).length >= autonomy.maxConcurrentWorkers) {
    setAutoLaunchStatus({
      mode: autonomy.mode,
      state: 'blocked',
      detail: `Worker limit reached (${asArray(dashboardState.workers).length}/${autonomy.maxConcurrentWorkers}).`,
    });
    return;
  }

  // Items already in the waiting queue but not yet running (launch failed or manually queued)
  const runningKeys = new Set(asArray(dashboardState.workers).map(w => getTaskKeyFromJob(w)));
  const unlaunchedQueued = asArray(dashboardState.waitingQueue)
    .filter(job => !runningKeys.has(getTaskKeyFromJob(job)));

  // New candidates from the issue source that haven't been tracked yet
  const newCandidates = asArray(dashboardState.startableJobs).filter(c => !c.neverAutoStart);

  if (unlaunchedQueued.length === 0 && newCandidates.length === 0) {
    const allStartable = asArray(dashboardState.startableJobs);
    const detail = allStartable.length > 0
      ? 'All visible startable jobs are marked never auto start.'
      : 'No untracked startable jobs are available.';
    // All startable jobs are never-auto or none exist — not a real blockage, just nothing to do
    setAutoLaunchStatus({ mode: autonomy.mode, state: 'idle', detail });
    return;
  }

  // Select candidates up to worker capacity, queued items first
  const activeRepoGroups = new Map();
  for (const worker of asArray(dashboardState.workers)) {
    const repoGroup = firstNonEmptyString(worker && worker.repoGroup);
    if (!repoGroup) continue;
    activeRepoGroups.set(repoGroup, (activeRepoGroups.get(repoGroup) || 0) + 1);
  }

  const selectedQueued = [];
  const selectedNew = [];

  for (const candidate of [...unlaunchedQueued, ...newCandidates]) {
    const repoGroup = firstNonEmptyString(candidate && candidate.repoGroup, candidate && candidate.batching && candidate.batching.repoGroup);
    const activeRepoCount = repoGroup ? (activeRepoGroups.get(repoGroup) || 0) : 0;
    if (repoGroup && activeRepoCount >= autonomy.maxWorkersPerRepoGroup) continue;
    const totalSelected = selectedQueued.length + selectedNew.length;
    if (asArray(dashboardState.workers).length + totalSelected >= autonomy.maxConcurrentWorkers) break;
    if (repoGroup) activeRepoGroups.set(repoGroup, activeRepoCount + 1);
    if (unlaunchedQueued.includes(candidate)) {
      selectedQueued.push(candidate);
    } else {
      selectedNew.push(candidate);
    }
  }

  const selected = [...selectedQueued, ...selectedNew];

  if (selected.length === 0) {
    setAutoLaunchStatus({
      mode: autonomy.mode,
      state: 'blocked',
      detail: 'Repo-family launch guardrails are currently saturated.',
    });
    return;
  }

  // Enqueue only the new candidates (queued ones are already in the queue)
  const sourceState = readRawState();
  for (const candidate of selectedNew) {
    enqueueJobRecord(sourceState, candidate, 'auto-launcher');
  }
  writeState(sourceState);

  const jobNumbers = selected.map(c => c.jobNumber).join(', ');
  setAutoLaunchStatus({
    mode: autonomy.mode,
    state: 'launching',
    detail: `Starting ${selected.length} job(s) automatically: ${jobNumbers}`,
    lastJobNumber: selected[0].jobNumber,
  });

  // Launch all queued candidates in parallel
  const commandScript = path.join(AUTOTASK_DIR, 'tools', 'invoke-autotask-command.ps1');
  let launchCount = 0;
  let failureCount = 0;

  for (const candidate of selected) {
    const startCommand = `start ${candidate.jobNumber}${candidate.taskSequence ? ` --task ${candidate.taskSequence}` : ''}`;
    runPowerShellFile(commandScript, ['-CommandText', startCommand, '-Source', 'auto-launcher'], (err, stdout, stderr) => {
      if (err) {
        failureCount++;
        console.error(`[auto-launch] Failed to start ${candidate.jobNumber}: ${err.message}`);
        if (stderr && stderr.trim()) {
          console.error('[auto-launch] Stderr: ' + stderr.trim());
        }
        return;
      }

      launchCount++;
      let result = null;
      try {
        result = stdout && stdout.trim() ? JSON.parse(stdout) : null;
      } catch (parseError) {
        failureCount++;
        console.error(`[auto-launch] Invalid JSON for ${candidate.jobNumber}: ${parseError.message}`);
        return;
      }

      if (!result || !result.success) {
        failureCount++;
        console.error(`[auto-launch] Launch failed for ${candidate.jobNumber}: ${result && result.error}`);
        return;
      }

      console.log('[auto-launch] Started ' + candidate.jobNumber);
    });
  }

  // Update final status after all launches queued
  setAutoLaunchStatus({
    mode: autonomy.mode,
    state: 'launched',
    detail: `Queued ${selected.length} job(s) for automatic launch.`,
    lastJobNumber: selected[0].jobNumber,
    lastActionAt: new Date().toISOString(),
  });
}

function getPollerStatusSnapshot(status) {
  const intervalMs = asNumber(status && status.intervalMs, DEFAULT_EMAIL_POLLING_INTERVAL_MS);
  const staleThresholdMs = Math.max(intervalMs * 2, intervalMs + DEFAULT_POLLER_STALE_GRACE_MS);
  const lastActivityAt = firstNonEmptyString(status && status.lastAttemptAt, status && status.lastSuccessAt);
  const lastActivityAgeMs = lastActivityAt ? Math.max(0, Date.now() - Date.parse(lastActivityAt)) : Number.MAX_SAFE_INTEGER;
  const stale = Boolean(status && status.running && status.timerActive && !status.inFlight && lastActivityAt && lastActivityAgeMs > staleThresholdMs);

  let health = 'disabled';
  if (status && status.running) {
    health = stale
      ? 'stale'
      : isNonEmptyString(status.lastError)
        ? 'error'
        : status.inFlight
          ? 'running'
          : 'healthy';
  } else if (status && status.timerActive) {
    health = 'idle';
  }

  return {
    name: firstNonEmptyString(status && status.name),
    intervalMs,
    running: Boolean(status && status.running),
    timerActive: Boolean(status && status.timerActive),
    inFlight: Boolean(status && status.inFlight),
    lastAttemptAt: firstNonEmptyString(status && status.lastAttemptAt),
    lastSuccessAt: firstNonEmptyString(status && status.lastSuccessAt),
    lastError: firstNonEmptyString(status && status.lastError),
    disabledReason: firstNonEmptyString(status && status.disabledReason),
    warnings: asArray(status && status.warnings).filter(isNonEmptyString),
    consecutiveFailures: asNumber(status && status.consecutiveFailures, 0),
    reviveCount: asNumber(status && status.reviveCount, 0),
    stale,
    health,
  };
}

// --- Route handlers ---

function handleGetIndex(req, res) {
  const filePath = path.join(DASHBOARD_DIR, 'index.html');
  fs.readFile(filePath, 'utf8', (err, content) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('index.html not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      Pragma: 'no-cache',
      Expires: '0',
      'Access-Control-Allow-Origin': '*',
    });
    res.end(content);
  });
}

function handleGetFavicon(req, res) {
  const filePath = path.join(DASHBOARD_DIR, 'favicon.ico');
  fs.readFile(filePath, (err, content) => {
    if (err) {
      res.writeHead(404, {
        'Content-Type': 'text/plain',
        'Cache-Control': 'no-store, no-cache, must-revalidate',
        Pragma: 'no-cache',
        Expires: '0',
        'Access-Control-Allow-Origin': '*',
      });
      res.end('favicon.ico not found');
      return;
    }

    res.writeHead(200, {
      'Content-Type': 'image/x-icon',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      Pragma: 'no-cache',
      Expires: '0',
      'Access-Control-Allow-Origin': '*',
    });
    res.end(content);
  });
}

function handleGetState(req, res) {
  try {
    const etag = getStateEtag();
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304);
      res.end();
      return;
    }
    const state = buildDashboardState(readRawState());
    res.setHeader('ETag', etag);
    sendJson(res, 200, state);
  } catch (e) {
    sendError(res, 500, 'Failed to read state: ' + e.message);
  }
}

async function handleJump(req, res) {
  try {
    const body = await parseBody(req);
    const { jobNumber } = body;
    if (!jobNumber) return sendError(res, 400, 'jobNumber required');

    const cmd = 'wt.exe -w 0 focus-tab --title "' + jobNumber + '"';
    exec(cmd, (err, stdout, stderr) => {
      if (err) {
        console.error('[jump] Error: ' + err.message);
        return sendJson(res, 200, { success: false, error: err.message });
      }
      sendJson(res, 200, { success: true, message: 'Focused tab for ' + jobNumber });
    });
  } catch (e) {
    sendError(res, 400, e.message);
  }
}

// handleManualComplete: moves a running worker to completedJobs without touching the workspace
// or stopping any process. Intentionally kept — triggered by the "Complete" button on running
// cards when the developer wants to manually mark a job done (e.g. worker exited silently).
async function handleManualComplete(req, res, jobNumber) {
  try {
    if (!jobNumber) return sendError(res, 400, 'jobNumber required in URL');
    const taskSequence = firstNonEmptyString(new URL(req.url, 'http://' + req.headers.host).searchParams.get('taskSequence'));

    const state = readRawState();
    const entry = getStateEntry(state, jobNumber, taskSequence);
    if (!entry) return sendError(res, 404, `${jobNumber}${taskSequence ? ` task ${taskSequence}` : ''} was not found in state.`);
    const targetKey = getTaskKey(jobNumber, taskSequence || entry.job.taskSequence);

    // Move from workers to completedJobs
    const job = asArray(state.workers).find(j => getTaskKeyFromJob(j) === targetKey);
    if (!job) return sendError(res, 404, `${jobNumber}${taskSequence ? ` task ${taskSequence}` : ''} is not in the running workers list.`);

    job.status = 'done';
    job.phase = 'complete';
    job.completedAt = new Date().toISOString();

    state.workers = asArray(state.workers).filter(j => getTaskKeyFromJob(j) !== targetKey);
    state.completedJobs = [job, ...asArray(state.completedJobs)];
    writeState(state);

    sendJson(res, 200, {
      success: true,
      message: `Marked ${jobNumber}${taskSequence ? ` task ${taskSequence}` : ''} as complete.`,
      state: buildDashboardState(state),
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleCleanup(req, res, jobNumber) {
  try {
    if (!jobNumber) return sendError(res, 400, 'jobNumber required in URL');
    const taskSequence = firstNonEmptyString(new URL(req.url, 'http://' + req.headers.host).searchParams.get('taskSequence'));

    const state = readRawState();
    const entry = getStateEntry(state, jobNumber, taskSequence);
    if (!entry) return sendError(res, 404, `${jobNumber}${taskSequence ? ` task ${taskSequence}` : ''} was not found in state.`);
    const workspacePath = firstNonEmptyString(entry.job.workspacePath, entry.job.workspace);
    const targetKey = getTaskKey(jobNumber, taskSequence || entry.job.taskSequence);
    const hasSiblingTasks = [
      ...asArray(state.workers),
      ...asArray(state.completedJobs),
      ...asArray(state.failedJobs),
      ...asArray(state.waitingQueue),
    ].some(job => firstNonEmptyString(job && job.jobNumber) === jobNumber && getTaskKeyFromJob(job) !== targetKey);

    // Workspace directories are intentionally preserved — they may contain useful artifacts
    // and should be cleaned up manually by the developer when ready.

    state.workers = asArray(state.workers).filter(j => getTaskKeyFromJob(j) !== targetKey);
    state.completedJobs = asArray(state.completedJobs).filter(j => getTaskKeyFromJob(j) !== targetKey);
    state.failedJobs = asArray(state.failedJobs).filter(j => getTaskKeyFromJob(j) !== targetKey);
    state.waitingQueue = asArray(state.waitingQueue).filter(j => getTaskKeyFromJob(j) !== targetKey);
    writeState(state);

    sendJson(res, 200, {
      success: true,
      message: hasSiblingTasks
        ? `Removed ${jobNumber}${taskSequence ? ` task ${taskSequence}` : ''} and kept the shared workspace because other tasks for this WI still exist.`
        : `Cleaned up ${jobNumber}${taskSequence ? ` task ${taskSequence}` : ''}.`,
      state: buildDashboardState(state),
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleQueue(req, res) {
  try {
    const body = await parseBody(req);
    const { jobNumber } = body;
    if (!jobNumber) return sendError(res, 400, 'jobNumber required');
    const taskSequence = firstNonEmptyString(body && body.taskSequence);

    const state = readRawState();
    if (!state.waitingQueue) state.waitingQueue = [];

    const normalizedState = normalizeState(state);
    const targetKey = getTaskKey(jobNumber, taskSequence);
    const taskLabel = taskSequence ? `${jobNumber} task ${taskSequence}` : jobNumber;
    if (normalizedState.waitingQueue.some(job => getTaskKeyFromJob(job) === targetKey)) {
      return sendJson(res, 409, { success: false, error: `${taskLabel} is already queued.`, state: buildDashboardState(state) });
    }
    if (normalizedState.workers.some(job => getTaskKeyFromJob(job) === targetKey)) {
      return sendJson(res, 409, { success: false, error: `${taskLabel} already has an active worker.`, state: buildDashboardState(state) });
    }
    if (normalizedState.completedJobs.some(job => getTaskKeyFromJob(job) === targetKey)) {
      return sendJson(res, 409, { success: false, error: `${taskLabel} is already completed. Clean it up before queueing again.`, state: buildDashboardState(state) });
    }
    if (normalizedState.failedJobs.some(job => getTaskKeyFromJob(job) === targetKey)) {
      return sendJson(res, 409, { success: false, error: `${taskLabel} is currently in failed jobs. Clean it up before queueing again.`, state: buildDashboardState(state) });
    }

    const queuedJob = normalizeJob({
      ...body,
      jobNumber,
      queuedAt: new Date().toISOString(),
      queuedVia: firstNonEmptyString(body.queuedVia, 'dashboard'),
      source: firstNonEmptyString(body.source, 'dashboard'),
    });
    if (!queuedJob) return sendError(res, 400, 'Invalid job payload');

    state.waitingQueue.push({
      jobNumber: queuedJob.jobNumber,
      jobGuid: queuedJob.jobGuid,
      taskSequence: queuedJob.taskSequence,
      taskType: queuedJob.taskType,
      summary: queuedJob.summary,
      description: queuedJob.description,
      zone: queuedJob.zone,
      source: queuedJob.source,
      sources: queuedJob.sources,
      repoGroup: queuedJob.repoGroup,
      repos: queuedJob.repos,
      batchSelectionMode: queuedJob.batchSelectionMode,
      batchSelectionReason: queuedJob.batchSelectionReason,
      queuedVia: queuedJob.queuedVia,
      queuedAt: queuedJob.queuedAt,
    });

    writeState(state);
    sendJson(res, 200, { success: true, state: buildDashboardState(state) });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

function handleRestart(req, res) {
  // Graceful restart: respond first, then trigger process exit so PM2 restarts us.
  // If not under PM2 the process simply exits and must be started manually.
  sendJson(res, 200, { success: true, message: 'Restarting dashboard server...' });
  console.log('[restart] Restart requested via /api/restart — exiting for PM2 to restart.');
  setTimeout(() => process.exit(0), 300);
}

async function handleCommand(req, res) {
  try {
    const body = await parseBody(req);
    const { command, source, responder } = body;
    if (!command) return sendError(res, 400, 'command required');
    const neverAutoMatch = String(command).trim().match(/^(never-auto|allow-auto)\s+((WI|CS|PRJ)\d+)(?:\s+--task\s+(\S+))?/i);
    if (neverAutoMatch) {
      const verb = neverAutoMatch[1].toLowerCase();
      const jobNumber = neverAutoMatch[2].toUpperCase();
      const taskSequence = firstNonEmptyString(neverAutoMatch[4]);
      const neverAutoStart = verb === 'never-auto';
      const state = readRawState();
      if (!state.autoStartPreferences || typeof state.autoStartPreferences !== 'object' || Array.isArray(state.autoStartPreferences)) {
        state.autoStartPreferences = {};
      }
      const preferenceKey = getTaskKey(jobNumber, taskSequence);
      if (neverAutoStart) {
        state.autoStartPreferences[preferenceKey] = { neverAutoStart: true, taskSequence, updatedAt: new Date().toISOString() };
      } else {
        delete state.autoStartPreferences[preferenceKey];
      }
      writeState(state);
      maybeRunAutoLaunchCycle();
      const label = taskSequence ? `${jobNumber} task ${taskSequence}` : jobNumber;
      return sendJson(res, 200, {
        success: true,
        message: neverAutoStart ? `${label} marked as never auto start.` : `${label} auto start preference cleared.`,
        state: buildDashboardState(readRawState()),
      });
    }

    const scriptPath = path.join(AUTOTASK_DIR, 'tools', 'invoke-autotask-command.ps1');
    const args = ['-CommandText', String(command), '-Source', firstNonEmptyString(source, 'dashboard-command')];
    if (responder) args.push('-Responder', String(responder));

    runPowerShellFile(scriptPath, args, (err, stdout, stderr) => {
      if (err) {
        console.error('[command] Error: ' + err.message);
        return sendJson(res, 200, { success: false, error: err.message });
      }

      let result = null;
      try {
        result = stdout && stdout.trim() ? JSON.parse(stdout) : null;
      } catch {
        result = {
          success: false,
          error: stdout && stdout.trim() ? stdout.trim() : 'Command script returned invalid JSON.',
        };
      }

      if (!result || !result.success) {
        return sendJson(res, 200, result || { success: false, error: 'Command failed.' });
      }

      console.log('[command] Executed: ' + command);
      sendJson(res, 200, result);

      // Broadcast status reports to Teams + email when a full status command is run from the dashboard.
      // runPowerShellFile is non-blocking so these fire after the response is already sent.
      if (result.action === 'status' && result.data && result.data.statusReport) {
        const broadcastPayload = JSON.stringify({ templateName: 'status-report', data: result.data });
        const teamsScript = path.join(AUTOTASK_DIR, 'tools', 'send-teams-notification.ps1');
        const emailScript = path.join(AUTOTASK_DIR, 'tools', 'send-email-notification.ps1');
        const commandSource = firstNonEmptyString(source, 'dashboard-command');

        if (commandSource !== 'teams-command-poller') {
          runPowerShellFile(teamsScript, ['-JsonPayload', broadcastPayload], (err) => {
            if (err) console.error('[command] Teams status broadcast error: ' + err.message);
          });
        }
        if (commandSource !== 'email-command') {
          runPowerShellFile(emailScript, ['-JsonPayload', broadcastPayload], (err) => {
            if (err) console.error('[command] Email status broadcast error: ' + err.message);
          });
        }
      }
    });
  } catch (e) {
    sendError(res, 400, e.message);
  }
}

async function handleAutonomyConfig(req, res) {
  try {
    const body = await parseBody(req);
    const mode = firstNonEmptyString(body && body.mode).toLowerCase();
    const maxConcurrentWorkers = asNumber(body && body.maxConcurrentWorkers, Number.NaN);

    if (mode && !['suggestions-only', 'auto'].includes(mode)) {
      return sendError(res, 400, 'Invalid autonomy mode.');
    }
    if (Number.isFinite(maxConcurrentWorkers) && maxConcurrentWorkers < 1) {
      return sendError(res, 400, 'maxConcurrentWorkers must be at least 1.');
    }

    if (mode) {
      upsertLocalConfigValue('autonomy_mode', mode);
    }
    if (Number.isFinite(maxConcurrentWorkers)) {
      upsertLocalConfigValue('max_concurrent_workers', Math.trunc(maxConcurrentWorkers));
    }

    setAutoLaunchStatus({
      mode: firstNonEmptyString(mode, readAutonomyConfig().mode),
      state: 'idle',
      detail: 'Autonomy settings updated.',
    });
    maybeRunAutoLaunchCycle();
    sendJson(res, 200, { success: true, state: buildDashboardState(readRawState()) });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleGetTaskNotes(req, res) {
  try {
    const parsedUrl = new URL(req.url, 'http://localhost');
    const jobNumber = (parsedUrl.searchParams.get('jobNumber') || '').toUpperCase();
    const taskSequence = parsedUrl.searchParams.get('taskSequence') || '';
    if (!/^(WI|CS|PRJ)\d{8}$/.test(jobNumber)) return sendError(res, 400, 'Valid jobNumber required.');
    if (!taskSequence) return sendError(res, 400, 'taskSequence required.');

    const scriptPath = path.join(AUTOTASK_DIR, 'tools', 'get-autotask-task-notes.ps1');
    const args = ['-JobNumber', jobNumber, '-TaskSequence', taskSequence];
    runPowerShellFile(scriptPath, args, (err, stdout) => {
      if (err) return sendJson(res, 200, { success: false, error: err.message });
      try {
        const result = JSON.parse((stdout || '').trim());
        sendJson(res, 200, result);
      } catch {
        sendJson(res, 200, { success: false, error: (stdout || '').trim() || 'Unexpected output from notes script.' });
      }
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleSetTaskNotes(req, res) {
  try {
    const body = await parseBody(req);
    const jobNumber = firstNonEmptyString(body && body.jobNumber).toUpperCase();
    const taskSequence = firstNonEmptyString(body && body.taskSequence);
    const content = body && body.content != null ? String(body.content) : null;
    if (!/^(WI|CS|PRJ)\d{8}$/.test(jobNumber)) return sendError(res, 400, 'Valid jobNumber required.');
    if (!taskSequence) return sendError(res, 400, 'taskSequence required.');
    if (content === null) return sendError(res, 400, 'content required.');

    const scriptPath = path.join(AUTOTASK_DIR, 'tools', 'set-autotask-task-notes.ps1');
    const args = ['-JobNumber', jobNumber, '-TaskSequence', taskSequence, '-Content', content];
    runPowerShellFile(scriptPath, args, (err, stdout) => {
      if (err) return sendJson(res, 200, { success: false, error: err.message });
      try {
        const result = JSON.parse((stdout || '').trim());
        sendJson(res, 200, result);
      } catch {
        sendJson(res, 200, { success: false, error: (stdout || '').trim() || 'Unexpected output from notes script.' });
      }
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleStartablePreference(req, res) {
  try {
    const body = await parseBody(req);
    const jobNumber = firstNonEmptyString(body && body.jobNumber).toUpperCase();
    const taskSequence = firstNonEmptyString(body && body.taskSequence);
    if (!/^(WI|CS|PRJ)\d{8}$/.test(jobNumber)) {
      return sendError(res, 400, 'Valid jobNumber required.');
    }

    const neverAutoStart = Boolean(body && body.neverAutoStart);
    const state = readRawState();
    if (!state.autoStartPreferences || typeof state.autoStartPreferences !== 'object' || Array.isArray(state.autoStartPreferences)) {
      state.autoStartPreferences = {};
    }
    const preferenceKey = getTaskKey(jobNumber, taskSequence);

    if (neverAutoStart) {
      state.autoStartPreferences[preferenceKey] = {
        neverAutoStart: true,
        taskSequence,
        updatedAt: new Date().toISOString(),
      };
    } else {
      delete state.autoStartPreferences[preferenceKey];
    }

    writeState(state);
    maybeRunAutoLaunchCycle();
    sendJson(res, 200, { success: true, state: buildDashboardState(readRawState()) });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleSubmitInput(req, res) {
  try {
    const body = await parseBody(req);
    const { jobNumber, taskSequence, response, requestId, source, responder } = body;
    if (!jobNumber) return sendError(res, 400, 'jobNumber required');
    if (!response || !String(response).trim()) return sendError(res, 400, 'response required');

    const scriptPath = path.join(AUTOTASK_DIR, 'tools', 'submit-autotask-user-input.ps1');
    const args = ['-JobNumber', jobNumber, '-Response', String(response)];
    if (firstNonEmptyString(taskSequence)) args.push('-TaskSequence', String(taskSequence));
    if (requestId) args.push('-RequestId', requestId);
    if (source) args.push('-Source', source);
    if (responder) args.push('-Responder', responder);

    runPowerShellFile(scriptPath, args, (err, stdout, stderr) => {
      if (err) {
        console.error('[submit-input] Error: ' + err.message);
        return sendJson(res, 200, { success: false, error: err.message });
      }

      let result = null;
      try {
        result = stdout && stdout.trim() ? JSON.parse(stdout) : null;
      } catch {
        result = { raw: stdout.trim() };
      }

      sendJson(res, 200, { success: true, result });
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleTeamsNotify(req, res) {
  try {
    const body = await parseBody(req);
    const toolsDir = path.join(AUTOTASK_DIR, 'tools');
    runPowerShellFile(path.join(toolsDir, 'send-teams-notification.ps1'), ['-JsonPayload', JSON.stringify(body)], (err, stdout, stderr) => {
      if (err) {
        console.error('[teams-notify] Error: ' + err.message);
        return sendJson(res, 200, { success: false, error: err.message });
      }
      sendJson(res, 200, { success: true, output: stdout.trim() });
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

async function handleEmailNotify(req, res) {
  try {
    const body = await parseBody(req);
    const toolsDir = path.join(AUTOTASK_DIR, 'tools');
    runPowerShellFile(path.join(toolsDir, 'send-email-notification.ps1'), ['-JsonPayload', JSON.stringify(body)], (err, stdout, stderr) => {
      if (err) {
        console.error('[email-notify] Error: ' + err.message);
        return sendJson(res, 200, { success: false, error: err.message });
      }
      sendJson(res, 200, { success: true, output: stdout.trim() });
    });
  } catch (e) {
    sendError(res, 500, e.message);
  }
}

function revivePoller(pollerName) {
  if (pollerName === 'email') {
    if (emailPollTimer) {
      clearInterval(emailPollTimer);
      emailPollTimer = null;
    }
    emailPollInFlight = false;
    emailPollStatus.inFlight = false;
    emailPollStatus.reviveCount += 1;
    startEmailReplyPoller();
    return 'Revived email poller.';
  }

  if (pollerName === 'teams') {
    if (teamsCommandPollTimer) {
      clearInterval(teamsCommandPollTimer);
      teamsCommandPollTimer = null;
    }
    teamsCommandPollInFlight = false;
    teamsCommandPollStatus.inFlight = false;
    teamsCommandPollStatus.reviveCount += 1;
    startTeamsCommandPoller();
    return 'Revived Teams poller.';
  }

  if (pollerName === 'startable') {
    if (startableJobsPollTimer) {
      clearInterval(startableJobsPollTimer);
      startableJobsPollTimer = null;
    }
    startableJobsPollInFlight = false;
    startablePollStatus.inFlight = false;
    startablePollStatus.reviveCount += 1;
    startStartableJobsPoller();
    return 'Revived startable poller.';
  }

  throw new Error(`Unknown poller '${pollerName}'.`);
}

async function handleRevivePoller(req, res) {
  try {
    const body = await parseBody(req);
    const pollerName = firstNonEmptyString(body && body.poller, 'all').toLowerCase();
    const messages = [];

    if (pollerName === 'all') {
      messages.push(revivePoller('email'));
      if (shouldExposeTeamsPoller()) {
        messages.push(revivePoller('teams'));
      }
      messages.push(revivePoller('startable'));
    } else {
      messages.push(revivePoller(pollerName));
    }

    sendJson(res, 200, {
      success: true,
      message: messages.join(' '),
      pollers: {
        email: getPollerStatusSnapshot(emailPollStatus),
        ...(shouldExposeTeamsPoller() ? { teams: { ...getPollerStatusSnapshot(teamsCommandPollStatus), pollerLog: teamsCommandPollerLog } } : {}),
        startable: { ...getPollerStatusSnapshot(startablePollStatus), pollerLog: startablePollerLog },
      },
    });
  } catch (e) {
    sendError(res, 400, e.message);
  }
}

let emailPollTimer = null;
let emailPollInFlight = false;

function startEmailReplyPoller() {
  const pollIntervalMs = readConfigNumberValue('email_polling_interval_ms', DEFAULT_EMAIL_POLLING_INTERVAL_MS);
  emailPollStatus.intervalMs = pollIntervalMs;
  emailPollStatus.warnings = [];
  emailPollStatus.lastError = '';
  emailPollStatus.disabledReason = '';

  const smtpFrom = readConfigTextValue('smtp_from');
  const smtpTo = readConfigTextValue('smtp_to');
  if (!smtpFrom || !smtpTo) {
    emailPollStatus.running = false;
    emailPollStatus.timerActive = false;
    emailPollStatus.disabledReason = 'smtp_from/smtp_to not configured';
    console.log('[email-poller] Disabled: smtp_from/smtp_to not configured');
    return;
  }

  const pollScript = path.join(AUTOTASK_DIR, 'tools', 'poll-autotask-email-input.ps1');
  if (!fs.existsSync(pollScript)) {
    emailPollStatus.running = false;
    emailPollStatus.timerActive = false;
    emailPollStatus.disabledReason = 'Poll script not found';
    console.log('[email-poller] Disabled: poll script not found');
    return;
  }

  if (emailPollTimer) {
    clearInterval(emailPollTimer);
    emailPollTimer = null;
  }

  const poll = () => {
    if (emailPollInFlight) return;
    emailPollInFlight = true;
    emailPollStatus.running = true;
    emailPollStatus.timerActive = true;
    emailPollStatus.inFlight = true;
    emailPollStatus.lastAttemptAt = new Date().toISOString();

    runPowerShellFile(pollScript, [], (err, stdout, stderr) => {
      emailPollInFlight = false;
      emailPollStatus.inFlight = false;
      if (err) {
        emailPollStatus.lastError = err.message;
        emailPollStatus.consecutiveFailures += 1;
        console.error('[email-poller] Error: ' + err.message);
        return;
      }

      if (stdout && stdout.trim()) {
        try {
          const result = JSON.parse(stdout);
          emailPollStatus.lastSuccessAt = new Date().toISOString();
          emailPollStatus.lastError = '';
          emailPollStatus.consecutiveFailures = 0;
          emailPollStatus.warnings = Array.isArray(result.rejectedCommands) && result.rejectedCommands.length > 0
            ? ['Rejected ' + result.rejectedCommands.length + ' command email(s).']
            : [];
          if (Array.isArray(result.processed) && result.processed.length > 0) {
            console.log('[email-poller] Processed ' + result.processed.length + ' reply message(s)');
          }
          if (Array.isArray(result.commandsProcessed) && result.commandsProcessed.length > 0) {
            console.log('[email-poller] Processed ' + result.commandsProcessed.length + ' command message(s)');
          }
          if (Array.isArray(result.rejectedCommands) && result.rejectedCommands.length > 0) {
            console.warn('[email-poller] Rejected ' + result.rejectedCommands.length + ' command message(s)');
          }
        } catch (parseError) {
          emailPollStatus.lastError = 'Failed to parse email poll JSON: ' + parseError.message;
          emailPollStatus.consecutiveFailures += 1;
          console.log('[email-poller] Output: ' + stdout.trim());
        }
      } else {
        emailPollStatus.lastSuccessAt = new Date().toISOString();
        emailPollStatus.lastError = '';
        emailPollStatus.consecutiveFailures = 0;
        emailPollStatus.warnings = [];
      }
    });
  };

  emailPollTimer = setInterval(poll, pollIntervalMs);
  emailPollStatus.running = true;
  emailPollStatus.timerActive = true;
  poll();
  console.log('[email-poller] Started with interval ' + pollIntervalMs + 'ms');
}

function startTeamsCommandPoller() {
  const pollIntervalMs = readConfigNumberValue('teams_chat_polling_interval_ms', DEFAULT_TEAMS_CHAT_POLLING_INTERVAL_MS);
  teamsCommandPollStatus.intervalMs = pollIntervalMs;
  teamsCommandPollStatus.warnings = [];
  teamsCommandPollStatus.lastError = '';
  teamsCommandPollStatus.disabledReason = '';

  if (!shouldExposeTeamsPoller()) {
    teamsCommandPollStatus.running = false;
    teamsCommandPollStatus.timerActive = false;
    teamsCommandPollStatus.disabledReason = 'Teams chat is not configured';
    teamsCommandPollerLog = { status: 'skipped', jobCount: 0, message: 'Teams chat is not configured', lastPollAt: new Date().toISOString() };
    return;
  }

  if (!readConfigBooleanValue('teams_chat_enabled', false)) {
    teamsCommandPollStatus.running = false;
    teamsCommandPollStatus.timerActive = false;
    teamsCommandPollStatus.disabledReason = 'teams_chat_enabled is false';
    teamsCommandPollerLog = { status: 'skipped', jobCount: 0, message: 'teams_chat_enabled is false', lastPollAt: new Date().toISOString() };
    return;
  }

  const targetMode = getTeamsChatTargetMode();
  if (!['self', 'person', 'chat', 'conversation-id'].includes(targetMode)) {
    teamsCommandPollStatus.running = false;
    teamsCommandPollStatus.timerActive = false;
    teamsCommandPollStatus.disabledReason = `Unsupported target mode '${targetMode}'`;
    teamsCommandPollerLog = { status: 'error', jobCount: 0, message: `Unsupported target mode '${targetMode}'`, lastPollAt: new Date().toISOString() };
    return;
  }

  if (!isTeamsChatTargetConfigured(targetMode)) {
    teamsCommandPollStatus.running = false;
    teamsCommandPollStatus.timerActive = false;
    teamsCommandPollStatus.disabledReason = 'teams_chat_target is missing';
    teamsCommandPollerLog = { status: 'skipped', jobCount: 0, message: 'teams_chat_target is missing', lastPollAt: new Date().toISOString() };
    return;
  }

  if (!readConfigBooleanValue('teams_chat_command_polling_enabled', false)) {
    teamsCommandPollStatus.running = false;
    teamsCommandPollStatus.timerActive = false;
    teamsCommandPollStatus.disabledReason = 'teams_chat_command_polling_enabled is false';
    teamsCommandPollerLog = { status: 'skipped', jobCount: 0, message: 'Command polling disabled', lastPollAt: new Date().toISOString() };
    return;
  }

  const pollScript = path.join(AUTOTASK_DIR, 'tools', 'poll-autotask-teams-input.ps1');
  if (!fs.existsSync(pollScript)) {
    teamsCommandPollStatus.running = false;
    teamsCommandPollStatus.timerActive = false;
    teamsCommandPollStatus.disabledReason = 'Poll script not found';
    teamsCommandPollerLog = { status: 'error', jobCount: 0, message: 'Poll script not found', lastPollAt: new Date().toISOString() };
    return;
  }

  if (teamsCommandPollTimer) {
    clearInterval(teamsCommandPollTimer);
    teamsCommandPollTimer = null;
  }

  const poll = () => {
    if (teamsCommandPollInFlight) return;
    teamsCommandPollInFlight = true;
    teamsCommandPollStatus.running = true;
    teamsCommandPollStatus.timerActive = true;
    teamsCommandPollStatus.inFlight = true;
    teamsCommandPollStatus.lastAttemptAt = new Date().toISOString();

    runPowerShellFile(pollScript, ['-Top', '60'], (err, stdout, stderr) => {
      teamsCommandPollInFlight = false;
      teamsCommandPollStatus.inFlight = false;
      if (err) {
        teamsCommandPollStatus.lastError = err.message;
        teamsCommandPollStatus.consecutiveFailures += 1;
        teamsCommandPollerLog = { status: 'error', jobCount: 0, message: err.message, lastPollAt: new Date().toISOString() };
        console.error('[teams-poller] Error: ' + err.message);
        if (stderr && stderr.trim()) {
          console.error('[teams-poller] Stderr: ' + stderr.trim());
        }
        return;
      }

      try {
        const result = stdout && stdout.trim() ? JSON.parse(stdout) : {};
        const pollTimestamp = firstNonEmptyString(result.polledAt, new Date().toISOString());
        teamsCommandPollStatus.lastSuccessAt = pollTimestamp;
        teamsCommandPollStatus.lastError = '';
        teamsCommandPollStatus.consecutiveFailures = 0;
        teamsCommandPollStatus.warnings = asArray(result.warnings).filter(isNonEmptyString);

        const processedCount = asArray(result.commandsProcessed).length;
        const rejectedCount = asArray(result.rejectedCommands).length;
        let message = 'No new Teams commands';
        if (processedCount > 0 || rejectedCount > 0) {
          const fragments = [];
          if (processedCount > 0) fragments.push(`${processedCount} processed`);
          if (rejectedCount > 0) fragments.push(`${rejectedCount} rejected`);
          message = fragments.join(', ') + ' command(s)';
        } else if (result.disabledReason) {
          message = String(result.disabledReason);
        }

        teamsCommandPollerLog = {
          status: result.disabled ? 'skipped' : 'ok',
          jobCount: processedCount,
          message,
          lastPollAt: pollTimestamp,
        };

        if (result.disabled) {
          teamsCommandPollStatus.running = false;
          teamsCommandPollStatus.timerActive = false;
          teamsCommandPollStatus.disabledReason = firstNonEmptyString(result.disabledReason, 'Teams command polling disabled');
        } else {
          teamsCommandPollStatus.disabledReason = '';
        }

        if (processedCount > 0) {
          console.log('[teams-poller] Processed ' + processedCount + ' command message(s)');
        }
        if (rejectedCount > 0) {
          console.warn('[teams-poller] Rejected ' + rejectedCount + ' command message(s)');
        }
        if (teamsCommandPollStatus.warnings.length > 0) {
          console.warn('[teams-poller] Warnings: ' + teamsCommandPollStatus.warnings.join(' | '));
        }
      } catch (parseError) {
        teamsCommandPollStatus.lastError = 'Failed to parse Teams poll JSON: ' + parseError.message;
        teamsCommandPollStatus.consecutiveFailures += 1;
        teamsCommandPollerLog = { status: 'error', jobCount: 0, message: teamsCommandPollStatus.lastError, lastPollAt: new Date().toISOString() };
        console.error('[teams-poller] ' + teamsCommandPollStatus.lastError);
        if (stdout && stdout.trim()) {
          console.error('[teams-poller] Output: ' + stdout.trim());
        }
      }
    });
  };

  teamsCommandPollTimer = setInterval(poll, pollIntervalMs);
  teamsCommandPollStatus.running = true;
  teamsCommandPollStatus.timerActive = true;
  poll();
  console.log('[teams-poller] Started with interval ' + pollIntervalMs + 'ms');
}

function startStartableJobsPoller() {
  const pollIntervalMs = readConfigNumberValue('startable_jobs_polling_interval_ms', DEFAULT_STARTABLE_JOBS_POLLING_INTERVAL_MS);
  const fetchTimeoutMs = readConfigNumberValue('startable_jobs_fetch_timeout_ms', DEFAULT_STARTABLE_JOBS_FETCH_TIMEOUT_MS);
  startablePollStatus.intervalMs = pollIntervalMs;
  startablePollStatus.warnings = [];
  startablePollStatus.lastError = '';
  startablePollStatus.disabledReason = '';

  const pollScript = path.join(AUTOTASK_DIR, 'tools', 'get-autotask-startable-jobs.ps1');
  if (!fs.existsSync(pollScript)) {
    startablePollStatus.running = false;
    startablePollStatus.timerActive = false;
    startablePollStatus.disabledReason = 'Poll script not found';
    startablePollerLog = { status: 'skipped', jobCount: 0, message: 'Poll script not found', lastPollAt: new Date().toISOString() };
    console.log('[startable-poller] Disabled: poll script not found');
    return;
  }

  if (startableJobsPollTimer) {
    clearInterval(startableJobsPollTimer);
    startableJobsPollTimer = null;
  }

  const poll = () => {
    if (startableJobsPollInFlight) return;
    startableJobsPollInFlight = true;
    startablePollStatus.running = true;
    startablePollStatus.timerActive = true;
    startablePollStatus.inFlight = true;
    startablePollStatus.lastAttemptAt = new Date().toISOString();

    runPowerShellFile(pollScript, [], (err, stdout, stderr) => {
      startableJobsPollInFlight = false;
      startablePollStatus.inFlight = false;
      if (err) {
        lastStartablePollError = err.message;
        startablePollStatus.lastError = err.message;
        startablePollStatus.consecutiveFailures += 1;
        startablePollerLog = { status: 'error', jobCount: 0, message: err.message, lastPollAt: new Date().toISOString() };
        console.error('[startable-poller] Error: ' + err.message);
        if (stderr && stderr.trim()) {
          console.error('[startable-poller] Stderr: ' + stderr.trim());
        }
        return;
      }

      try {
        const result = stdout && stdout.trim() ? JSON.parse(stdout) : {};
        startableJobsCache = mergeJobCollection(result.startableJobs);
        startableJobsWarnings = asArray(result.warnings).filter(isNonEmptyString);
        lastStartablePollAt = firstNonEmptyString(result.fetchedAt, new Date().toISOString());
        lastStartablePollError = firstNonEmptyString(result.error);
        startablePollStatus.lastSuccessAt = lastStartablePollAt;
        startablePollStatus.lastError = lastStartablePollError;
        startablePollStatus.warnings = startableJobsWarnings;
        startablePollStatus.consecutiveFailures = lastStartablePollError ? 1 : 0;

        const pollTimestamp = lastStartablePollAt || new Date().toISOString();
        if (lastStartablePollError) {
          startablePollerLog = { status: 'error', jobCount: startableJobsCache.length, message: lastStartablePollError, lastPollAt: pollTimestamp };
        } else {
          startablePollerLog = { status: 'ok', jobCount: startableJobsCache.length, message: startableJobsCache.length + ' jobs found', lastPollAt: pollTimestamp };
        }

        console.log('[startable-poller] Loaded ' + startableJobsCache.length + ' startable job(s)');
        if (startableJobsWarnings.length > 0) {
          console.warn('[startable-poller] Warnings: ' + startableJobsWarnings.join(' | '));
        }
        maybeRunAutoLaunchCycle();
      } catch (parseError) {
        lastStartablePollError = 'Failed to parse startable jobs JSON: ' + parseError.message;
        startablePollStatus.lastError = lastStartablePollError;
        startablePollStatus.consecutiveFailures += 1;
        startablePollerLog = { status: 'error', jobCount: 0, message: lastStartablePollError, lastPollAt: new Date().toISOString() };
        console.error('[startable-poller] ' + lastStartablePollError);
        if (stdout && stdout.trim()) {
          console.error('[startable-poller] Output: ' + stdout.trim());
        }
      }
    }, {
      timeout: fetchTimeoutMs,
    });
  };

  startableJobsPollTimer = setInterval(poll, pollIntervalMs);
  startablePollStatus.running = true;
  startablePollStatus.timerActive = true;
  poll();
  console.log('[startable-poller] Started with interval ' + pollIntervalMs + 'ms');
}

// --- Server ---

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://' + req.headers.host);
  const method = req.method.toUpperCase();
  const pathname = url.pathname;

  const ts = new Date().toISOString();
  console.log('[' + ts + '] ' + method + ' ' + pathname);

  // CORS preflight
  if (method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    res.end();
    return;
  }

  try {
    if (method === 'GET' && pathname === '/') return handleGetIndex(req, res);
    if (method === 'GET' && pathname === '/favicon.ico') return handleGetFavicon(req, res);
    if (method === 'GET' && pathname === '/api/state') return handleGetState(req, res);
    if (method === 'POST' && pathname === '/api/jump') return await handleJump(req, res);
    if (method === 'POST' && pathname === '/api/queue') return await handleQueue(req, res);
    if (method === 'POST' && pathname === '/api/command') return await handleCommand(req, res);
    if (method === 'POST' && pathname === '/api/autonomy-config') return await handleAutonomyConfig(req, res);
    if (method === 'GET' && pathname === '/api/notes') return handleGetTaskNotes(req, res);
    if (method === 'POST' && pathname === '/api/notes') return await handleSetTaskNotes(req, res);
    if (method === 'POST' && pathname === '/api/startable-preference') return await handleStartablePreference(req, res);
    if (method === 'POST' && pathname === '/api/submit-input') return await handleSubmitInput(req, res);
    if (method === 'POST' && pathname === '/api/pollers/revive') return await handleRevivePoller(req, res);
    if (method === 'POST' && pathname === '/api/teams-notify') return await handleTeamsNotify(req, res);
    if (method === 'POST' && pathname === '/api/email-notify') return await handleEmailNotify(req, res);
    if (method === 'POST' && pathname === '/api/restart') return handleRestart(req, res);

    // Cleanup route: POST /api/cleanup/:jobNumber
    const cleanupMatch = pathname.match(/^\/api\/cleanup\/(.+)$/);
    if (method === 'POST' && cleanupMatch) {
      return await handleCleanup(req, res, decodeURIComponent(cleanupMatch[1]));
    }

    // Manual complete route: POST /api/complete/:jobNumber
    // Intentionally kept: moves a running worker to the Completed column without
    // stopping the underlying process. Useful when the worker finishes but state
    // was not updated automatically (e.g. worker exited silently).
    const completeMatch = pathname.match(/^\/api\/complete\/(.+)$/);
    if (method === 'POST' && completeMatch) {
      return await handleManualComplete(req, res, decodeURIComponent(completeMatch[1]));
    }

    sendError(res, 404, 'Not found');
  } catch (e) {
    console.error('[error] ' + e.message);
    sendError(res, 500, e.message);
  }
});

const PORT = readPort();
server.listen(PORT, () => {
  console.log('Autotask dashboard listening on http://localhost:' + PORT);
  console.log('State file: ' + STATE_PATH);
  startEmailReplyPoller();
  startTeamsCommandPoller();
  startStartableJobsPoller();
});
