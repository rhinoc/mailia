import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { TimelineBridge } from "../bridge/timelineBridge";
import type { BodyDisplayMode, TimelineItem, TimelineMessageView, TimelineState } from "../types";
import { MessageCard } from "./MessageCard";

interface TimelineViewProps {
  bridge: TimelineBridge;
  state: TimelineState;
}

type TimelineScrollDebugDetails = Record<string, unknown>;

type TimelineListRow =
  | { kind: "top-reserve"; key: "top-reserve" }
  | { kind: "loading"; key: "loading"; messageIndex: number }
  | { kind: "message"; key: string; message: TimelineMessageView; messageIndex: number }
  | { kind: "bottom-reserve"; key: "bottom-reserve" };

type TimelineDataChange =
  | "append"
  | "prepend"
  | "remove-from-start"
  | "remove-from-end"
  | "replace";

interface ReverseScrollMetrics {
  scrollTop: number;
  clientHeight: number;
  scrollHeight: number;
  bottomOffset: number;
  topOffset: number;
}

interface RevealBoundary {
  entityID?: number;
  firstVisibleMessageID: number | null;
}

export function TimelineView({ bridge, state }: TimelineViewProps) {
  const selectedEntityID = state.entity?.id;
  const displayOptions = state.displayOptions;
  const itemIDSignature = useMemo(
    () => state.items.map((item) => item.id).join(":"),
    [state.items]
  );
  const itemIDs = useMemo(
    () => state.items.map((item) => item.id),
    [itemIDSignature]
  );
  const itemCount = itemIDs.length;
  const messageViews = useMemo(
    () => state.items.map((item) => toMessageView(item, state)),
    [state]
  );
  const bodyDisplayMode = normalizeBodyDisplayMode(displayOptions.bodyDisplayMode);
  const nextBodyRequestIndex = useMemo(
    () => firstUnsettledMessageIndexFromBottom(messageViews),
    [messageViews]
  );
  const computedFirstVisibleIndex =
    nextBodyRequestIndex === null ? 0 : nextBodyRequestIndex + 1;
  const listRef = useRef<HTMLDivElement>(null);
  const scrollSettleTimerRef = useRef<number | null>(null);
  const isScrollSettlingRef = useRef(false);
  const lastBodyRequestKeyRef = useRef<string | null>(null);
  const lastOlderRequestRef = useRef<string | null>(null);
  const previousItemIDsRef = useRef<{
    entityID?: number;
    itemIDs: number[];
    signature: string;
  } | null>(null);
  const [bodyRequestWakeToken, setBodyRequestWakeToken] = useState(0);
  const [bodyHeightCache, setBodyHeightCache] = useState<Record<string, number>>({});
  const [revealBoundary, setRevealBoundary] = useState<RevealBoundary>({
    entityID: undefined,
    firstVisibleMessageID: null
  });
  const bottomChromeReserve = Math.max(0, state.chromeInsets.bottom);
  const scrollAnchorID = state.scrollAnchor?.id ?? null;
  const scrollAnchorEdge = state.scrollAnchor?.edge ?? null;
  const scrollAnchorGeneration = state.scrollAnchor?.generation ?? null;
  const visibleStartIndex = readVisibleStartIndex(
    revealBoundary,
    selectedEntityID,
    messageViews,
    computedFirstVisibleIndex
  );

  const debugScroll = useCallback(
    (message: string, details: TimelineScrollDebugDetails = {}) => {
      const payload = {
        entityID: selectedEntityID ?? null,
        anchorID: scrollAnchorID,
        anchorEdge: scrollAnchorEdge,
        anchorGeneration: scrollAnchorGeneration,
        itemCount,
        bottomChromeReserve,
        metrics: readReverseScrollMetrics(listRef.current),
        ...details
      };
      const line = `[MailiaScrollDebug] ${message} ${JSON.stringify(payload)}`;
      console.info(line);
      window.webkit?.messageHandlers?.mailiaTimeline?.postMessage({
        type: "log",
        payload: {
          level: "debug",
          message: line
        }
      });
    },
    [
      bottomChromeReserve,
      itemCount,
      scrollAnchorEdge,
      scrollAnchorGeneration,
      scrollAnchorID,
      selectedEntityID
    ]
  );

  const listRows = useMemo<TimelineListRow[]>(
    () => {
      const firstVisibleIndex = clampIndex(visibleStartIndex, messageViews.length);
      const loadingIndex =
        nextBodyRequestIndex !== null && nextBodyRequestIndex < firstVisibleIndex
          ? nextBodyRequestIndex
          : null;
      const rows: TimelineListRow[] = [
        { kind: "bottom-reserve", key: "bottom-reserve" }
      ];

      for (let messageIndex = messageViews.length - 1; messageIndex >= firstVisibleIndex; messageIndex -= 1) {
        const message = messageViews[messageIndex];
        rows.push({
          kind: "message",
          key: String(message.messageID),
          message,
          messageIndex
        });
      }

      if (loadingIndex !== null) {
        rows.push({
          kind: "loading",
          key: "loading",
          messageIndex: loadingIndex
        });
      }

      rows.push({ kind: "top-reserve", key: "top-reserve" });
      return rows;
    },
    [messageViews, nextBodyRequestIndex, visibleStartIndex]
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

  const recordBodyHeight = useCallback(
    (cacheKey: string, height: number) => {
      setBodyHeightCache((current) => {
        if (Math.abs((current[cacheKey] ?? 0) - height) <= 2) {
          return current;
        }

        return {
          ...current,
          [cacheKey]: height
        };
      });
    },
    []
  );

  const maybeRequestOlderMessages = useCallback(
    (metrics: ReverseScrollMetrics | null) => {
      if (
        !metrics ||
        metrics.topOffset > 96 ||
        !state.hasOlderTimeline ||
        state.isLoadingOlderTimeline ||
        selectedEntityID === undefined
      ) {
        return;
      }

      const beforeMessageID = state.items[0]?.id;
      if (beforeMessageID === undefined) {
        return;
      }

      const requestKey = `${selectedEntityID}:${beforeMessageID}`;
      if (lastOlderRequestRef.current === requestKey) {
        return;
      }

      lastOlderRequestRef.current = requestKey;
      bridge.send({
        type: "requestOlderMessages",
        entityID: selectedEntityID,
        beforeMessageID
      });
    },
    [
      bridge,
      selectedEntityID,
      state.hasOlderTimeline,
      state.isLoadingOlderTimeline,
      state.items
    ]
  );

  const handleListScroll = useCallback(() => {
    const metrics = readReverseScrollMetrics(listRef.current);
    handleScrolling(true);
    maybeRequestOlderMessages(metrics);
  }, [handleScrolling, maybeRequestOlderMessages]);

  const handleListScrollEnd = useCallback(() => {
    handleScrolling(false);
  }, [handleScrolling]);

  useEffect(() => {
    lastBodyRequestKeyRef.current = null;
    lastOlderRequestRef.current = null;
    previousItemIDsRef.current = null;
    isScrollSettlingRef.current = false;
    if (scrollSettleTimerRef.current !== null) {
      window.clearTimeout(scrollSettleTimerRef.current);
      scrollSettleTimerRef.current = null;
    }
  }, [selectedEntityID]);

  useEffect(() => {
    setRevealBoundary((current) => {
      const nextBoundary = makeRevealBoundary(
        selectedEntityID,
        messageViews,
        computedFirstVisibleIndex
      );
      if (current.entityID !== selectedEntityID) {
        return nextBoundary;
      }

      const currentIndex = readVisibleStartIndex(
        current,
        selectedEntityID,
        messageViews,
        computedFirstVisibleIndex
      );
      if (computedFirstVisibleIndex < currentIndex) {
        return nextBoundary;
      }

      return current;
    });
  }, [
    computedFirstVisibleIndex,
    messageViews,
    selectedEntityID
  ]);

  useEffect(() => {
    if (nextBodyRequestIndex === null) {
      return;
    }

    const message =
      messageViews[nextBodyRequestIndex];
    if (!message || isBodySettled(message) || message.bodyStatus === "loading") {
      return;
    }

    const requestKey = `${selectedEntityID ?? "none"}:${message.messageID}:${message.bodyStatus}`;
    if (lastBodyRequestKeyRef.current === requestKey) {
      return;
    }

    lastBodyRequestKeyRef.current = requestKey;
    requestBody(message, bodyRequestWakeToken * 1_000_000 + nextBodyRequestIndex);
  }, [
    bodyRequestWakeToken,
    messageViews,
    nextBodyRequestIndex,
    requestBody,
    selectedEntityID
  ]);

  useEffect(() => {
    const previous = previousItemIDsRef.current;
    previousItemIDsRef.current = {
      entityID: selectedEntityID,
      itemIDs,
      signature: itemIDSignature
    };

    if (
      !previous ||
      previous.entityID !== selectedEntityID ||
      previous.signature === itemIDSignature
    ) {
      return;
    }

    const dataChange = classifyTimelineDataChange(previous.itemIDs, itemIDs);
    debugScroll("timeline data change classified", {
      dataChange,
      previousCount: previous.itemIDs.length,
      nextCount: itemIDs.length,
      previousFirstID: previous.itemIDs[0] ?? null,
      previousLastID: previous.itemIDs[previous.itemIDs.length - 1] ?? null,
      nextFirstID: itemIDs[0] ?? null,
      nextLastID: itemIDs[itemIDs.length - 1] ?? null
    });

  }, [
    debugScroll,
    itemIDs,
    itemIDSignature,
    selectedEntityID
  ]);

  return (
    <main
      className="timeline"
      aria-label="Mail timeline"
      aria-busy={state.isLoadingTimeline && state.items.length === 0 ? true : undefined}
    >
      <div
        key={selectedEntityID ?? "empty"}
        ref={listRef}
        className="timeline__list"
        onScroll={handleListScroll}
        onScrollEnd={handleListScrollEnd}
      >
        {listRows.map((row) => {
          if (row.kind === "top-reserve") {
            return (
              <div
                key={row.key}
                className="timeline__top-reserve"
                data-row-kind="top-reserve"
                data-native-chrome="true"
                aria-hidden="true"
              />
            );
          }

          if (row.kind === "bottom-reserve") {
            return (
              <div
                key={row.key}
                className="timeline__bottom-reserve"
                data-row-kind="bottom-reserve"
                aria-hidden="true"
                style={{ height: bottomChromeReserve }}
              />
            );
          }

          if (row.kind === "loading") {
            return (
              <div
                key={row.key}
                className="timeline__loading-row"
                data-row-kind="loading"
                data-message-index={row.messageIndex}
                aria-live="polite"
                aria-label="Loading messages"
              >
                <span className="timeline__loading-spinner" aria-hidden="true" />
              </div>
            );
          }

          const { message, messageIndex } = row;
          const previousMessage = messageIndex > 0 ? messageViews[messageIndex - 1] : undefined;
          const nextMessage =
            messageIndex < messageViews.length - 1 ? messageViews[messageIndex + 1] : undefined;
          const bodyHeightCacheKey = messageBodyHeightCacheKey(
            message,
            bodyDisplayMode,
            displayOptions.loadRemoteContent,
            displayOptions.hideQuotedReplyText,
            displayOptions.hideReplySubjects
          );

          return (
            <div
              key={row.key}
              className="timeline__item"
              data-row-kind="message"
              data-message-id={message.messageID}
              data-message-index={messageIndex}
            >
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
                bodyRequestPriority={bodyRequestWakeToken * 1_000_000 + messageIndex}
                reservedBodyHeight={bodyHeightCache[bodyHeightCacheKey]}
                bodyHeightCacheKey={bodyHeightCacheKey}
                canRequestBody={true}
                canRevealBody={true}
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
        })}
      </div>
    </main>
  );
}

function normalizeBodyDisplayMode(value: string): BodyDisplayMode {
  return value === "markdown" ? "markdown" : "html";
}

function makeRevealBoundary(
  entityID: number | undefined,
  messages: readonly TimelineMessageView[],
  firstVisibleIndex: number
): RevealBoundary {
  return {
    entityID,
    firstVisibleMessageID: messages[firstVisibleIndex]?.messageID ?? null
  };
}

function readVisibleStartIndex(
  boundary: RevealBoundary,
  entityID: number | undefined,
  messages: readonly TimelineMessageView[],
  fallbackIndex: number
) {
  if (boundary.entityID !== entityID) {
    return fallbackIndex;
  }

  if (boundary.firstVisibleMessageID === null) {
    return messages.length;
  }

  const index = messages.findIndex(
    (message) => message.messageID === boundary.firstVisibleMessageID
  );
  return index === -1 ? fallbackIndex : index;
}

function clampIndex(index: number, length: number) {
  return Math.max(0, Math.min(index, length));
}

function readReverseScrollMetrics(scroller: HTMLElement | null): ReverseScrollMetrics | null {
  if (!scroller) {
    return null;
  }

  const scrollTop = scroller.scrollTop;
  const overflow = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  return {
    scrollTop: roundMetric(scrollTop),
    clientHeight: roundMetric(scroller.clientHeight),
    scrollHeight: roundMetric(scroller.scrollHeight),
    bottomOffset: roundMetric(Math.max(0, -scrollTop)),
    topOffset: roundMetric(Math.max(0, overflow + scrollTop))
  };
}

function roundMetric(value: number) {
  return Math.round(value * 10) / 10;
}

function firstUnsettledMessageIndexFromBottom(messages: readonly TimelineMessageView[]) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (!isBodySettled(messages[index])) {
      return index;
    }
  }

  return null;
}

