import type { TimelineMessage, TimelineState } from "../types";

interface DevFixture {
  id: string;
  label: string;
  state: TimelineState;
  messagesByEntity: Record<string, TimelineMessage[]>;
}

const accounts = ["gmail", "gmail-imseonwong", "outlook"];

function address(displayName: string, emailAddress: string) {
  return { displayName, emailAddress };
}

function isoHoursAgo(hours: number) {
  return new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
}

function buildConversation(entityID: string, count: number): TimelineMessage[] {
  return Array.from({ length: count }, (_, index) => {
    const outgoing = index % 7 === 4;
    const accountKey = accounts[index % accounts.length];
    const subject =
      entityID === "github"
        ? index % 5 === 0
          ? "[mailia] CI run completed"
          : "Pull request activity"
        : entityID === "pragmatic-engineer"
          ? "The Pragmatic Engineer: deep dive"
          : index % 4 === 0
            ? "Planning notes and next steps"
            : "Re: Checking in";

    return {
      messageID: `${entityID}-${index + 1}`,
      accountKey,
      folderName: outgoing ? "Sent" : index % 6 === 0 ? "Updates" : "Inbox",
      folderRole: outgoing ? "sent" : "normal",
      himalayaEnvelopeID: `${accountKey}-${entityID}-${index + 1000}`,
      flags: index % 9 === 0 ? ["Seen", "Flagged"] : index % 3 === 0 ? ["Seen"] : [],
      subject,
      from: outgoing
        ? address("Ryan", "ryan@example.com")
        : entityID === "github"
          ? address("GitHub", "notifications@github.com")
          : entityID === "pragmatic-engineer"
            ? address("The Pragmatic Engineer", "pragmaticengineer@substack.com")
            : address("Maya Chen", "maya.chen@example.net"),
      to: outgoing
        ? [
            entityID === "github"
              ? address("GitHub", "notifications@github.com")
              : entityID === "pragmatic-engineer"
                ? address("The Pragmatic Engineer", "pragmaticengineer@substack.com")
                : address("Maya Chen", "maya.chen@example.net")
          ]
        : [address("Ryan", "ryan@example.com")],
      cc: index % 11 === 0 ? [address("Ops", "ops@example.com")] : [],
      messageDate: isoHoursAgo(count - index),
      direction: outgoing ? "outgoing" : "incoming",
      hasAttachments: index % 13 === 0,
      sanitizedHTML: bodyFor(entityID, index, subject),
      textFallback: `Fallback text for ${subject}`,
      avatarSeed: `${entityID}-${entityName(entityID)}`,
      avatarName: entityName(entityID)
    };
  });
}

function entityName(entityID: string) {
  switch (entityID) {
    case "github":
      return "GitHub";
    case "pragmatic-engineer":
      return "The Pragmatic Engineer";
    case "maya":
      return "Maya Chen";
    default:
      return entityID;
  }
}

function bodyFor(entityID: string, index: number, subject: string) {
  if (entityID === "github" && index % 5 === 0) {
    return `
      <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;">
        <h2 style="margin: 0 0 12px;">${subject}</h2>
        <p>The workflow finished with a green status on branch <strong>main</strong>.</p>
        <table style="border-collapse: collapse; min-width: 920px; margin-top: 16px;">
          <tr>
            <th style="text-align: left; border: 1px solid #ccd0d5; padding: 8px;">Job</th>
            <th style="text-align: left; border: 1px solid #ccd0d5; padding: 8px;">Runner</th>
            <th style="text-align: left; border: 1px solid #ccd0d5; padding: 8px;">Duration</th>
            <th style="text-align: left; border: 1px solid #ccd0d5; padding: 8px;">Artifacts</th>
          </tr>
          <tr>
            <td style="border: 1px solid #ccd0d5; padding: 8px;">swift-test</td>
            <td style="border: 1px solid #ccd0d5; padding: 8px;">macos-15</td>
            <td style="border: 1px solid #ccd0d5; padding: 8px;">4m 12s</td>
            <td style="border: 1px solid #ccd0d5; padding: 8px;">coverage.xml, test.log, package.resolved</td>
          </tr>
        </table>
      </div>
    `;
  }

  if (entityID === "pragmatic-engineer") {
    return `
      <article style="font-family: Georgia, serif; line-height: 1.55; max-width: 720px;">
        <h1 style="font-size: 28px; margin: 0 0 12px;">Systems thinking for product engineers</h1>
        <p>This issue looks at why high-leverage teams keep operational context close to product decisions.</p>
        <p>${"Long-form email body paragraph. ".repeat(85)}</p>
      </article>
    `;
  }

  return `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.45;">
      <p>Here are the notes from the latest thread.</p>
      <ul>
        <li>Timeline should read like a durable conversation history.</li>
        <li>Account and folder source metadata should stay visible.</li>
        <li>Long HTML bodies should remain scrollable inside the message.</li>
      </ul>
      <p>${"Additional context line. ".repeat(index % 8 === 0 ? 120 : 6)}</p>
    </div>
  `;
}

