import fs from 'fs';
import path from 'path';
import { readYamlKey, readYamlList, repoRoot, configPaths, resolveMcpEdiprodRoot } from './config.ts';

const mcpRoot = resolveMcpEdiprodRoot();
const { createClient } = await import(`${mcpRoot}/src/apps/cli/auth.ts`);

// Resolve capability codes to Guids via OData, with caching in temp/
async function resolveCapabilityGuids(
  client: any,
  capCodes: string[],
  cacheFilePath: string,
): Promise<Map<string, string>> {
  // Try loading from cache
  if (fs.existsSync(cacheFilePath)) {
    try {
      const cached = JSON.parse(fs.readFileSync(cacheFilePath, 'utf8'));
      const cachedCodes = new Set(Object.keys(cached.codeToGuid || {}));
      const allPresent = capCodes.every(c => cachedCodes.has(c));
      if (allPresent && cached.configCodes && JSON.stringify(cached.configCodes.sort()) === JSON.stringify([...capCodes].sort())) {
        return new Map(Object.entries(cached.codeToGuid));
      }
    } catch { /* stale or corrupt — re-resolve */ }
  }

  // Resolve by querying tasks that use these capabilities
  const codeFilter = capCodes.map(c => `RequiredCapability/G4_Code eq '${c}'`).join(' or ');
  const tasks = await client.queryOdata({
    schema: 'BufferManagement',
    entity: 'BMWorkflowTasks',
    query: {
      $filter: `(${codeFilter}) and P9_Status ne 'CLS' and P9_Status ne 'CAN'`,
      $select: 'P9_G4_RequiredCapability',
      $expand: 'RequiredCapability',
      $top: 200,
    },
  } as any);

  const codeToGuid = new Map<string, string>();
  for (const t of (tasks as any[]) || []) {
    const rc = t.RequiredCapability;
    if (rc?.G4_Code && rc?.G4_PK) {
      codeToGuid.set(String(rc.G4_Code).toUpperCase(), String(rc.G4_PK).toLowerCase());
    }
  }

  // Cache the resolved mapping
  try {
    const payload = { configCodes: capCodes, codeToGuid: Object.fromEntries(codeToGuid), resolvedAt: new Date().toISOString() };
    fs.writeFileSync(cacheFilePath, JSON.stringify(payload, null, 2), 'utf8');
  } catch { /* non-critical */ }

  return codeToGuid;
}

