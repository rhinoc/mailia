import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createTimelineBridge,
  isDevTimelineBridge,
  type TimelineBridge,
  type TimelineInboundEvent
} from "./bridge/timelineBridge";
import { DevHarness } from "./components/DevHarness";
import { EntityList } from "./components/EntityList";
import { TimelineView } from "./components/TimelineView";
import type { TimelineState } from "./types";

const emptyState: TimelineState = {
  entity: null,
  items: [],
  isLoadingTimeline: true,
  isLoadingOlderTimeline: false,
  isLoadingNewerTimeline: false,
  hasOlderTimeline: false,
  hasNewerTimeline: false,
  bodyStates: {},
  attachmentDownloadStates: {},
  replySendState: { status: "idle" },
  sendAccounts: [],
  selectedSendAccountKey: null,
  scrollAnchor: null,
  displayOptions: {
    bodyDisplayMode: "html",
    loadRemoteContent: false,
    showTimelineAvatars: true,
    showOwnTimelineAvatars: true,
    hideQuotedReplyText: false,
    hideReplySubjects: false
  },
  windowState: {
    bottomOverlayHeight: 0
  }
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
    (entityID: number) => {
      bridge.send({ type: "selectEntity", entityID });
    },
    [bridge]
  );

  const refreshEntities = useCallback(() => {
    bridge.send({ type: "refreshEntities" });
  }, [bridge]);

  return (
    <div className="app-shell" data-bridge={bridge.mode}>
      <DevHarness bridge={bridge} state={state} />
      <div className="timeline-shell" data-dev={bridge.mode === "dev"}>
        {isDevTimelineBridge(bridge) ? (
          <EntityList
            entities={bridge.getEntities()}
            selectedEntityID={state.entity?.id ?? null}
            isRefreshing={state.isLoadingTimeline}
            onSelect={selectEntity}
            onRefresh={refreshEntities}
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
    case "error":
      return { ...current, isLoadingTimeline: false };
  }
}
