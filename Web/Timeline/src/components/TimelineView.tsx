import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Virtuoso, type VirtuosoHandle } from "react-virtuoso";
import type { TimelineBridge } from "../bridge/timelineBridge";
import type { BodyDisplayMode, TimelineItem, TimelineMessageView, TimelineState } from "../types";
import { MessageCard } from "./MessageCard";

interface TimelineViewProps {
  bridge: TimelineBridge;
  state: TimelineState;
}

export function TimelineView({ bridge, state }: TimelineViewProps) {
  const selectedEntityID = state.entity?.id;
  const displayOptions = state.displayOptions;
  const windowState = state.windowState;
  const messageViews = useMemo(
    () => state.items.map((item) => toMessageView(item, state)),
    [state]
  );
  const bodyDisplayMode = normalizeBodyDisplayMode(displayOptions.bodyDisplayMode);
  const virtuosoRef = useRef<VirtuosoHandle>(null);
  const scrollSettleTimerRef = useRef<number | null>(null);
  const isScrollSettlingRef = useRef(false);
  const lastAtBottomRef = useRef<boolean | null>(null);
  const lastAppliedAnchorGenerationRef = useRef<number | null>(null);
  const [bodyRequestWakeToken, setBodyRequestWakeToken] = useState(0);
  const [bodyHeightCache, setBodyHeightCache] = useState<Record<string, number>>({});
  const useNativeChrome = bridge.mode === "native";
  const topAnchorOffset = useNativeChrome ? -86 : -34;
  const bottomOverlayHeight = useNativeChrome ? Math.max(0, windowState.bottomOverlayHeight) : 0;
  const bottomChromeReserve = useNativeChrome ? Math.max(104, bottomOverlayHeight + 28) : 0;
  const anchoredToBottom = state.scrollAnchor?.edge === "bottom";
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
        return <div aria-hidden="true" style={{ height: bottomChromeReserve }} />;
      },
    [bottomChromeReserve]
  );
  const virtuosoComponents = useMemo(
    () => ({
      Header: TimelineTopReserveHeader,
      ...(useNativeChrome ? { Footer: BottomChromeReserveFooter } : {})
    }),
    [useNativeChrome, BottomChromeReserveFooter, TimelineTopReserveHeader]
  );
  const requestBody = useCallback(
    (message: TimelineMessageView, bodyPriority: number) => {
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
    (message: TimelineMessageView) => {
      bridge.send({
        type: "downloadAttachments",
        messageID: message.messageID
      });
    },
    [bridge]
  );

  useEffect(() => {
    return () => {
      if (scrollSettleTimerRef.current !== null) {
        window.clearTimeout(scrollSettleTimerRef.current);
        scrollSettleTimerRef.current = null;
      }
    };
  }, []);

  const handleScrolling = useCallback((isScrolling: boolean) => {
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
        ? state.items.length - 1
        : state.items.findIndex((item) => item.id === anchor.id);
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
  }, [state.items, state.scrollAnchor, topAnchorOffset]);

  return (
    <main
      className="timeline"
      aria-label="Mail timeline"
      aria-busy={state.isLoadingTimeline && state.items.length === 0 ? true : undefined}
    >
      <div className="timeline__list-shell">
        <Virtuoso
          ref={virtuosoRef}
          key={selectedEntityID ?? "none"}
          className="timeline__list"
          style={{ height: "100%", minHeight: 0, width: "100%" }}
          data={messageViews}
          components={virtuosoComponents}
          alignToBottom
          defaultItemHeight={360}
          followOutput={anchoredToBottom ? "auto" : false}
          increaseViewportBy={{ top: 720, bottom: 720 }}
          initialTopMostItemIndex={Math.max(0, messageViews.length - 1)}
          computeItemKey={(index, message) =>
            message?.messageID ?? `missing-message-${selectedEntityID ?? "none"}-${index}`
          }
          isScrolling={handleScrolling}
          startReached={() => {
            if (state.hasOlderTimeline && !state.isLoadingOlderTimeline && selectedEntityID !== undefined) {
              bridge.send({
                type: "requestOlderMessages",
                entityID: selectedEntityID,
                beforeMessageID: state.items[0]?.id
              });
            }
          }}
          atBottomStateChange={handleAtBottomStateChange}
          itemContent={(index, message) => {
            if (!message) {
              return null;
            }

            const previousMessage = index > 0 ? messageViews[index - 1] : undefined;
            const nextMessage =
              index < messageViews.length - 1 ? messageViews[index + 1] : undefined;
            const bodyHeightCacheKey = messageBodyHeightCacheKey(
              message,
              bodyDisplayMode,
              displayOptions.loadRemoteContent,
              displayOptions.hideQuotedReplyText,
              displayOptions.hideReplySubjects
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
                  showSubject={shouldShowSubject(
                    message,
                    previousMessage,
                    displayOptions.hideReplySubjects
                  )}
                  bodyDisplayMode={bodyDisplayMode}
                  loadRemoteContent={displayOptions.loadRemoteContent}
                  hideQuotedReplyText={displayOptions.hideQuotedReplyText}
                  showAvatar={
                    message.direction === "outgoing"
                      ? displayOptions.showOwnTimelineAvatars
                      : displayOptions.showTimelineAvatars
                  }
                  bodyRequestWakeToken={bodyRequestWakeToken}
                  bodyRequestPriority={bodyRequestWakeToken * 1_000_000 + index}
                  reservedBodyHeight={bodyHeightCache[bodyHeightCacheKey]}
                  bodyHeightCacheKey={bodyHeightCacheKey}
                  shouldDeferBodyRequest={shouldDeferBodyRequest}
                  attachmentState={
                    state.attachmentDownloadStates[String(message.messageID)] ?? {
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

function normalizeBodyDisplayMode(value: string): BodyDisplayMode {
  return value === "markdown" ? "markdown" : "html";
}

function toMessageView(item: TimelineItem, state: TimelineState): TimelineMessageView {
  const bodyState = state.bodyStates[String(item.id)];
  const loadedBody = bodyState?.status === "loaded" ? bodyState.body : undefined;
  const bodyStatus = item.html ? "loaded" : (bodyState?.status ?? "notRequested");
  const direction = item.direction === "outgoing" ? "outgoing" : "incoming";

  return {
    messageID: item.id,
    accountKey: item.accountLabel,
    folderName: item.folderLabel,
    himalayaEnvelopeID: item.envelopeID,
    flags: item.isFlagged ? ["flagged"] : [],
    subject: item.subject,
    fromLabel: item.fromLabel,
    toLabel: item.toLabel,
    messageDate: item.date ?? null,
    direction,
    hasAttachments: item.hasAttachments,
    bodyStatus,
    sanitizedHTML: loadedBody?.html ?? item.html ?? null,
    textFallback: loadedBody?.text ?? (bodyState?.status === "failed" ? item.preview : null),
    avatarSeed: state.entity
      ? `${state.entity.id}-${state.entity.displayName}`
      : null,
    avatarName: direction === "outgoing"
      ? item.accountLabel
      : (state.entity?.displayName ?? item.fromLabel),
    avatarEmoji: direction === "outgoing" ? (item.accountEmoji ?? null) : null,
    avatarImageDataURL: direction === "outgoing"
      ? (item.accountAvatarImageDataURL ?? null)
      : (state.entity?.avatarImageDataURL ?? null)
  };
}

function messageBodyHeightCacheKey(
  message: TimelineMessageView,
  bodyDisplayMode: string,
  loadRemoteContent: boolean,
  hideQuotedReplyText: boolean,
  hideReplySubjects: boolean
) {
  return [
    message.messageID,
    bodyDisplayMode,
    loadRemoteContent ? "remote" : "blocked",
    hideQuotedReplyText ? "quotes-hidden" : "quotes-shown",
    hideReplySubjects ? "reply-subjects-hidden" : "reply-subjects-shown"
  ].join(":");
}

function shouldShowDateSeparator(
  message: TimelineMessageView,
  previousMessage?: TimelineMessageView
) {
  if (!message.messageDate) return false;
  if (!previousMessage?.messageDate) return true;

  return dateKey(message.messageDate) !== dateKey(previousMessage.messageDate);
}

function shouldShowSubject(
  message: TimelineMessageView,
  previousMessage: TimelineMessageView | undefined,
  hideReplySubjects: boolean
) {
  if (!message.subject) return false;
  if (hideReplySubjects && isReplySubject(message.subject)) return false;
  if (!previousMessage?.subject) return true;

  return normalizeSubject(message.subject) !== normalizeSubject(previousMessage.subject);
}

function isReplySubject(subject: string) {
  return /^\s*(re|回复|答复|回覆)\s*[:：]/i.test(subject);
}

function normalizeSubject(subject: string) {
  return subject
    .replace(/^(\s*(re|fw|fwd|回复|答复|回覆)\s*[:：]\s*)+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLocaleLowerCase();
}

function messageCluster(
  message: TimelineMessageView,
  previousMessage?: TimelineMessageView,
  nextMessage?: TimelineMessageView
) {
  const continuesPrevious = isSameVisualGroup(message, previousMessage);
  const continuesNext = isSameVisualGroup(message, nextMessage);

  if (continuesPrevious && continuesNext) return "middle";
  if (continuesPrevious) return "end";
  if (continuesNext) return "start";
  return "single";
}

function isSameVisualGroup(message: TimelineMessageView, other?: TimelineMessageView) {
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