const githubMessages = buildConversation("github", 92);
const newsletterMessages = buildConversation("pragmatic-engineer", 36);
const personMessages = buildConversation("maya", 58);
const junkGithubMessages = githubMessages.slice(-18).map(toJunkMessage);
const junkPersonMessages = personMessages.slice(-22).map(toJunkMessage);

export const devFixtures: DevFixture[] = [
  {
    id: "main",
    label: "Main timeline",
    messagesByEntity: {
      github: githubMessages,
      "pragmatic-engineer": newsletterMessages,
      maya: personMessages
    },
    state: {
      workspace: "main",
      selectedEntityID: "github",
      isLoading: false,
      error: null,
      syncStatus: "Fixture data loaded",
      hasOlderMessages: true,
      anchoredToBottom: true,
      bodyDisplayMode: "html",
      entities: [
        {
          id: "github",
          name: "GitHub",
          kind: "service",
          primaryAddress: "notifications@github.com",
          detail: "Pull requests, CI, security alerts",
          messageCount: githubMessages.length,
          unreadCount: 7,
          lastMessageAt: githubMessages.at(-1)?.messageDate,
          sourceAccounts: ["gmail", "outlook"]
        },
        {
          id: "pragmatic-engineer",
          name: "The Pragmatic Engineer",
          kind: "newsletter",
          primaryAddress: "pragmaticengineer@substack.com",
          detail: "Newsletter",
          messageCount: newsletterMessages.length,
          unreadCount: 2,
          lastMessageAt: newsletterMessages.at(-1)?.messageDate,
          sourceAccounts: ["gmail-imseonwong"]
        },
        {
          id: "maya",
          name: "Maya Chen",
          kind: "person",
          primaryAddress: "maya.chen@example.net",
          detail: "Direct conversation",
          messageCount: personMessages.length,
          unreadCount: 1,
          lastMessageAt: personMessages.at(-1)?.messageDate,
          sourceAccounts: ["gmail", "gmail-imseonwong"]
        }
      ],
      messages: githubMessages
    }
  },
  {
    id: "junk-review",
    label: "Junk review",
    messagesByEntity: {
      github: junkGithubMessages,
      maya: junkPersonMessages
    },
    state: {
      workspace: "junk",
      selectedEntityID: "maya",
      isLoading: false,
      error: null,
      syncStatus: "Junk fixture data loaded",
      hasOlderMessages: false,
      anchoredToBottom: true,
      bodyDisplayMode: "html",
      entities: [
        {
          id: "maya",
          name: "Maya Chen",
          kind: "person",
          primaryAddress: "maya.chen@example.net",
          detail: "Potential false-positive Junk sender",
          messageCount: 22,
          unreadCount: 22,
          lastMessageAt: personMessages.at(-1)?.messageDate,
          sourceAccounts: ["gmail"]
        },
        {
          id: "github",
          name: "GitHub",
          kind: "service",
          primaryAddress: "notifications@github.com",
          detail: "Security notifications in Junk",
          messageCount: 18,
          unreadCount: 18,
          lastMessageAt: githubMessages.at(-1)?.messageDate,
          sourceAccounts: ["outlook"]
        }
      ],
      messages: junkPersonMessages
    }
  }
];

function toJunkMessage(message: TimelineMessage): TimelineMessage {
  return {
    ...message,
    folderName: "Junk",
    folderRole: "junk",
    flags: message.flags.filter((flag) => flag !== "Seen")
  };
}
