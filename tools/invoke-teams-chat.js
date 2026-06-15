

const fs = require("node:fs");
const path = require("node:path");
const { TeamsClient } = require("teams-api");

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = String(argv[index] || "");
    if (!token.startsWith("--")) {
      continue;
    }

    const key = token.slice(2);
    const next = argv[index + 1];
    if (next === undefined || String(next).startsWith("--")) {
      args[key] = "true";
      continue;
    }

    args[key] = String(next);
    index += 1;
  }

  return args;
}

function requiredValue(args, key, message) {
  const value = typeof args[key] === "string" ? args[key].trim() : "";
  if (!value) {
    throw new Error(message);
  }

  return value;
}

function decodeHtmlEntities(value) {
  const entityMap = {
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": "\"",
    "&#39;": "'",
    "&nbsp;": " ",
  };

  return String(value || "").replace(/&(amp|lt|gt|quot|nbsp|#39);/g, match => entityMap[match] || match);
}

function htmlToText(value) {
  const raw = String(value || "");
  if (!raw.includes("<")) {
    return decodeHtmlEntities(raw).replace(/\r\n/g, "\n").trim();
  }

  const withLineBreaks = raw
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|tr|table|section|article|blockquote|h[1-6])>/gi, "\n")
    .replace(/<li\b[^>]*>/gi, "- ")
    .replace(/<\/li>/gi, "\n");

  const withoutTags = withLineBreaks.replace(/<[^>]+>/g, "");
  const decoded = decodeHtmlEntities(withoutTags).replace(/\u00a0/g, " ");
  const normalized = decoded
    .replace(/\r\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .split("\n")
    .map(line => line.trimEnd())
    .join("\n")
    .trim();

  return normalized;
}

function compareMessages(left, right) {
  const leftTime = Date.parse(left && left.originalArrivalTime ? left.originalArrivalTime : "") || 0;
  const rightTime = Date.parse(right && right.originalArrivalTime ? right.originalArrivalTime : "") || 0;
  if (leftTime !== rightTime) {
    return leftTime - rightTime;
  }

  const leftComposeTime = Date.parse(left && left.composeTime ? left.composeTime : "") || 0;
  const rightComposeTime = Date.parse(right && right.composeTime ? right.composeTime : "") || 0;
  if (leftComposeTime !== rightComposeTime) {
    return leftComposeTime - rightComposeTime;
  }

  return String(left && left.id ? left.id : "").localeCompare(String(right && right.id ? right.id : ""), undefined, {
    numeric: true,
    sensitivity: "base",
  });
}

async function getCurrentUserDisplayName(client) {
  try {
    return await client.getCurrentUserDisplayName();
  } catch {
    return "";
  }
}

async function resolveConversation(client, args) {
  const currentUserDisplayName = await getCurrentUserDisplayName(client);
  const explicitConversationId = typeof args["conversation-id"] === "string" ? args["conversation-id"].trim() : "";
  if (explicitConversationId) {
    return {
      conversationId: explicitConversationId,
      targetDescription: `conversation ${explicitConversationId}`,
      currentUserDisplayName,
    };
  }

  const targetMode = String(args["target-mode"] || "self").trim().toLowerCase();
  const target = typeof args.target === "string" ? args.target.trim() : "";

  switch (targetMode) {
    case "self": {
      const selfName = currentUserDisplayName || "self";
      const selfConversation = await client.findOneOnOneConversation(selfName);
      if (!selfConversation) {
        throw new Error("Failed to resolve the current user's self chat.");
      }

      return {
        conversationId: selfConversation.conversationId,
        targetDescription: `self chat (${selfConversation.memberDisplayName || selfName})`,
        currentUserDisplayName,
      };
    }

    case "person": {
      const personName = requiredValue(args, "target", "A Teams chat target is required when target mode is 'person'.");
      const personConversation = await client.findOneOnOneConversation(personName);
      if (!personConversation) {
        throw new Error(`Failed to resolve a 1:1 Teams chat for '${personName}'.`);
      }

      return {
        conversationId: personConversation.conversationId,
        targetDescription: `1:1 chat with ${personConversation.memberDisplayName || personName}`,
        currentUserDisplayName,
      };
    }

    case "chat": {
      const chatName = requiredValue(args, "target", "A Teams chat target is required when target mode is 'chat'.");
      const conversation = await client.findConversation(chatName);
      if (!conversation) {
        throw new Error(`Failed to resolve a Teams conversation matching '${chatName}'.`);
      }

      return {
        conversationId: conversation.id,
        targetDescription: conversation.topic || chatName,
        currentUserDisplayName,
      };
    }

    case "conversation-id": {
      const conversationId = requiredValue(args, "target", "A Teams conversation ID is required when target mode is 'conversation-id'.");
      return {
        conversationId,
        targetDescription: `conversation ${conversationId}`,
        currentUserDisplayName,
      };
    }

    default:
      throw new Error(`Unsupported Teams target mode '${targetMode}'. Expected self, person, chat, or conversation-id.`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const action = requiredValue(args, "action", "Missing required --action.");
  const email = typeof args.email === "string" && args.email.trim() ? args.email.trim() : undefined;
  const client = await TeamsClient.connect({ email, verbose: false });
  const target = await resolveConversation(client, args);

  if (action === "resolve-target") {
    return {
      success: true,
      action,
      conversationId: target.conversationId,
      targetDescription: target.targetDescription,
      currentUserDisplayName: target.currentUserDisplayName,
    };
  }

  if (action === "send-message") {
    const content = requiredValue(args, "content", "Missing required --content for send-message.");
    const format = typeof args.format === "string" && args.format.trim() ? args.format.trim() : "markdown";
    const subject = typeof args.subject === "string" && args.subject.trim() ? args.subject.trim() : undefined;
    const sent = await client.sendMessage(target.conversationId, content, format, [], subject);
    return {
      success: true,
      action,
      conversationId: target.conversationId,
      targetDescription: target.targetDescription,
      currentUserDisplayName: target.currentUserDisplayName,
      sent,
    };
  }

  if (action === "get-messages") {
    const rawLimit = typeof args.limit === "string" ? parseInt(args.limit, 10) : 50;
    const limit = Number.isFinite(rawLimit) && rawLimit > 0 ? rawLimit : 50;
    const pageSize = Math.min(Math.max(limit, 1), 200);
    const messages = await client.getMessages(target.conversationId, {
      limit,
      pageSize,
      maxPages: Math.max(1, Math.ceil(limit / pageSize)),
    });

    return {
      success: true,
      action,
      conversationId: target.conversationId,
      targetDescription: target.targetDescription,
      currentUserDisplayName: target.currentUserDisplayName,
      messages: [...messages]
        .sort(compareMessages)
        .map(message => ({
          id: String(message.id || ""),
          messageType: String(message.messageType || ""),
          senderMri: String(message.senderMri || ""),
          senderDisplayName: String(message.senderDisplayName || ""),
          content: String(message.content || ""),
          textContent: htmlToText(message.content || ""),
          originalArrivalTime: String(message.originalArrivalTime || ""),
          composeTime: String(message.composeTime || ""),
          editTime: message.editTime ? String(message.editTime) : "",
          subject: message.subject ? String(message.subject) : "",
          isDeleted: Boolean(message.isDeleted),
        })),
    };
  }

  if (action === "send-file") {
    const filePath = requiredValue(args, "file", "Missing required --file for send-file.");
    const caption = typeof args.caption === "string" && args.caption.trim() ? args.caption.trim() : "";
    const subject = typeof args.subject === "string" && args.subject.trim() ? args.subject.trim() : undefined;

    const fileData = fs.readFileSync(filePath);
    const fileName = path.basename(filePath);
    const contentParts = [];
    if (caption) {
      contentParts.push({ type: "text", text: caption });
    }
    contentParts.push({ type: "file", data: fileData, fileName });

    const sent = await client.sendMessageWithFiles(target.conversationId, contentParts, "organization", subject);
    return {
      success: true,
      action,
      conversationId: target.conversationId,
      targetDescription: target.targetDescription,
      currentUserDisplayName: target.currentUserDisplayName,
      sent,
    };
  }

  throw new Error(`Unsupported action '${action}'. Expected resolve-target, send-message, send-file, or get-messages.`);
}

main()
  .then(result => {
    process.stdout.write(JSON.stringify(result));
  })
  .catch(error => {
    process.stdout.write(JSON.stringify({
      success: false,
      error: error && error.message ? error.message : String(error),
    }));
    process.exitCode = 1;
  });
