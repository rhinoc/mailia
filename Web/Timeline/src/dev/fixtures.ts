import type { EntityKind, TimelineEntity, TimelineItem, TimelineState, WorkspaceKind } from "../types";

interface DevFixture {
  id: string;
  label: string;
  entities: TimelineEntity[];
  itemsByEntity: Record<string, TimelineItem[]>;
  state: TimelineState;
}

const accounts = ["gmail", "gmail-imseonwong", "outlook"];

const githubEntity = entity({
  id: 1,
  displayName: "GitHub",
  primaryEmailAddress: "notifications@github.com",
  kind: "service",
  unreadCount: 7,
  latestSubject: "Pull requests, CI, security alerts",
  accountLabel: "gmail",
  workspace: "main"
});

const newsletterEntity = entity({
  id: 2,
  displayName: "The Pragmatic Engineer",
  primaryEmailAddress: "pragmaticengineer@substack.com",
  kind: "newsletter",
  unreadCount: 2,
  latestSubject: "Newsletter",
  accountLabel: "gmail-imseonwong",
  workspace: "main"
});

const personEntity = entity({
  id: 3,
  displayName: "Maya Chen",
  primaryEmailAddress: "maya.chen@example.net",
  kind: "person",
  unreadCount: 1,
  latestSubject: "Direct conversation",
  accountLabel: "gmail",
  workspace: "main"
});

function entity(input: {
  id: number;
  displayName: string;
  primaryEmailAddress: string;
  kind: EntityKind;
  unreadCount: number;
  latestSubject: string;
  accountLabel: string;
  workspace: WorkspaceKind;
}): TimelineEntity {
  return {
    ...input,
    emailAddresses: [input.primaryEmailAddress],
    latestDate: null,
    avatarImageDataURL: null
  };
}

function isoHoursAgo(hours: number) {
  return new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
}

function buildConversation(entity: TimelineEntity, count: number): TimelineItem[] {
  const slug = slugForEntity(entity);
  return Array.from({ length: count }, (_, index) => {
    const outgoing = index % 7 === 4;
    const accountLabel = accounts[index % accounts.length];
    const subject =
      slug === "github"
        ? index % 5 === 0
          ? "[mailia] CI run completed"
          : "Pull request activity"
        : slug === "pragmatic-engineer"
          ? "The Pragmatic Engineer: deep dive"
          : index % 4 === 0
            ? "Planning notes and next steps"
            : "Re: Checking in";

    return {
      id: entity.id * 10_000 + index + 1,
      entityID: entity.id,
      direction: outgoing ? "outgoing" : "incoming",
      subject,
      preview: `Fallback text for ${subject}`,
      html: bodyFor(slug, index, subject),
      date: isoHoursAgo(count - index),
      accountLabel,
      accountEmoji: outgoing ? accountEmoji(accountLabel) : null,
      accountAvatarImageDataURL: null,
      folderLabel: outgoing ? "Sent" : index % 6 === 0 ? "Updates" : "Inbox",
      envelopeID: `${accountLabel}-${slug}-${index + 1000}`,
      isFlagged: index % 9 === 0,
      fromLabel: outgoing ? "Ryan" : entity.displayName,
      toLabel: outgoing ? entity.displayName : "Ryan",
      hasAttachments: index % 13 === 0
    };
  });
}

function slugForEntity(entity: TimelineEntity) {
  switch (entity.id) {
    case githubEntity.id:
      return "github";
    case newsletterEntity.id:
      return "pragmatic-engineer";
    case personEntity.id:
      return "maya";
    default:
      return String(entity.id);
  }
}

