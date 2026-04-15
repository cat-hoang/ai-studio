import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { resolveMcpEdiprodRoot } from './config.ts';

const mcpRoot = resolveMcpEdiprodRoot();
const { createClient } = await import(`${mcpRoot}/src/apps/cli/auth.ts`);
const { htmlToMarkdown } = await import(`${mcpRoot}/src/packages/utils/text.ts`);

function parseArgs(): { action: string; jobNumber: string; taskSequence: string; content?: string } {
  const args = process.argv.slice(2);
  let action = '';
  let jobNumber = '';
  let taskSequence = '';
  let content: string | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--action') action = args[++i] ?? '';
    else if (args[i] === '--jobNumber') jobNumber = args[++i] ?? '';
    else if (args[i] === '--taskSequence') taskSequence = args[++i] ?? '';
    else if (args[i] === '--content') content = args[++i] ?? '';
    else if (args[i] === '--content-file') {
      const filePath = args[++i] ?? '';
      content = fs.readFileSync(filePath, 'utf8');
    }
  }
  return { action, jobNumber, taskSequence, content };
}

function lookupTaskId(jobNumber: string, taskSequence: string): string {
  const ediOutput = execSync(`edi --format jsonl task list ${jobNumber}`, {
    encoding: 'utf8',
    timeout: 30000,
  });
  const seqNum = parseInt(taskSequence, 10);
  const tasks = ediOutput
    .split(/\r?\n/)
    .filter((line) => line.trim().startsWith('{'))
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);

  const matched = tasks.find((t) => {
    const s = t.sequence ?? t.taskSequence ?? t.seq ?? t.Sequence;
    return s != null && parseInt(String(s), 10) === seqNum;
  });

  if (!matched) {
    throw new Error(
      `Task sequence ${taskSequence} not found in ${jobNumber}. The task may not exist yet in ediProd.`,
    );
  }

  const taskId = String(matched.id ?? matched.taskId ?? matched.TaskId ?? '');
  if (!taskId) {
    throw new Error(`Could not extract taskId for ${jobNumber} task ${taskSequence}.`);
  }
  return taskId;
}

async function main() {
  const { action, jobNumber, taskSequence, content } = parseArgs();

  if (!action || !jobNumber || !taskSequence) {
    console.log(
      JSON.stringify({ success: false, error: 'Required: --action get|set --jobNumber --taskSequence' }),
    );
    process.exit(1);
  }

  try {
    const taskId = lookupTaskId(jobNumber, taskSequence);
    const client = await createClient();

    if (action === 'get') {
      const notesResponse = await client.pave.getTaskNotes(taskId);
      let notesHtml = notesResponse?.content ?? '';

      // Detect trailing <br> tags before the final container close (these represent blank lines)
      const brTrailingMatch = notesHtml.match(/(?:<br\s*\/?>(?:\s|\r|\n)*)+(?=<\/[\w:-]+>[\s\r\n]*$)/i);
      const trailingBrCount = brTrailingMatch ? (brTrailingMatch[0].match(/<br\s*\/?/gi) || []).length : 0;

      // Detect trailing spaces (including NBSP entity or actual NBSP char) before the closing tag
      const wsMatch = notesHtml.match(/((?:&nbsp;|\u00A0|[ \t])+)(?=<\/[\w:-]+>[\s\r\n]*$)/i);
      let trailingWsCount = 0;
      if (wsMatch) {
        const s = wsMatch[1];
        // Count &nbsp; occurrences
        const nbspMatches = s.match(/&nbsp;/gi) || [];
        trailingWsCount += nbspMatches.length;
        // Count actual spaces/tabs and NBSP chars
        for (let ch of s) {
          if (ch === ' ' || ch === '\t' || ch === '\u00A0') trailingWsCount++;
        }
      }

      // Remove the detected trailing HTML fragments before conversion to markdown
      if (brTrailingMatch) notesHtml = notesHtml.replace(brTrailingMatch[0], '');
      if (wsMatch) notesHtml = notesHtml.replace(wsMatch[0], '');

      let markdown = htmlToMarkdown(notesHtml);

      if (trailingWsCount > 0 || trailingBrCount > 0) {
        // Normalize end of markdown then re-append spaces (first) and newlines (second)
        markdown = markdown.replace(/[ \t\r\n]+$/, '');
        markdown = markdown + ' '.repeat(trailingWsCount) + '\n'.repeat(trailingBrCount);
      }

      console.log(JSON.stringify({ success: true, taskId, notes: markdown }));
    } else if (action === 'set') {
      if (content === undefined) {
        console.log(JSON.stringify({ success: false, error: '--content is required for set action' }));
        process.exit(1);
      }

      const original = content;
      // Count trailing newlines (\n) and trailing spaces/tabs on the final line
      let i = original.length - 1;
      let trailingNlCount = 0;
      while (i >= 0 && (original[i] === '\n' || original[i] === '\r')) {
        if (original[i] === '\n') trailingNlCount++;
        i--;
      }
      let trailingWsCount = 0;
      while (i >= 0 && (original[i] === ' ' || original[i] === '\t')) {
        trailingWsCount++;
        i--;
      }

      let encoded = original;
      if (trailingWsCount > 0 || trailingNlCount > 0) {
        encoded = original + `<span data-ratatosk-trailing-ws="${trailingWsCount}" data-ratatosk-trailing-nl="${trailingNlCount}"></span>`;
      }

      const current = await client.pave.getTaskNotes(taskId);
      if (!current?.hash) {
        console.log(JSON.stringify({ success: false, error: `Cannot update notes for ${taskId}: missing hash.` }));
        process.exit(1);
      }
      await client.pave.updateTaskNotes(taskId, {
        previousHash: current.hash,
        newNotes: encoded,
      });
      console.log(JSON.stringify({ success: true, taskId }));
    } else {
      console.log(JSON.stringify({ success: false, error: `Unknown action: ${action}. Use get or set.` }));
      process.exit(1);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.log(JSON.stringify({ success: false, error: msg }));
    process.exit(1);
  }
}

main();