async function main() {
  try {
    const root = repoRoot();

    // Load config.local.yaml (fall back to config.yaml)
    const { local: localCfgPath, base: baseCfgPath, effective: cfgPath } = configPaths();
    let staffCodeRaw = readYamlKey(cfgPath, 'staff_code');
    if (!staffCodeRaw) {
      console.error(JSON.stringify({ error: 'staff_code not found in config.local.yaml or config.yaml' }));
      process.exit(2);
    }
    const staffCode = String(staffCodeRaw).toUpperCase();

    // Load capability codes — prefer config.local.yaml > config.yaml > legacy temp cache
    let capCodes: string[] = [];
    const localCaps = readYamlList(localCfgPath, 'staff_capabilities');
    const baseCaps = readYamlList(baseCfgPath, 'staff_capabilities');
    if (localCaps.length > 0) {
      capCodes = localCaps.map(c => c.toUpperCase());
    } else if (baseCaps.length > 0) {
      capCodes = baseCaps.map(c => c.toUpperCase());
    } else {
      // Legacy fallback: temp/staff-capabilities-{code}.json
      const legacyPath = path.join(root, 'temp', `staff-capabilities-${staffCode}.json`);
      if (fs.existsSync(legacyPath)) {
        try {
          const parsed = JSON.parse(fs.readFileSync(legacyPath, 'utf8'));
          const arr = Array.isArray(parsed) ? parsed : (parsed.capabilities || []);
          capCodes = arr.map((c: any) => String(c).toUpperCase());
        } catch { /* ignore */ }
      }
    }

    const client = await createClient();

    // Resolve capability codes → Guids (cached in temp/)
    const capGuidCachePath = path.join(root, 'temp', 'staff-capability-guids.json');
    let capGuids: string[] = [];
    let codeToGuidMap = new Map<string, string>();
    if (capCodes.length > 0) {
      codeToGuidMap = await resolveCapabilityGuids(client, capCodes, capGuidCachePath);
      capGuids = [...codeToGuidMap.values()];
    }

    // Active Buffer component GUIDs — capability-only tasks (unassigned) are only shown when the
    // workflow's current component is one of these active buffer zones or equivalent gates.
    // Staff-assigned tasks bypass this check (the user owns the task directly regardless of component).
    //
    // Buffer (1 day):              f12656db-77dd-4879-8dff-0da03a60ef15
    // Buffer (3 day):              aa4e7317-dde3-413b-8d78-f8cc32c549de
    // Buffer (9 day):              925a735b-18e1-4a0a-900e-6c1e6489ba23
    // Value Assessment Gate RTR:   3de2de4b-832a-4c5f-afe1-b8d9cc05b47b
    const ACTIVE_BUFFER_COMPONENT_GUIDS = new Set([
      'f12656db-77dd-4879-8dff-0da03a60ef15', // Buffer (1 day)
      'aa4e7317-dde3-413b-8d78-f8cc32c549de', // Buffer (3 day)
      '925a735b-18e1-4a0a-900e-6c1e6489ba23', // Buffer (9 day)
      '3de2de4b-832a-4c5f-afe1-b8d9cc05b47b', // Value Assessment Gate RTR
    ]);

    // Query P9Logs first — server-side filter on Parent navigation property eliminates the need
    // to paginate through thousands of unrelated BMWorkflowTasks records.
    // P9Log.Parent → Odyssey.ProcessTask (BMWorkflowTask entity).
    // Filter: SRT events whose parent task is still ASN and matches staff or (unassigned + capability).
    const staffPart = `Parent/P9_GS_NKAssignedStaffMember eq '${staffCode}'`;
    const capParts = capGuids.map(guid => `Parent/P9_G4_RequiredCapability eq ${guid}`).join(' or ');
    // Capability-matched tasks (unassigned) will be filtered client-side to exclude Queue component
    // (server-side filter on ProcessHeader/FH_FC_CurrentComponent is not supported for this path).
    const capAssignPart = capGuids.length > 0
      ? `(Parent/P9_GS_NKAssignedStaffMember eq '' and (${capParts}))`
      : null;
    const assignFilter = capAssignPart ? `(${staffPart} or ${capAssignPart})` : staffPart;

    // Only consider SRT events posted within the last year.
    // The buffer board continuously re-batches eligible tasks, posting new SRT events each cycle.
    // A task whose most recent SRT event is over a year old is no longer being scheduled by the
    // buffer board and should not appear as startable (e.g. stale tasks from years past).
    const srtCutoff = new Date();
    srtCutoff.setFullYear(srtCutoff.getFullYear() - 1);
    const srtCutoffStr = srtCutoff.toISOString();

    const logsFilter = `SL_SE_NKEvent eq 'SRT' and SL_PostedTimeUtc ge ${srtCutoffStr} and Parent/P9_Status eq 'ASN' and ${assignFilter}`;

    // Expand the parent task + its workflow header to get FH_Status, FH_TaskLowestOpenSequenceNumber,
    // and FH_FC_CurrentComponent.
    // Tasks whose workflow header has FH_Status = 'BLK' (blocked) have not yet been scheduled for
    // active work — they are sitting in the queue waiting for the buffer to be penetrated.
    // These should not appear as startable even though their task record is in ASN state.
    // The FH_TaskLowestOpenSequenceNumber provides a secondary check: when it equals -1 the header
    // has no open task currently scheduled, which also indicates the queue/backlog state.
    const taskExpand = 'Parent($select=P9_PK,P9_ParentID,P9_Description,P9_Type,P9_Sequence,P9_Status,P9_GS_NKAssignedStaffMember,P9_G4_RequiredCapability,P9_FH_ProcessHeader;$expand=ProcessHeader($select=FH_Status,FH_TaskLowestOpenSequenceNumber,FH_FC_CurrentComponent))';

    // Paginate P9Logs ordered by most-recent-first so the first SRT event seen per task is the
    // current buffer cycle's event. This lets us correctly check the SRT=Y/N reference flag.
    const PAGE_SIZE = 50;
    const seenTaskPks = new Set<string>();
    const uniqueTasks: any[] = [];
    let skip = 0;
    while (true) {
      const page = await client.queryOdata<any>({
        schema: 'BufferManagement',
        entity: 'P9Logs',
        query: { $filter: logsFilter, $expand: taskExpand, $select: 'SL_Parent,SL_Reference', $top: PAGE_SIZE, $skip: skip, $orderby: 'SL_PostedTimeUtc desc' },
      } as any);
      const rows = Array.isArray(page) ? page : (page?.value ?? []);
      for (const entry of rows) {
        const t = entry.Parent;
        if (!t?.P9_PK || seenTaskPks.has(t.P9_PK)) continue;
        // The first SRT event per task (due to descending order) is the most recent one for
        // this buffer cycle. Skip tasks where the buffer board has marked them NOT start-ready
        // (SRT=N in the reference) — this mirrors the portal's _get_startable_date() check.
        const srtRef = String(entry.SL_Reference ?? '');
        if (!srtRef.includes('SRT=Y')) continue;
        // Skip tasks from blocked workflows — FH_Status='BLK' means the workflow is sitting in
        // the queue and has not been scheduled for active work yet (buffer not yet penetrated).
        // A secondary indicator is FH_TaskLowestOpenSequenceNumber=-1 (header has no open task).
        const header = t.ProcessHeader;
        const headerStatus = header?.FH_Status ?? '';
        const lowestOpenSeq = header?.FH_TaskLowestOpenSequenceNumber ?? 0;
        if (headerStatus === 'BLK' || lowestOpenSeq === -1) continue;
        // For capability-only tasks (unassigned): only show when the workflow is in an active
        // buffer component (Buffer 1/3/9 day, Value Assessment Gate RTR). Tasks whose workflow
        // is in Queue, Stand By, or other non-buffer components are not yet actionable.
        const isUnassigned = !t.P9_GS_NKAssignedStaffMember || t.P9_GS_NKAssignedStaffMember === '';
        if (isUnassigned) {
          const comp = String(header?.FH_FC_CurrentComponent ?? '').toLowerCase();
          if (!ACTIVE_BUFFER_COMPONENT_GUIDS.has(comp)) continue;
        }
        seenTaskPks.add(t.P9_PK);
        uniqueTasks.push(t);
      }
      if (rows.length < PAGE_SIZE) break;
      skip += PAGE_SIZE;
    }

    // For unassigned review tasks (CB* types), exclude tasks where the current staff member
    // completed the most recent preceding coding task in the same workflow.
    // This prevents a developer from reviewing their own code.
    //
    // Coding task types checked: CDF, CDU, COD, SH0
    // Review task types (CB* prefix): CBC, CBS, CBF, CBR, etc.
    const CODING_TASK_TYPES = ['CDF', 'CDU', 'COD', 'TLT', 'SH0'];
    const unassignedReviewTasks = uniqueTasks.filter(t => {
      const isUnassigned = !t.P9_GS_NKAssignedStaffMember || t.P9_GS_NKAssignedStaffMember === '';
      return isUnassigned && String(t.P9_Type ?? '').toUpperCase().startsWith('CB');
    });

    // Build a map from headerPk → the review tasks belonging to that header
    const headerToReviewTasks = new Map<string, typeof unassignedReviewTasks>();
    for (const t of unassignedReviewTasks) {
      const headerPk = String(t.P9_FH_ProcessHeader ?? '').toLowerCase();
      if (!headerPk) continue;
      if (!headerToReviewTasks.has(headerPk)) headerToReviewTasks.set(headerPk, []);
      headerToReviewTasks.get(headerPk)!.push(t);
    }

    // Fetch the most recent preceding coding task per unique header, then mark review tasks
    // to exclude if that coding task was done by the current staff.
    const ownWorkTaskPks = new Set<string>();
    const codingTypeFilter = CODING_TASK_TYPES.map(t => `P9_Type eq '${t}'`).join(' or ');
    for (const [headerPk, reviewTasks] of headerToReviewTasks) {
      // Use the minimum sequence among review tasks for this header as the ceiling
      const minSeq = Math.min(...reviewTasks.map(t => Number(t.P9_Sequence)));
      const precedingFilter = `P9_FH_ProcessHeader eq ${headerPk} and P9_Status eq 'CLS' and P9_Sequence lt ${minSeq} and (${codingTypeFilter})`;
      const preceding = await client.queryOdata<any>({
        schema: 'BufferManagement',
        entity: 'BMWorkflowTasks',
        query: { $filter: precedingFilter, $select: 'P9_Sequence,P9_GS_NKAssignedStaffMember', $orderby: 'P9_Sequence desc', $top: 1 },
      } as any);
      const precedingTask = Array.isArray(preceding) ? preceding[0] : null;
      if (!precedingTask) continue;
      const precedingStaff = String(precedingTask.P9_GS_NKAssignedStaffMember ?? '').toUpperCase();
      if (precedingStaff === staffCode.toUpperCase()) {
        // Mark ALL review tasks in this workflow as own-work (staff did the preceding coding)
        for (const t of reviewTasks) ownWorkTaskPks.add(t.P9_PK);
      }
    }

    // Remove own-work review tasks from the final set
    const filteredTasks = ownWorkTaskPks.size > 0
      ? uniqueTasks.filter(t => !ownWorkTaskPks.has(t.P9_PK))
      : uniqueTasks;

    const results: any[] = [];
    for (const t of filteredTasks) {
      const assigned = t.P9_GS_NKAssignedStaffMember ? String(t.P9_GS_NKAssignedStaffMember).toUpperCase() : '';
      const capGuid = t.P9_G4_RequiredCapability ? String(t.P9_G4_RequiredCapability).toLowerCase() : '';
      results.push({
        taskPk: t.P9_PK,
        parentJobPk: t.P9_ParentID,
        description: t.P9_Description,
        type: t.P9_Type,
        sequence: t.P9_Sequence,
        status: t.P9_Status,
        capability: capGuid,
        assignedStaff: assigned,
        jobNumber: '',
      });
    }

    // Batch-resolve work item numbers from parent PKs (in chunks to avoid URL length limits)
    const uniqueParentPks = [...new Set(results.map((r) => r.parentJobPk).filter(Boolean))];
    if (uniqueParentPks.length > 0) {
      const pkToNumber = new Map<string, string>();
      const pkToSummary = new Map<string, string>();
      const WI_CHUNK = 20;
      for (let i = 0; i < uniqueParentPks.length; i += WI_CHUNK) {
        const chunk = uniqueParentPks.slice(i, i + WI_CHUNK);
        const pkFilter = chunk.map((pk) => `WKI_PK eq ${pk}`).join(' or ');
        const workitems = await client.queryOdata<any>({
          schema: 'BufferManagement',
          entity: 'WorkItems',
          query: { $filter: pkFilter, $select: 'WKI_PK,WKI_WorkItemNumber,WKI_Summary', $top: chunk.length },
        } as any);
        for (const wi of workitems || []) {
          if (wi.WKI_PK) {
            const pk = String(wi.WKI_PK);
            if (wi.WKI_WorkItemNumber) pkToNumber.set(pk, String(wi.WKI_WorkItemNumber));
            if (wi.WKI_Summary) pkToSummary.set(pk, String(wi.WKI_Summary));
          }
        }
      }

      for (const r of results) {
        r.jobNumber = pkToNumber.get(r.parentJobPk) ?? '';
        r.jobSummary = pkToSummary.get(r.parentJobPk) ?? '';
      }
    }

    console.log(JSON.stringify({ fetchedAt: new Date().toISOString(), staff: staffCode, capabilities: capCodes, capabilityGuids: capGuids, results }, null, 2));
    process.exit(0);
  } catch (err: any) {
    console.error(JSON.stringify({ error: String(err?.message ?? err) }));
    process.exit(1);
  }
}

main();
