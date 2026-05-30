import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createTimelineBridge,
  type TimelineBridge,
  type TimelineInboundEvent
} from "./bridge/timelineBridge";
import { DevHarness } from "./components/DevHarness";
import { EntityList } from "./components/EntityList";
import { TimelineView } from "./components/TimelineView";
import type { TimelineState } from "./types";

const emptyState: TimelineState = {
  workspace: "main",
  entities: [],
  selectedEntityID: null,
  messages: [],
  isLoading: true,
  error: null,
  syncStatus: null,
  hasOlderMessages: false,
  anchoredToBottom: true,
  bodyDisplayMode: "html"
};

export function App() {
  const bridge = useMemo<TimelineBridge>(() => createTimelineBridge(), []);
  const [state, setState] = useState<TimelineState>(emptyState);

  useEffect(() => {
    return bridge.subscribe((event) => {
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
