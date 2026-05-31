import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createTimelineBridge,
  type TimelineBridge,
  type TimelineInboundEvent
} from "./bridge/timelineBridge";
import { DevHarness } from "./components/DevHarness";
import { EntityList } from "./components/EntityList";
import { TimelineView } from "./components/TimelineView";
import { debugLog, debugLogEnabled } from "./debugLog";
import type { TimelineState } from "./types";

const emptyState: TimelineState = {
  workspace: "main",
  entities: [],
  selectedEntityID: null,
  messages: [],
  isLoading: true,
  isLoadingOlderMessages: false,
  isLoadingNewerMessages: false,
  error: null,
  syncStatus: null,
  hasOlderMessages: false,
  anchoredToBottom: true,
  scrollAnchor: null,
  bodyDisplayMode: "html",
  loadRemoteContent: false,
  showTimelineAvatars: true
};

export function App() {
  const bridge = useMemo<TimelineBridge>(() => createTimelineBridge(), []);
  const [state, setState] = useState<TimelineState>(emptyState);

  useEffect(() => {
    return bridge.subscribe((event) => {
      if (debugLogEnabled) {
        debugLog("app inbound event", inboundEventSummary(event));
      }
      setState((current) => reduceInboundEvent(current, event));
    });
  }, [bridge]);

  useEffect(() => {
    bridge.send({ type: "ready" });
  }, [bridge]);

  const selectEntity = useCallback(
    (entityID: string) => {
      bridge.send({ type: "selectEntity", entityID });
    },
    [bridge]
  );

  return (
    <div className="app-shell" data-bridge={bridge.mode}>
      <DevHarness bridge={bridge} state={state} />
      <div className="timeline-shell" data-dev={bridge.mode === "dev"}>
        {bridge.mode === "dev" ? (
          <EntityList
            entities={state.entities}
            selectedEntityID={state.selectedEntityID}
            onSelect={selectEntity}
          />
        ) : null}
        <TimelineView bridge={bridge} state={state} />
      </div>
    </div>
  );
}

function inboundEventSummary(event: TimelineInboundEvent) {
  switch (event.type) {
    case "state":
      return {
        type: event.type,
        entityID: event.state.selectedEntityID,
        messages: event.state.messages.length,
        loading: event.state.isLoading,
        loadingOlder: event.state.isLoadingOlderMessages,
        hasOlder: event.state.hasOlderMessages,
        anchored: event.state.anchoredToBottom,
        bodyStates: event.state.messages.reduce<Record<string, number>>((counts, message) => {
          const status = message.bodyStatus ?? "unknown";
          counts[status] = (counts[status] ?? 0) + 1;
          return counts;
        }, {})
      };
    case "messagesChanged":
      return { type: event.type, entityID: event.entityID, messages: event.messages.length };
    case "bodyLoaded":
      return {
        type: event.type,
        messageID: event.messageID,
        hasHTML: Boolean(event.sanitizedHTML),
        hasText: Boolean(event.textFallback)
      };
    case "error":
      return { type: event.type, message: event.message };
  }
}

function reduceInboundEvent(
  current: TimelineState,
  event: TimelineInboundEvent
): TimelineState {
  switch (event.type) {
    case "state":
      return event.state;
    case "messagesChanged":
      return {
        ...current,
        selectedEntityID: event.entityID,
        messages: event.messages,
        hasOlderMessages: event.hasOlderMessages ?? current.hasOlderMessages,
        anchoredToBottom: event.anchoredToBottom ?? current.anchoredToBottom,
        scrollAnchor: null,
        isLoading: false
      };
    case "bodyLoaded":
      return {
        ...current,
        messages: current.messages.map((message) =>
          message.messageID === event.messageID
            ? {
                ...message,
                sanitizedHTML: event.sanitizedHTML ?? message.sanitizedHTML,
                textFallback: event.textFallback ?? message.textFallback
              }
            : message
        )
      };
    case "error":
      return { ...current, error: event.message, isLoading: false };
  }
}
