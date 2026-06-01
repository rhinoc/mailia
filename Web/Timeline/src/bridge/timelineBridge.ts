import type { TimelineEntity, TimelineItem, TimelineState } from "../types";

type TimelineEntityID = TimelineEntity["id"];
type TimelineMessageID = TimelineItem["id"];

export type TimelineInboundEvent =
  | { type: "state"; state: TimelineState }
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
      receive(event: TimelineInboundEvent): void;
      receiveState(state: TimelineState): void;
    };
  }
}

type Listener = (event: TimelineInboundEvent) => void;

class NativeTimelineBridge implements TimelineBridge {
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
