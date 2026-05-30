import { devFixtures } from "../dev/fixtures";
import type { TimelineEntity, TimelineMessage, TimelineState } from "../types";

export type TimelineInboundEvent =
  | { type: "state"; state: TimelineState }
  | {
      type: "messagesChanged";
      entityID: string;
      messages: TimelineMessage[];
      hasOlderMessages?: boolean;
      anchoredToBottom?: boolean;
    }
  | {
      type: "bodyLoaded";
      messageID: TimelineMessage["messageID"];
      sanitizedHTML?: string | null;
      textFallback?: string | null;
    }
  | { type: "error"; message: string };

export type TimelineOutboundEvent =
  | { type: "ready" }
  | { type: "selectEntity"; entityID: string }
  | {
      type: "requestOlderMessages";
      entityID: string;
      beforeMessageID?: TimelineMessage["messageID"];
    }
  | {
      type: "requestBody";
      messageID: TimelineMessage["messageID"];
      accountKey: string;
      folderName?: string | null;
      himalayaEnvelopeID?: string | null;
    }
  | { type: "downloadAttachments"; messageID: TimelineMessage["messageID"] }
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
      receiveState(state: NativeTimelineState): void;
    };
  }
}

type Listener = (event: TimelineInboundEvent) => void;

interface NativeTimelineState {
  entity: NativeTimelineEntity | null;
  items: NativeTimelineItem[];
  isLoadingTimeline: boolean;
  isLoadingOlderTimeline: boolean;
  isLoadingNewerTimeline: boolean;
  hasOlderTimeline: boolean;
  hasNewerTimeline: boolean;
  bodyStates: Record<string, NativeBodyState>;
  attachmentDownloadStates: Record<string, NativeAttachmentState>;
  scrollAnchor?: { id: number | string; edge: "top" | "bottom"; generation: number } | null;
  bodyDisplayMode?: string | null;
}

interface NativeTimelineEntity {
  id: number | string;
  displayName: string;
  primaryEmailAddress?: string | null;
  kind: string;
  unreadCount: number;
  latestSubject: string;
  latestDate?: string | null;
  accountLabel: string;
  workspace: string;
  avatarImageDataURL?: string | null;
}

interface NativeTimelineItem {
  id: number | string;
  entityID: number | string;
  direction: "incoming" | "outgoing" | string;
  subject: string;
  preview: string;
  html?: string | null;
  date?: string | null;
  accountLabel: string;
  folderLabel: string;
  envelopeID: string;
  isFlagged: boolean;
  fromLabel: string;
  toLabel: string;
  hasAttachments: boolean;
}

type NativeBodyState =
  | { status: "notRequested" }
  | { status: "loading" }
  | { status: "loaded"; body: { html?: string | null; text?: string | null } }
  | { status: "failed"; message: string };

type NativeAttachmentState =
  | { status: "idle" }
  | { status: "downloading" }
  | { status: "downloaded"; result: { directoryPath: string; fileNames: string[] } }
  | { status: "failed"; message: string };

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
        console.warn("[MailiaTimelineWebDebug] native receiveState", {
          entityID: state.entity?.id ?? null,
          entityName: state.entity?.displayName ?? null,
          itemCount: state.items.length,
          firstItemID: state.items[0]?.id ?? null,
          lastItemID: state.items.at(-1)?.id ?? null,
          loading: state.isLoadingTimeline,
          anchor: state.scrollAnchor ?? null,
          bodyStateCount: Object.keys(state.bodyStates).length
        });
        this.emit({ type: "state", state: adaptNativeState(state) });
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
      return { type: "requestBody", payload: { messageID: event.messageID } };
    case "downloadAttachments":
      return { type: "downloadAttachments", payload: { messageID: event.messageID } };
    case "selectEntity":
    case "setScrolledToBottom":
      return null;
  }
}

function adaptNativeState(nativeState: NativeTimelineState): TimelineState {
  const entity = nativeState.entity;
  const selectedEntityID = entity ? String(entity.id) : null;
  return {
    workspace: normalizeWorkspace(entity?.workspace),
    entities: entity
      ? [
          {
            id: selectedEntityID ?? "",
            name: entity.displayName,
            kind: normalizeEntityKind(entity.kind),
            primaryAddress: entity.primaryEmailAddress,
            detail: entity.latestSubject,
            messageCount: nativeState.items.length,
            unreadCount: entity.unreadCount,
            lastMessageAt: entity.latestDate ?? null,
            sourceAccounts: [entity.accountLabel].filter(Boolean)
          }
        ]
      : [],
    selectedEntityID,
    messages: nativeState.items.map((item) => adaptNativeMessage(item, nativeState)),
    isLoading: nativeState.isLoadingTimeline,
    error: null,
    syncStatus: entity ? `${entity.displayName} · ${nativeState.items.length} messages` : null,
    hasOlderMessages: nativeState.hasOlderTimeline,
    anchoredToBottom: nativeState.scrollAnchor?.edge === "bottom",
    bodyDisplayMode: normalizeBodyDisplayMode(nativeState.bodyDisplayMode),
    attachmentDownloadStates: nativeState.attachmentDownloadStates
  };
}

