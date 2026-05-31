import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Virtuoso, type VirtuosoHandle } from "react-virtuoso";
import type { TimelineBridge } from "../bridge/timelineBridge";
import { debugLog, debugLogEnabled } from "../debugLog";
import type { TimelineMessage, TimelineState } from "../types";
import { MessageCard } from "./MessageCard";

interface TimelineViewProps {
  bridge: TimelineBridge;
  state: TimelineState;
}

export function TimelineView({ bridge, state }: TimelineViewProps) {
  const selectedEntityID = state.selectedEntityID ?? undefined;
  const virtuosoRef = useRef<VirtuosoHandle>(null);
  const scrollSettleTimerRef = useRef<number | null>(null);
  const isScrollSettlingRef = useRef(false);
  const lastAtBottomRef = useRef<boolean | null>(null);
  const lastAppliedAnchorGenerationRef = useRef<number | null>(null);
  const [bodyRequestWakeToken, setBodyRequestWakeToken] = useState(0);
  const [bodyHeightCache, setBodyHeightCache] = useState<Record<string, number>>({});
  const useNativeChrome = bridge.mode === "native";
  const topAnchorOffset = useNativeChrome ? -86 : -34;
  const TimelineTopReserveHeader = useMemo(
    () =>
      function TimelineTopReserveHeader() {
        return (
          <div
            className="timeline__top-reserve"
            data-native-chrome={useNativeChrome}
            aria-hidden="true"
          />
        );
      },
    [useNativeChrome]
  );
  const BottomChromeReserveFooter = useMemo(
    () =>
      function BottomChromeReserveFooter() {
        return <div aria-hidden="true" style={{ height: 80 }} />;
      },
    []
  );
  const virtuosoComponents = useMemo(
    () => ({
      Header: TimelineTopReserveHeader,
      ...(useNativeChrome ? { Footer: BottomChromeReserveFooter } : {})
    }),
    [useNativeChrome, BottomChromeReserveFooter, TimelineTopReserveHeader]
  );

  const requestBody = useCallback(
    (message: TimelineMessage, bodyPriority: number) => {
      bridge.send({
        type: "requestBody",
        messageID: message.messageID,
        bodyPriority,
        accountKey: message.accountKey,
        folderName: message.folderName,
        himalayaEnvelopeID: message.himalayaEnvelopeID
      });
    },
    [bridge]
  );

  const downloadAttachments = useCallback(
    (message: TimelineMessage) => {
      bridge.send({
        type: "downloadAttachments",
        messageID: message.messageID
      });
    },
    [bridge]
  );

  useEffect(() => {
    if (!debugLogEnabled) return;
    debugLog("timeline state", {
      entityID: selectedEntityID ?? null,
      messages: state.messages.length,
      first: state.messages[0]?.messageID ?? null,
      last: state.messages.at(-1)?.messageID ?? null,
      loading: state.isLoading,
      loadingOlder: state.isLoadingOlderMessages,
      hasOlder: state.hasOlderMessages,
      anchored: state.anchoredToBottom,
      mode: state.bodyDisplayMode,
      remote: state.loadRemoteContent,
      avatars: state.showTimelineAvatars
    });
  }, [
    selectedEntityID,
    state.anchoredToBottom,
    state.bodyDisplayMode,
    state.hasOlderMessages,
    state.isLoading,
    state.isLoadingOlderMessages,
    state.loadRemoteContent,
    state.showTimelineAvatars,
    state.messages
  ]);

  useEffect(() => {
    return () => {
      if (scrollSettleTimerRef.current !== null) {
        window.clearTimeout(scrollSettleTimerRef.current);
        scrollSettleTimerRef.current = null;
      }
    };
  }, []);

  const handleScrolling = useCallback((isScrolling: boolean) => {
    if (debugLogEnabled) {
      debugLog("virtuoso scrolling", { isScrolling });
    }
    if (scrollSettleTimerRef.current !== null) {
      window.clearTimeout(scrollSettleTimerRef.current);
      scrollSettleTimerRef.current = null;
    }

    if (isScrolling) {
      isScrollSettlingRef.current = true;
      return;
    }

    if (!isScrollSettlingRef.current) {
      return;
    }

    scrollSettleTimerRef.current = window.setTimeout(() => {
      scrollSettleTimerRef.current = null;
      isScrollSettlingRef.current = false;
      if (debugLogEnabled) {
        debugLog("scroll settled, wake body requests");
      }
      setBodyRequestWakeToken((value) => value + 1);
    }, 160);
  }, []);

  const shouldDeferBodyRequest = useCallback(() => isScrollSettlingRef.current, []);

  const recordBodyHeight = useCallback((cacheKey: string, height: number) => {
    setBodyHeightCache((current) => {
      if (Math.abs((current[cacheKey] ?? 0) - height) <= 2) {
        return current;
      }

      return {
        ...current,
        [cacheKey]: height
      };
    });
  }, []);

  const handleAtBottomStateChange = useCallback(
    (atBottom: boolean) => {
      if (lastAtBottomRef.current === atBottom) return;
      lastAtBottomRef.current = atBottom;
      if (debugLogEnabled) {
        debugLog("virtuoso at bottom", { atBottom });
      }
      bridge.send({ type: "setScrolledToBottom", atBottom });
    },
    [bridge]
  );

  useEffect(() => {
    lastAtBottomRef.current = null;
    lastAppliedAnchorGenerationRef.current = null;
    isScrollSettlingRef.current = false;
    if (scrollSettleTimerRef.current !== null) {
      window.clearTimeout(scrollSettleTimerRef.current);
      scrollSettleTimerRef.current = null;
    }
  }, [selectedEntityID]);

  useEffect(() => {
    const anchor = state.scrollAnchor;
    if (!anchor || lastAppliedAnchorGenerationRef.current === anchor.generation) {
      return;
    }

    const index =
      anchor.edge === "bottom"
        ? state.messages.length - 1
        : state.messages.findIndex((message) => String(message.messageID) === String(anchor.id));
    if (index < 0) {
      return;
    }

    lastAppliedAnchorGenerationRef.current = anchor.generation;
    const animationFrame = window.requestAnimationFrame(() => {
      virtuosoRef.current?.scrollToIndex({
        index,
        align: anchor.edge === "bottom" ? "end" : "start",
        behavior: "auto",
        offset: anchor.edge === "top" ? topAnchorOffset : 0
      });
    });

    return () => window.cancelAnimationFrame(animationFrame);
  }, [state.messages, state.scrollAnchor, topAnchorOffset]);

  if (state.error) {
    return <main className="timeline timeline--empty">{state.error}</main>;
  }

  return (
    <main
      className="timeline"
      aria-label="Mail timeline"
      aria-busy={state.isLoading && state.messages.length === 0 ? true : undefined}
    >
      <div className="timeline__list-shell">
        <Virtuoso
          ref={virtuosoRef}
          key={selectedEntityID ?? "none"}
          className="timeline__list"
          style={{ height: "100%", minHeight: 0, width: "100%" }}
          data={state.messages}
          components={virtuosoComponents}
          alignToBottom
          defaultItemHeight={360}
          followOutput={state.anchoredToBottom ? "auto" : false}
          increaseViewportBy={{ top: 720, bottom: 720 }}
          initialTopMostItemIndex={Math.max(0, state.messages.length - 1)}
          computeItemKey={(index, message) =>
            message?.messageID ?? `missing-message-${selectedEntityID ?? "none"}-${index}`
          }
          isScrolling={handleScrolling}
          startReached={() => {
            if (debugLogEnabled) {
              debugLog("virtuoso start reached", {
                hasOlder: state.hasOlderMessages,
                loadingOlder: state.isLoadingOlderMessages,
                entityID: selectedEntityID ?? null,
                beforeMessageID: state.messages[0]?.messageID ?? null
              });
            }
            if (state.hasOlderMessages && !state.isLoadingOlderMessages && selectedEntityID) {
              bridge.send({
                type: "requestOlderMessages",
                entityID: selectedEntityID,
                beforeMessageID: state.messages[0]?.messageID
              });
            }
          }}
          atBottomStateChange={handleAtBottomStateChange}
          itemContent={(index, message) => {
            if (!message) {
              return null;
            }

            const previousMessage = index > 0 ? state.messages[index - 1] : undefined;
            const nextMessage =
              index < state.messages.length - 1 ? state.messages[index + 1] : undefined;
            const bodyHeightCacheKey = messageBodyHeightCacheKey(
              message,
              state.bodyDisplayMode,
              state.loadRemoteContent
            );

            return (
              <div className="timeline__item">
                {shouldShowDateSeparator(message, previousMessage) ? (
                  <div className="timeline__date-separator">
                    <span>{formatDateSeparator(message.messageDate)}</span>
                  </div>
                ) : null}
                <MessageCard
                  message={message}
                  cluster={messageCluster(message, previousMessage, nextMessage)}
                  showSubject={shouldShowSubject(message, previousMessage)}
                  bodyDisplayMode={state.bodyDisplayMode}
                  loadRemoteContent={state.loadRemoteContent}
                  showAvatar={state.showTimelineAvatars}
                  bodyRequestWakeToken={bodyRequestWakeToken}
                  bodyRequestPriority={bodyRequestWakeToken * 1_000_000 + index}
                  reservedBodyHeight={bodyHeightCache[bodyHeightCacheKey]}
                  bodyHeightCacheKey={bodyHeightCacheKey}
                  shouldDeferBodyRequest={shouldDeferBodyRequest}
                  attachmentState={
                    state.attachmentDownloadStates?.[String(message.messageID)] ?? {
                      status: "idle"
                    }
                  }
                  onRequestBody={requestBody}
                  onBodyHeightMeasured={recordBodyHeight}
                  onDownloadAttachments={downloadAttachments}
                />
              </div>
            );
          }}
        />
      </div>
    </main>
  );
}

