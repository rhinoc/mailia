import { useCallback, useEffect, useRef } from "react";
import { Virtuoso } from "react-virtuoso";
import type { TimelineBridge } from "../bridge/timelineBridge";
import type { TimelineMessage, TimelineState } from "../types";
import { MessageCard } from "./MessageCard";

interface TimelineViewProps {
  bridge: TimelineBridge;
  state: TimelineState;
}

export function TimelineView({ bridge, state }: TimelineViewProps) {
  const selectedEntityID = state.selectedEntityID ?? undefined;
  const listShellRef = useRef<HTMLDivElement | null>(null);

  const requestBody = useCallback(
    (message: TimelineMessage) => {
      bridge.send({
        type: "requestBody",
        messageID: message.messageID,
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
    console.warn("[MailiaTimelineWebDebug] timeline state", {
      bridgeMode: bridge.mode,
      selectedEntityID: state.selectedEntityID,
      messageCount: state.messages.length,
      firstMessageID: state.messages[0]?.messageID ?? null,
      lastMessageID: state.messages.at(-1)?.messageID ?? null,
      isLoading: state.isLoading,
      hasOlderMessages: state.hasOlderMessages,
      anchoredToBottom: state.anchoredToBottom,
      syncStatus: state.syncStatus
    });
  }, [
    bridge.mode,
    state.anchoredToBottom,
    state.hasOlderMessages,
    state.isLoading,
    state.messages,
    state.selectedEntityID,
    state.syncStatus
  ]);

  useEffect(() => {
    const shell = listShellRef.current;
    if (!shell) return;

    const logLayout = (source: string) => {
      const shellRect = rectSummary(shell);
      const virtuosoRoot = shell.querySelector(".timeline__list");
      const scroller = shell.querySelector("[data-virtuoso-scroller]");
      const itemList = shell.querySelector("[data-virtuoso-item-list]");
      const items = Array.from(shell.querySelectorAll("[data-index]"));
      const firstItem = items[0] as HTMLElement | undefined;

      console.warn("[MailiaTimelineWebDebug] virtuoso layout", {
        source,
        viewport: {
          innerWidth: window.innerWidth,
          innerHeight: window.innerHeight,
          documentClientWidth: document.documentElement.clientWidth,
          documentClientHeight: document.documentElement.clientHeight,
          bodyClientWidth: document.body.clientWidth,
          bodyClientHeight: document.body.clientHeight
        },
        shell: shellRect,
        root: rectSummary(virtuosoRoot),
        scroller: rectSummary(scroller),
        itemList: rectSummary(itemList),
        itemDOMCount: items.length,
        firstItem: rectSummary(firstItem),
        firstItemIndex: firstItem?.getAttribute("data-index") ?? null,
        shellHTMLLength: shell.innerHTML.length
      });
    };

    logLayout("effect");
    const resizeObserver = new ResizeObserver(() => logLayout("resize"));
    resizeObserver.observe(shell);

    const timeout = window.setTimeout(() => logLayout("timeout-250ms"), 250);
    const secondTimeout = window.setTimeout(() => logLayout("timeout-1000ms"), 1000);

    return () => {
      resizeObserver.disconnect();
      window.clearTimeout(timeout);
      window.clearTimeout(secondTimeout);
    };
  }, [state.messages.length, selectedEntityID]);

  if (state.isLoading && state.messages.length === 0) {
    return <main className="timeline timeline--empty">Loading timeline...</main>;
  }

  if (state.error) {
    return <main className="timeline timeline--empty">{state.error}</main>;
  }

  if (!selectedEntityID) {
    return <main className="timeline timeline--empty">Select an entity.</main>;
  }

  return (
    <main className="timeline" aria-label="Mail timeline">
      <div className="timeline__list-shell" ref={listShellRef}>
        <Virtuoso
          className="timeline__list"
          style={{ height: "100%", minHeight: 0, width: "100%" }}
          data={state.messages}
          alignToBottom
          defaultItemHeight={360}
          followOutput={state.anchoredToBottom ? "auto" : false}
          increaseViewportBy={{ top: 720, bottom: 720 }}
          initialTopMostItemIndex={Math.max(0, state.messages.length - 1)}
          computeItemKey={(index, message) =>
            message?.messageID ?? `missing-message-${selectedEntityID ?? "none"}-${index}`
          }
          startReached={() => {
            if (state.hasOlderMessages && selectedEntityID) {
              bridge.send({
                type: "requestOlderMessages",
                entityID: selectedEntityID,
                beforeMessageID: state.messages[0]?.messageID
              });
            }
          }}
          rangeChanged={(range) => {
            console.warn("[MailiaTimelineWebDebug] virtuoso range", range);
          }}
          itemsRendered={(items) => {
            console.warn(
              "[MailiaTimelineWebDebug] virtuoso itemsRendered",
              items.map((item) => ({
                index: item.index,
                messageID:
                  "data" in item && item.data
                    ? (item.data as TimelineMessage).messageID
                    : null
              }))
            );
          }}
          totalListHeightChanged={(height) => {
            console.warn("[MailiaTimelineWebDebug] virtuoso totalHeight", {
              height
            });
          }}
          atBottomStateChange={(atBottom) => {
            console.warn("[MailiaTimelineWebDebug] virtuoso atBottom", {
              atBottom
            });
            bridge.send({ type: "setScrolledToBottom", atBottom });
          }}
          itemContent={(index, message) => {
            if (!message) {
              console.warn("[MailiaTimelineWebDebug] virtuoso missing item", {
                index,
                selectedEntityID,
                messageCount: state.messages.length
              });
              return null;
            }

            const previousMessage = index > 0 ? state.messages[index - 1] : undefined;
            const nextMessage =
              index < state.messages.length - 1 ? state.messages[index + 1] : undefined;

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
                  attachmentState={
                    state.attachmentDownloadStates?.[String(message.messageID)] ?? {
                      status: "idle"
                    }
                  }
                  onRequestBody={requestBody}
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

function rectSummary(element: Element | null | undefined) {
  if (!(element instanceof HTMLElement)) return null;
  const rect = element.getBoundingClientRect();
  return {
    x: Math.round(rect.x),
    y: Math.round(rect.y),
    width: Math.round(rect.width),
    height: Math.round(rect.height),
    clientWidth: element.clientWidth,
    clientHeight: element.clientHeight,
    scrollWidth: element.scrollWidth,
    scrollHeight: element.scrollHeight,
    display: getComputedStyle(element).display,
    overflow: getComputedStyle(element).overflow
  };
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
