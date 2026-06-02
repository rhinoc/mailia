import type { TimelineEntity, TimelineItem, TimelineState, TimelineStatePatch } from "../types";

type TimelineEntityID = TimelineEntity["id"];
type TimelineMessageID = TimelineItem["id"];

export type TimelineInboundEvent =
  | { type: "state"; state: TimelineState }
  | { type: "statePatch"; patch: TimelineStatePatch }
  | { type: "error"; message: string };

export type TimelineOutboundEvent =
  | { type: "ready" }
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
  | { type: "setScrolledToBottom"; atBottom: boolean }
  | { type: "log"; payload: { level: string; message: string } };

export interface TimelineBridge {
  subscribe(listener: (event: TimelineInboundEvent) => void): () => void;
  send(event: TimelineOutboundEvent): void;
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
      receive(event: unknown): void;
    };
    __mailiaTimelinePendingEvents?: TimelineInboundEvent[];
  }
}

type Listener = (event: TimelineInboundEvent) => void;

class NativeTimelineBridge implements TimelineBridge {
  private listeners = new Set<Listener>();
  private queuedEvents: TimelineInboundEvent[] = [];

  constructor(
    private readonly handler: {
      postMessage(message: unknown): void;
    }
  ) {
    window.mailiaTimeline = {
      receive: (event) => {
        const inboundEvent = normalizeInboundEvent(event);
        if (inboundEvent) {
          this.emit(inboundEvent);
        }
      }
    };

    const pendingEvents = window.__mailiaTimelinePendingEvents;
    if (pendingEvents?.length) {
      delete window.__mailiaTimelinePendingEvents;
      for (const event of pendingEvents) {
        const inboundEvent = normalizeInboundEvent(event);
        if (inboundEvent) {
          this.emit(inboundEvent);
        }
      }
    }
  }

  subscribe(listener: Listener) {
    this.listeners.add(listener);
    if (this.queuedEvents.length > 0) {
      const queuedEvents = this.queuedEvents;
      this.queuedEvents = [];
      for (const event of queuedEvents) {
        listener(event);
      }
    }
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
    if (this.listeners.size === 0) {
      this.queuedEvents.push(event);
      return;
    }

    for (const listener of this.listeners) {
      listener(event);
    }
  }
}

function normalizeInboundEvent(event: unknown): TimelineInboundEvent | null {
  if (!event || typeof event !== "object") {
    return null;
  }

  const candidate = event as Partial<TimelineInboundEvent>;
  switch (candidate.type) {
    case "state": {
      const state = (candidate as { state?: unknown }).state;
      return isTimelineState(state) ? { type: "state", state } : null;
    }
    case "statePatch": {
      const patch = (candidate as { patch?: unknown }).patch;
      return isTimelineStatePatch(patch) ? { type: "statePatch", patch } : null;
    }
    case "error": {
      const message = (candidate as { message?: unknown }).message;
      return { type: "error", message: typeof message === "string" ? message : "Timeline error" };
    }
    default:
      return null;
  }
}

function isTimelineState(value: unknown): value is TimelineState {
  if (!value || typeof value !== "object") return false;
  const state = value as Partial<TimelineState>;
  return (
    Array.isArray(state.items) &&
    isRecord(state.bodyStates) &&
    isRecord(state.attachmentDownloadStates) &&
    state.replySendState !== undefined &&
    state.displayOptions !== undefined &&
    state.chromeInsets !== undefined
  );
}

function isTimelineStatePatch(value: unknown): value is TimelineStatePatch {
  if (!value || typeof value !== "object") return false;
  const patch = value as Partial<TimelineStatePatch>;
  return (
    typeof patch.isLoadingTimeline === "boolean" &&
    typeof patch.isLoadingOlderTimeline === "boolean" &&
    typeof patch.isLoadingNewerTimeline === "boolean" &&
    typeof patch.hasOlderTimeline === "boolean" &&
    typeof patch.hasNewerTimeline === "boolean" &&
    isRecord(patch.bodyStateUpdates) &&
    Array.isArray(patch.removedBodyStateKeys) &&
    isRecord(patch.attachmentDownloadStateUpdates) &&
    Array.isArray(patch.removedAttachmentDownloadStateKeys) &&
    patch.replySendState !== undefined &&
    patch.chromeInsets !== undefined
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
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
    case "setScrolledToBottom":
      return null;
    case "log":
      return event;
  }
}

export function createTimelineBridge(): TimelineBridge {
  const nativeHandler = window.webkit?.messageHandlers?.mailiaTimeline;
  if (!nativeHandler) {
    throw new Error("Mailia timeline requires the native WKWebView bridge.");
  }

  return new NativeTimelineBridge(nativeHandler);
}