function messageBodyHeightCacheKey(
  message: TimelineMessage,
  bodyDisplayMode: string,
  loadRemoteContent: boolean
) {
  return [
    message.messageID,
    bodyDisplayMode,
    loadRemoteContent ? "remote" : "blocked"
  ].join(":");
}

function shouldShowDateSeparator(
  message: TimelineMessage,
  previousMessage?: TimelineMessage
) {
  if (!message.messageDate) return false;
  if (!previousMessage?.messageDate) return true;

  return dateKey(message.messageDate) !== dateKey(previousMessage.messageDate);
}

function shouldShowSubject(message: TimelineMessage, previousMessage?: TimelineMessage) {
  if (!message.subject) return false;
  if (!previousMessage?.subject) return true;

  return normalizeSubject(message.subject) !== normalizeSubject(previousMessage.subject);
}

function normalizeSubject(subject: string) {
  return subject
    .replace(/^(\s*(re|fw|fwd)\s*:\s*)+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLocaleLowerCase();
}

function messageCluster(
  message: TimelineMessage,
  previousMessage?: TimelineMessage,
  nextMessage?: TimelineMessage
) {
  const continuesPrevious = isSameVisualGroup(message, previousMessage);
  const continuesNext = isSameVisualGroup(message, nextMessage);

  if (continuesPrevious && continuesNext) return "middle";
  if (continuesPrevious) return "end";
  if (continuesNext) return "start";
  return "single";
}

function isSameVisualGroup(message: TimelineMessage, other?: TimelineMessage) {
  if (!other || message.direction !== other.direction) return false;
  if (!message.messageDate || !other.messageDate) return true;

  const current = new Date(message.messageDate).getTime();
  const adjacent = new Date(other.messageDate).getTime();
  if (Number.isNaN(current) || Number.isNaN(adjacent)) return true;

  return Math.abs(current - adjacent) < 5 * 60 * 1000;
}

function dateKey(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;

  return [
    date.getFullYear(),
    String(date.getMonth() + 1).padStart(2, "0"),
    String(date.getDate()).padStart(2, "0")
  ].join("-");
}

function formatDateSeparator(value?: string | null) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric"
  }).format(date);
}
