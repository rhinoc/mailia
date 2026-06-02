import { useEffect, useMemo, useState } from "react";
import {
  createTimelineBridge,
  type TimelineBridge,
  type TimelineInboundEvent
} from "./bridge/timelineBridge";
import { TimelineView } from "./components/TimelineView";
import type { TimelineState, TimelineStatePatch } from "./types";

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
    case "statePatch":
      return applyTimelineStatePatch(current, event.patch);
    case "error":
      return { ...current, isLoadingTimeline: false };
  }
}

function applyTimelineStatePatch(
  current: TimelineState,
  patch: TimelineStatePatch
): TimelineState {
  return {
    ...current,
    isLoadingTimeline: patch.isLoadingTimeline,
    isLoadingOlderTimeline: patch.isLoadingOlderTimeline,
    isLoadingNewerTimeline: patch.isLoadingNewerTimeline,
    hasOlderTimeline: patch.hasOlderTimeline,
    hasNewerTimeline: patch.hasNewerTimeline,
    bodyStates: applyRecordPatch(
      current.bodyStates,
      patch.bodyStateUpdates,
      patch.removedBodyStateKeys
    ),
    attachmentDownloadStates: applyRecordPatch(
      current.attachmentDownloadStates,
      patch.attachmentDownloadStateUpdates,
      patch.removedAttachmentDownloadStateKeys
    ),
    replySendState: patch.replySendState,
    chromeInsets: patch.chromeInsets
  };
}

function applyRecordPatch<T>(
  current: Record<string, T>,
  updates: Record<string, T>,
  removedKeys: string[]
) {
  const updateKeys = Object.keys(updates);
  if (updateKeys.length === 0 && removedKeys.length === 0) {
    return current;
  }

  const next = { ...current };
  for (const key of removedKeys) {
    delete next[key];
  }
  for (const key of updateKeys) {
    next[key] = updates[key];
  }
  return next;
}