function isBodySettled(message: TimelineMessageView) {
  return Boolean(message.sanitizedHTML) ||
    message.bodyStatus === "loaded" ||
    message.bodyStatus === "failed";
}

function classifyTimelineDataChange(
  previousItemIDs: readonly number[],
  nextItemIDs: readonly number[]
): TimelineDataChange {
  if (
    nextItemIDs.length > previousItemIDs.length &&
    arrayStartsWith(nextItemIDs, previousItemIDs)
  ) {
    return "append";
  }

  if (
    nextItemIDs.length > previousItemIDs.length &&
    arrayEndsWith(nextItemIDs, previousItemIDs)
  ) {
    return "prepend";
  }

  if (
    nextItemIDs.length < previousItemIDs.length &&
    arrayStartsWith(previousItemIDs, nextItemIDs)
  ) {
    return "remove-from-end";
  }

  if (
    nextItemIDs.length < previousItemIDs.length &&
    arrayEndsWith(previousItemIDs, nextItemIDs)
  ) {
    return "remove-from-start";
  }

  return "replace";
}

function arrayStartsWith(values: readonly number[], prefix: readonly number[]) {
  if (prefix.length > values.length) {
    return false;
  }

  return prefix.every((value, index) => values[index] === value);
}

function arrayEndsWith(values: readonly number[], suffix: readonly number[]) {
  if (suffix.length > values.length) {
    return false;
  }

  const offset = values.length - suffix.length;
  return suffix.every((value, index) => values[offset + index] === value);
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