function normalizeBodyDisplayMode(value?: string | null): TimelineState["bodyDisplayMode"] {
  return value === "markdown" ? "markdown" : "html";
}

function adaptNativeMessage(
  item: NativeTimelineItem,
  nativeState: NativeTimelineState
): TimelineMessage {
  const bodyState = nativeState.bodyStates[String(item.id)];
  const loadedBody = bodyState?.status === "loaded" ? bodyState.body : undefined;
  const bodyStatus = item.html ? "loaded" : (bodyState?.status ?? "notRequested");
  return {
    messageID: item.id,
    accountKey: item.accountLabel,
    folderName: item.folderLabel,
    folderRole: null,
    himalayaEnvelopeID: item.envelopeID,
    flags: item.isFlagged ? ["flagged"] : [],
    subject: item.subject,
    from: {
      displayName: item.fromLabel || undefined,
      emailAddress: item.fromLabel || "unknown"
    },
    to: item.toLabel
      ? [{ displayName: item.toLabel, emailAddress: item.toLabel }]
      : [],
    cc: [],
    messageDate: item.date ?? null,
    direction: item.direction === "outgoing" ? "outgoing" : "incoming",
    hasAttachments: item.hasAttachments,
    bodyStatus,
    sanitizedHTML: loadedBody?.html ?? item.html ?? null,
    textFallback: loadedBody?.text ?? (bodyState?.status === "failed" ? item.preview : null),
    avatarSeed: nativeState.entity
      ? `${nativeState.entity.id}-${nativeState.entity.displayName}`
      : null,
    avatarName: nativeState.entity?.displayName ?? item.fromLabel,
    avatarImageDataURL: nativeState.entity?.avatarImageDataURL ?? null
  };
}

function normalizeWorkspace(value?: string): TimelineState["workspace"] {
  return value?.toLowerCase() === "junk" ? "junk" : "main";
}

function normalizeEntityKind(value: string): TimelineEntity["kind"] {
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
      case "selectEntity":
        this.selectEntity(event.entityID);
        break;
      case "requestOlderMessages":
        this.prependOlderMessages(event.entityID);
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

  setFixture(fixtureID: string) {
    const fixture = devFixtures.find((candidate) => candidate.id === fixtureID);
    if (!fixture) return;

    this.fixtureID = fixtureID;
    this.state = structuredClone(fixture.state);
    this.emit({ type: "state", state: this.state });
  }

  private selectEntity(entityID: string) {
    const selected = this.state.entities.find((entity) => entity.id === entityID);
    if (!selected) return;

    const fixture = devFixtures.find((candidate) => candidate.id === this.fixtureID);
    const messages = fixture?.messagesByEntity[entityID] ?? this.state.messages;

    this.state = {
      ...this.state,
      selectedEntityID: entityID,
      messages,
      isLoading: false,
      syncStatus: `${selected.messageCount} messages from ${selected.name}`,
      anchoredToBottom: true
    };

    this.emit({ type: "state", state: this.state });
  }

  private prependOlderMessages(entityID: string) {
    const firstMessage = this.state.messages[0];
    if (!firstMessage) return;

    const olderMessages = Array.from({ length: 12 }, (_, index) => {
      const offset = 12 - index;
      const date = new Date(Date.now() - (offset + 125) * 60 * 60 * 1000);
      return {
        ...firstMessage,
        messageID: `older-${entityID}-${Date.now()}-${index}`,
        subject: `Older context ${offset}: ${firstMessage.subject ?? "Message"}`,
        messageDate: date.toISOString(),
        sanitizedHTML: `<p>This is an older fixture message generated by the dev bridge.</p><p>It exercises prepend behavior without requiring Swift.</p>`,
        textFallback: "This is an older fixture message generated by the dev bridge."
      };
    });

    this.state = {
      ...this.state,
      messages: [...olderMessages, ...this.state.messages],
      hasOlderMessages: this.state.messages.length < 180,
      anchoredToBottom: false
    };
    this.emit({ type: "state", state: this.state });
  }

  private emit(event: TimelineInboundEvent) {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  private downloadAttachments(messageID: TimelineMessage["messageID"]) {
    const key = String(messageID);
    this.state = {
      ...this.state,
      attachmentDownloadStates: {
        ...(this.state.attachmentDownloadStates ?? {}),
        [key]: { status: "downloading" }
      }
    };
    this.emit({ type: "state", state: this.state });

    window.setTimeout(() => {
      this.state = {
        ...this.state,
        attachmentDownloadStates: {
          ...(this.state.attachmentDownloadStates ?? {}),
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
