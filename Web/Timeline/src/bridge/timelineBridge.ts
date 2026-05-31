import { devFixtures } from "../dev/fixtures";
import type {
  TimelineEntity,
  TimelineEntityOption,
  TimelineItem,
  TimelineState
} from "../types";

type TimelineEntityID = TimelineEntity["id"];
type TimelineMessageID = TimelineItem["id"];

export type TimelineInboundEvent =
  | { type: "state"; state: TimelineState }
  | { type: "error"; message: string };

export type TimelineOutboundEvent =
  | { type: "ready" }
  | { type: "refreshEntities" }
  | { type: "selectEntity"; entityID: TimelineEntityID }
  | {
      type: "requestOlderMessages";
      entityID: TimelineEntityID;
      beforeMessageID?: TimelineMessageID;
    }
  | {
      type: "requestBody";
      messageID: TimelineMessageID;
      bodyPriority?: number;
      accountKey: string;
      folderName?: string | null;
      himalayaEnvelopeID?: string | null;
    }
  | { type: "downloadAttachments"; messageID: TimelineMessageID }
  | { type: "setScrolledToBottom"; atBottom: boolean };

export interface TimelineBridge {
  mode: "native" | "dev";
  subscribe(listener: (event: TimelineInboundEvent) => void): () => void;
  send(event: TimelineOutboundEvent): void;
}

export interface DevFixtureSummary {
  id: string;
  label: string;
}

export interface DevTimelineBridge extends TimelineBridge {
  mode: "dev";
  getFixtures(): DevFixtureSummary[];
  getFixtureID(): string;
  getEntities(): TimelineEntityOption[];
  setFixture(fixtureID: string): void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        mailiaTimeline?: {
          postMessage(message: TimelineOutboundEvent): void;
        };
      };
    };
    mailiaTimeline?: {
      receive(event: TimelineInboundEvent): void;
      receiveState(state: TimelineState): void;
    };
  }
}

type Listener = (event: TimelineInboundEvent) => void;

class NativeTimelineBridge implements TimelineBridge {
  readonly mode = "native";
  private listeners = new Set<Listener>();

  constructor(
    private readonly handler: {
      postMessage(message: unknown): void;
    }
  ) {
    window.mailiaTimeline = {
      receive: (event) => {
        this.emit(event);
      },
      receiveState: (state) => {
        this.emit({ type: "state", state });
      }
    };
  }

  subscribe(listener: Listener) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  send(event: TimelineOutboundEvent) {
    const envelope = toNativeEnvelope(event);
    if (envelope) {
      this.handler.postMessage(envelope);
    }
  }

  private emit(event: TimelineInboundEvent) {
    for (const listener of this.listeners) {
      listener(event);
    }
  }
}

function toNativeEnvelope(event: TimelineOutboundEvent) {
  switch (event.type) {
    case "ready":
      return { type: "ready" };
    case "requestOlderMessages":
      return { type: "requestOlder" };
    case "requestBody":
      return {
        type: "requestBody",
        payload: { messageID: event.messageID, bodyPriority: event.bodyPriority }
      };
    case "downloadAttachments":
      return { type: "downloadAttachments", payload: { messageID: event.messageID } };
    case "refreshEntities":
    case "selectEntity":
    case "setScrolledToBottom":
      return null;
  }
}

let generatedDevItemID = -1;

class InMemoryDevTimelineBridge implements DevTimelineBridge {
  readonly mode = "dev";
  private listeners = new Set<Listener>();
  private fixtureID = getInitialDevFixture().id;
  private state: TimelineState = structuredClone(getInitialDevFixture().state);

  subscribe(listener: Listener) {
    this.listeners.add(listener);
    queueMicrotask(() => listener({ type: "state", state: this.state }));
    return () => {
      this.listeners.delete(listener);
    };
  }

  send(event: TimelineOutboundEvent) {
    switch (event.type) {
      case "ready":
        this.emit({ type: "state", state: this.state });
        break;
      case "refreshEntities":
        this.refreshEntities();
        break;
      case "selectEntity":
        this.selectEntity(event.entityID);
        break;
      case "requestOlderMessages":
        this.prependOlderMessages();
        break;
      case "requestBody":
      case "setScrolledToBottom":
        break;
      case "downloadAttachments":
        this.downloadAttachments(event.messageID);
        break;
    }
  }

  getFixtures() {
    return devFixtures.map(({ id, label }) => ({ id, label }));
  }

  getFixtureID() {
    return this.fixtureID;
  }

  getEntities() {
    const fixture = this.currentFixture();
    return fixture.entities.map((entity) =>
      toEntityOption(entity, fixture.itemsByEntity[String(entity.id)] ?? [], {
        hideQuotedReplyText: this.state.displayOptions.hideQuotedReplyText,
        hideReplySubjects: this.state.displayOptions.hideReplySubjects
      })
    );
  }

  setFixture(fixtureID: string) {
    const fixture = devFixtures.find((candidate) => candidate.id === fixtureID);
    if (!fixture) return;

    this.fixtureID = fixtureID;
    this.state = structuredClone(fixture.state);
    this.emit({ type: "state", state: this.state });
  }

  private selectEntity(entityID: TimelineEntityID) {
    const fixture = this.currentFixture();
    const selected = fixture.entities.find((entity) => sameID(entity.id, entityID));
    if (!selected) return;

    this.state = {
      ...this.state,
      entity: selected,
      items: fixture.itemsByEntity[String(selected.id)] ?? [],
      isLoadingTimeline: false,
      isLoadingOlderTimeline: false,
      isLoadingNewerTimeline: false,
      scrollAnchor: { id: selected.id, edge: "bottom", generation: Date.now() }
    };

    this.emit({ type: "state", state: this.state });
  }

