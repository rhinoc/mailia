import { useEffect, useMemo, useState } from "react";
import {
  createTimelineBridge,
  type TimelineBridge,
  type TimelineInboundEvent
} from "./bridge/timelineBridge";
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
  chromeInsets: {
    bottom: 0
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

  return (
    <div className="app-shell">
      <div className="timeline-shell">
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
      if (
        event.state.entity !== null &&
        event.state.isLoadingTimeline &&
        event.state.items.length === 0 &&
        current.items.length > 0 &&
        current.entity?.id !== event.state.entity.id
      ) {
        return {
          ...current,
          isLoadingTimeline: true,
          isLoadingOlderTimeline: false,
          isLoadingNewerTimeline: false,
          replySendState: event.state.replySendState,
          sendAccounts: event.state.sendAccounts,
          selectedSendAccountKey: event.state.selectedSendAccountKey,
          displayOptions: event.state.displayOptions,
          chromeInsets: event.state.chromeInsets
        };
      }
      return event.state;
    case "error":
      return { ...current, isLoadingTimeline: false };
  }
}
