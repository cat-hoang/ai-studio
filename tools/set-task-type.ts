import { execSync } from 'child_process';
import { resolveMcpEdiprodRoot } from './config.ts';

const mcpRoot = resolveMcpEdiprodRoot();
const { createClient } = await import(`${mcpRoot}/src/apps/cli/auth.ts`);

function parseArgs(): { jobNumber: string; taskSequence: string; newType: string } {
  const args = process.argv.slice(2);
  let jobNumber = '';
  let taskSequence = '';
  let newType = '';
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--jobNumber') jobNumber = args[++i] ?? '';
    else if (args[i] === '--taskSequence') taskSequence = args[++i] ?? '';
    else if (args[i] === '--newType') newType = args[++i] ?? '';
  }
  return { jobNumber, taskSequence, newType };
}

function lookupTask(jobNumber: string, taskSequence: string): { taskId: string; currentType: string } {
  const ediOutput = execSync(`edi --format jsonl task list ${jobNumber}`, {
    encoding: 'utf8',
    timeout: 30000,
  });
  const seqNum = parseInt(taskSequence, 10);
  const tasks = ediOutput
    .split(/\r?\n/)
    .filter((line) => line.trim().startsWith('{'))
    .map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    })
    .filter(Boolean);

  const matched = tasks.find((t) => {
    const s = t.sequence ?? t.taskSequence ?? t.seq ?? t.Sequence;
    return s != null && parseInt(String(s), 10) === seqNum;
  });

  if (!matched) {
    throw new Error(`Task sequence ${taskSequence} not found in ${jobNumber}.`);
  }

  const taskId = String(matched.id ?? matched.taskId ?? matched.TaskId ?? '');
  if (!taskId) throw new Error(`Could not extract taskId for ${jobNumber} task ${taskSequence}.`);

  // The PAVE API requires the current type as PreviousType for optimistic concurrency
  const currentType = String(matched.type?.code ?? matched.type ?? '');
  if (!currentType) throw new Error(`Could not determine current type for task ${taskId}.`);

  return { taskId, currentType };
}

async function main() {
  const { jobNumber, taskSequence, newType } = parseArgs();

  if (!jobNumber || !taskSequence || !newType) {
    console.log(JSON.stringify({
      success: false,
      error: 'Required: --jobNumber <WI> --taskSequence <seq> --newType <code>',
      usage: 'bun tools/set-task-type.ts --jobNumber WI01056353 --taskSequence 615 --newType SH0',
    }));
    process.exit(1);
  }

  if (newType.length !== 3) {
    console.log(JSON.stringify({ success: false, error: `Task type must be 3 characters, got: "${newType}"` }));
    process.exit(1);
  }

  try {
    const { taskId, currentType } = lookupTask(jobNumber, taskSequence);

    if (currentType.toUpperCase() === newType.toUpperCase()) {
      console.log(JSON.stringify({ success: true, taskId, message: `Task is already type ${currentType} — no change needed.` }));
      process.exit(0);
    }

    const client = await createClient();
    await client.pave.updateTaskType(taskId, currentType, newType);

    console.log(JSON.stringify({
      success: true,
      taskId,
      jobNumber,
      taskSequence,
      previousType: currentType,
      newType,
    }));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.log(JSON.stringify({ success: false, error: msg }));
    process.exit(1);
  }
}

main();