  private refreshEntities() {
    this.state = {
      ...this.state,
      isLoadingTimeline: true
    };
    this.emit({ type: "state", state: this.state });

    window.setTimeout(() => {
      this.state = {
        ...this.state,
        entity: this.state.entity
          ? {
              ...this.state.entity,
              unreadCount: this.state.entity.unreadCount + 1,
              latestSubject: "Refreshed just now",
              latestBodyPreview: null,
              latestDate: new Date().toISOString()
            }
          : null,
        isLoadingTimeline: false
      };
      this.emit({ type: "state", state: this.state });
    }, 700);
  }

  private prependOlderMessages() {
    const firstItem = this.state.items[0];
    if (!firstItem) return;

    const olderItems = Array.from({ length: 12 }, (_, index) => {
      const offset = 12 - index;
      const date = new Date(Date.now() - (offset + 125) * 60 * 60 * 1000);
      return {
        ...firstItem,
        id: generatedDevItemID--,
        subject: `Older context ${offset}: ${firstItem.subject || "Message"}`,
        preview: "This is an older fixture message generated by the dev bridge.",
        html: `<p>This is an older fixture message generated by the dev bridge.</p><p>It exercises prepend behavior without requiring Swift.</p>`,
        date: date.toISOString()
      };
    });

    this.state = {
      ...this.state,
      items: [...olderItems, ...this.state.items],
      isLoadingOlderTimeline: false,
      hasOlderTimeline: this.state.items.length < 180
    };
    this.emit({ type: "state", state: this.state });
  }

  private emit(event: TimelineInboundEvent) {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  private downloadAttachments(messageID: TimelineMessageID) {
    const key = String(messageID);
    this.state = {
      ...this.state,
      attachmentDownloadStates: {
        ...this.state.attachmentDownloadStates,
        [key]: { status: "downloading" }
      }
    };
    this.emit({ type: "state", state: this.state });

    window.setTimeout(() => {
      this.state = {
        ...this.state,
        attachmentDownloadStates: {
          ...this.state.attachmentDownloadStates,
          [key]: {
            status: "downloaded",
            result: {
              directoryPath: "~/Downloads",
              fileNames: ["proposal.pdf", "invoice.csv"]
            }
          }
        }
      };
      this.emit({ type: "state", state: this.state });
    }, 700);
  }

  private currentFixture() {
    return devFixtures.find((fixture) => fixture.id === this.fixtureID) ?? getInitialDevFixture();
  }
}

function sameID(left: TimelineEntityID, right: TimelineEntityID) {
  return String(left) === String(right);
}

function toEntityOption(
  entity: TimelineEntity,
  items: TimelineItem[],
  options: { hideQuotedReplyText: boolean; hideReplySubjects: boolean }
): TimelineEntityOption {
  const latestItem = items.at(-1);
  return {
    id: entity.id,
    name: entity.displayName,
    kind: normalizeEntityKind(entity.kind),
    primaryAddress: entity.primaryEmailAddress ?? null,
    detail: entityListPreview(entity, latestItem, options),
    unreadCount: entity.unreadCount,
    lastMessageAt: entity.latestDate ?? latestItem?.date ?? null,
    avatarImageDataURL: entity.avatarImageDataURL ?? null
  };
}

function entityListPreview(
  entity: TimelineEntity,
  latestItem: TimelineItem | undefined,
  options: { hideQuotedReplyText: boolean; hideReplySubjects: boolean }
) {
  const subject = entity.latestSubject;
  if (options.hideReplySubjects && isReplySubject(subject)) {
    const bodyPreview = entity.latestBodyPreview ?? latestItem?.preview ?? "";
    const visiblePreview = options.hideQuotedReplyText
      ? stripTrailingQuotedReplyText(bodyPreview)
      : bodyPreview;
    const preview = compactPreviewText(visiblePreview);
    if (preview) return preview;
  }

  return subject || entity.primaryEmailAddress || entity.kind;
}

function isReplySubject(subject: string) {
  return /^\s*(re|回复|答复|回覆)\s*[:：]/i.test(subject);
}

function stripTrailingQuotedReplyText(text: string) {
  const normalized = text
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n");
  const lines = normalized.split("\n");

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (!/^On\s+.+\swrote:\s*$/i.test(lines[index].trim())) continue;

    const followingLines = lines.slice(index + 1);
    const nonBlankFollowingLines = followingLines.filter((line) => line.trim() !== "");
    if (nonBlankFollowingLines.length === 0) continue;
    if (!nonBlankFollowingLines.every((line) => line.trimStart().startsWith(">"))) continue;

    const keptLines = lines.slice(0, index);
    while (keptLines.length > 0 && keptLines.at(-1)?.trim() === "") {
      keptLines.pop();
    }
    return keptLines.join("\n");
  }

  return text;
}

function compactPreviewText(text: string) {
  return text.replace(/\s+/g, " ").trim();
}

function normalizeEntityKind(value: string): TimelineEntityOption["kind"] {
  switch (value) {
    case "person":
    case "organization":
    case "service":
    case "newsletter":
    case "unknown":
      return value;
    default:
      return "unknown";
  }
}

function getInitialDevFixture() {
  const fixture = devFixtures[0];
  if (!fixture) {
    throw new Error("Timeline dev bridge requires at least one fixture.");
  }
  return fixture;
}

export function createTimelineBridge(): TimelineBridge {
  const nativeHandler = window.webkit?.messageHandlers?.mailiaTimeline;
  if (nativeHandler) {
    return new NativeTimelineBridge(nativeHandler);
  }

  return new InMemoryDevTimelineBridge();
}

export function isDevTimelineBridge(
  bridge: TimelineBridge
): bridge is DevTimelineBridge {
  return bridge.mode === "dev";
}