function accountEmoji(accountLabel: string) {
  switch (accountLabel) {
    case "gmail":
      return "G";
    case "gmail-imseonwong":
      return "I";
    case "outlook":
      return "O";
    default:
      return null;
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

const githubItems = buildConversation(githubEntity, 92);
const newsletterItems = buildConversation(newsletterEntity, 36);
const personItems = buildConversation(personEntity, 58);
const junkGithubItems = githubItems.slice(-18).map(toJunkItem);
const junkPersonItems = personItems.slice(-22).map(toJunkItem);
const quotedReplyItems = buildQuotedReplyItems();

export const devFixtures: DevFixture[] = [
  {
    id: "main",
    label: "Main timeline",
    entities: withLatestDates([githubEntity, newsletterEntity, personEntity], {
      [githubEntity.id]: githubItems,
      [newsletterEntity.id]: newsletterItems,
      [personEntity.id]: personItems
    }),
    itemsByEntity: {
      [githubEntity.id]: githubItems,
      [newsletterEntity.id]: newsletterItems,
      [personEntity.id]: personItems
    },
    state: stateFor(githubEntity, githubItems, { hasOlderTimeline: true })
  },
  {
    id: "quoted-replies",
    label: "Quoted reply samples",
    entities: withLatestDates(
      [{ ...personEntity, unreadCount: 0, latestSubject: "Quoted reply samples" }],
      { [personEntity.id]: quotedReplyItems }
    ),
    itemsByEntity: {
      [personEntity.id]: quotedReplyItems
    },
    state: stateFor(
      { ...personEntity, unreadCount: 0, latestSubject: "Quoted reply samples" },
      quotedReplyItems,
      {
        displayOptions: {
          hideQuotedReplyText: true,
          hideReplySubjects: true
        }
      }
    )
  },
  {
    id: "junk-review",
    label: "Junk review",
    entities: withLatestDates(
      [
        { ...personEntity, unreadCount: 22, latestSubject: "Potential false-positive Junk sender", workspace: "junk" },
        { ...githubEntity, unreadCount: 18, latestSubject: "Security notifications in Junk", workspace: "junk" }
      ],
      {
        [personEntity.id]: junkPersonItems,
        [githubEntity.id]: junkGithubItems
      }
    ),
    itemsByEntity: {
      [personEntity.id]: junkPersonItems,
      [githubEntity.id]: junkGithubItems
    },
    state: stateFor(
      { ...personEntity, unreadCount: 22, latestSubject: "Potential false-positive Junk sender", workspace: "junk" },
      junkPersonItems
    )
  }
];

function stateFor(
  selectedEntity: TimelineEntity,
  items: TimelineItem[],
  options: {
    hasOlderTimeline?: boolean;
    displayOptions?: Partial<TimelineState["displayOptions"]>;
  } = {}
): TimelineState {
  const entityWithLatestDate = {
    ...selectedEntity,
    latestDate: items.at(-1)?.date ?? selectedEntity.latestDate ?? null
  };

  return {
    entity: entityWithLatestDate,
    items,
    isLoadingTimeline: false,
    isLoadingOlderTimeline: false,
    isLoadingNewerTimeline: false,
    hasOlderTimeline: options.hasOlderTimeline ?? false,
    hasNewerTimeline: false,
    bodyStates: Object.fromEntries(
      items
        .filter((item) => !item.html && item.preview)
        .map((item) => [
          String(item.id),
          { status: "loaded", body: { html: null, text: item.preview } }
        ])
    ),
    attachmentDownloadStates: {},
    replySendState: { status: "idle" },
    sendAccounts: [],
    selectedSendAccountKey: null,
    scrollAnchor: { id: items.at(-1)?.id ?? entityWithLatestDate.id, edge: "bottom", generation: 0 },
    displayOptions: {
      bodyDisplayMode: "html",
      loadRemoteContent: false,
      showTimelineAvatars: true,
      showOwnTimelineAvatars: true,
      hideQuotedReplyText: false,
      hideReplySubjects: false,
      ...options.displayOptions
    },
    windowState: {
      bottomOverlayHeight: 0
    }
  };
}

function withLatestDates(
  entities: TimelineEntity[],
  itemsByEntity: Record<string, TimelineItem[]>
) {
  return entities.map((candidate) => ({
    ...candidate,
    latestDate: itemsByEntity[String(candidate.id)]?.at(-1)?.date ?? null
  }));
}

function toJunkItem(item: TimelineItem): TimelineItem {
  return {
    ...item,
    folderLabel: "Junk",
    isFlagged: false
  };
}

function buildQuotedReplyItems(): TimelineItem[] {
  const baseItem = buildConversation(personEntity, 2)[0];
  const textReply: TimelineItem = {
    ...baseItem,
    id: 90_001,
    envelopeID: "gmail-maya-quoted-text",
    accountLabel: "gmail",
    accountEmoji: "G",
    folderLabel: "[Gmail]/Sent Mail",
    subject: "Re: Plain quoted reply",
    preview: "I will handle this today.",
    date: isoHoursAgo(2),
    direction: "outgoing",
    html: null
  };
  const htmlReply: TimelineItem = {
    ...baseItem,
    id: 90_002,
    envelopeID: "outlook-maya-quoted-html",
    accountLabel: "outlook",
    accountEmoji: "O",
    folderLabel: "Sent",
    subject: "Re: Outlook quoted reply",
    preview: "I cleaned up the draft and sent the latest version.",
    date: isoHoursAgo(1),
    direction: "outgoing",
    html: `
      <div class="elementToProof">I cleaned up the draft and sent the latest version.</div>
      <div id="appendonsend"></div>
      <hr>
      <div id="divRplyFwdMsg" dir="ltr">
        <b>发件人:</b> Maya Chen<br>
        <b>发送时间:</b> Sunday, May 31, 2026 16:36<br>
        <b>收件人:</b> Ryan<br>
        <b>主题:</b> Outlook quoted reply
      </div>
      <div>
        <div dir="ltr">Previous message body that should not appear when quote hiding is enabled.</div>
      </div>
    `
  };

  return [textReply, htmlReply];
}
