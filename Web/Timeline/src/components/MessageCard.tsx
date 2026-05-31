import { useCallback, useEffect, useState } from "react";
import { debugLog, debugLogEnabled } from "../debugLog";
import type { AttachmentDownloadState, BodyDisplayMode, TimelineMessage } from "../types";
import { MessageBody } from "./MessageBody";

const MIN_RESERVED_BODY_HEIGHT = 120;
const MAX_ESTIMATED_BODY_HEIGHT = 420;
const MAX_CACHED_BODY_HEIGHT = 1400;

interface MessageCardProps {
  message: TimelineMessage;
  showSubject: boolean;
  cluster: "single" | "start" | "middle" | "end";
  bodyDisplayMode: BodyDisplayMode;
  loadRemoteContent: boolean;
  showAvatar: boolean;
  bodyRequestWakeToken: number;
  bodyRequestPriority: number;
  reservedBodyHeight?: number;
  bodyHeightCacheKey: string;
  shouldDeferBodyRequest(): boolean;
  attachmentState: AttachmentDownloadState;
  onRequestBody(message: TimelineMessage, priority: number): void;
  onBodyHeightMeasured(cacheKey: string, height: number): void;
  onDownloadAttachments(message: TimelineMessage): void;
}

export function MessageCard({
  message,
  showSubject,
  cluster,
  bodyDisplayMode,
  loadRemoteContent,
  showAvatar,
  bodyRequestWakeToken,
  bodyRequestPriority,
  reservedBodyHeight,
  bodyHeightCacheKey,
  shouldDeferBodyRequest,
  attachmentState,
  onRequestBody,
  onBodyHeightMeasured,
  onDownloadAttachments
}: MessageCardProps) {
  const hasBody = Boolean(message.sanitizedHTML || message.textFallback);
  const messageID = message.messageID;
  const accountKey = message.accountKey;
  const folderName = message.folderName;
  const himalayaEnvelopeID = message.himalayaEnvelopeID;
  const bodyStatus = message.bodyStatus;
  const estimatedBodyHeight = estimateReservedBodyHeight(message);
  const [committedBodyHeight, setCommittedBodyHeight] = useState(
    clampReservedHeight(reservedBodyHeight ?? estimatedBodyHeight)
  );
  const [revealedBodyMessageID, setRevealedBodyMessageID] = useState<
    TimelineMessage["messageID"] | null
  >(hasBody ? messageID : null);
  const isBodyRevealed = hasBody && revealedBodyMessageID === messageID;
  const shouldRequestBody = !hasBody && bodyStatus !== "loading";
  const showMessageAvatar =
    showAvatar && message.direction === "incoming" && (cluster === "single" || cluster === "end");

  useEffect(() => {
    setCommittedBodyHeight(clampReservedHeight(reservedBodyHeight ?? estimatedBodyHeight));
  }, [bodyHeightCacheKey]);

  useEffect(() => {
    if (reservedBodyHeight === undefined) return;
    if (shouldDeferBodyRequest()) return;
    setCommittedBodyHeight((current) => {
      const next = clampReservedHeight(reservedBodyHeight);
      return Math.abs(current - next) > 2 ? next : current;
    });
  }, [bodyRequestWakeToken, reservedBodyHeight, shouldDeferBodyRequest]);

  useEffect(() => {
    if (!hasBody) {
      setRevealedBodyMessageID(null);
      return;
    }

    if (revealedBodyMessageID === messageID) return;
    if (shouldDeferBodyRequest()) return;

    setRevealedBodyMessageID(messageID);
  }, [
    bodyRequestWakeToken,
    hasBody,
    messageID,
    revealedBodyMessageID,
    shouldDeferBodyRequest
  ]);

  useEffect(() => {
    if (!shouldRequestBody) return;

    if (shouldDeferBodyRequest()) {
      if (debugLogEnabled) {
        debugLog("defer body request", { messageID: message.messageID });
      }
      return;
    }

    if (debugLogEnabled) {
      debugLog("request body", { messageID });
    }
    onRequestBody(message, bodyRequestPriority);
  }, [
    accountKey,
    bodyStatus,
    bodyRequestPriority,
    bodyRequestWakeToken,
    folderName,
    hasBody,
    himalayaEnvelopeID,
    messageID,
    onRequestBody,
    shouldDeferBodyRequest,
    shouldRequestBody
  ]);

  const handleMeasuredBodyHeight = useCallback((height: number) => {
    const nextHeight = clampReservedHeight(height);
    onBodyHeightMeasured(bodyHeightCacheKey, nextHeight);

    if (shouldDeferBodyRequest()) return;
    setCommittedBodyHeight((current) => {
      return Math.abs(current - nextHeight) > 2 ? nextHeight : current;
    });
  }, [bodyHeightCacheKey, onBodyHeightMeasured, shouldDeferBodyRequest]);

  return (
    <article
      className="message-row"
      data-direction={message.direction}
      data-cluster={cluster}
    >
      {showAvatar ? (
        <div
          className="message-avatar"
          aria-hidden="true"
        >
          {showMessageAvatar && message.avatarImageDataURL ? (
            <img alt="" src={message.avatarImageDataURL} />
          ) : null}
        </div>
      ) : null}
      <div className="message-card">
        <header className="message-card__header">
          {showSubject ? (
            <h2 className="message-card__subject">{message.subject || "(No subject)"}</h2>
          ) : null}
          <div className="message-card__meta" aria-label="Message details">
            <time dateTime={message.messageDate ?? undefined}>
              {formatDate(message.messageDate)}
            </time>
          </div>
        </header>

        <div
          className="mail-body-reserve"
          style={{ minHeight: committedBodyHeight }}
        >
          {!isBodyRevealed ? (
            <div className="mail-body-frame mail-body--placeholder">
              Loading message body...
            </div>
          ) : (
            <MessageBody
              debugID={message.messageID}
              html={message.sanitizedHTML}
              text={message.textFallback}
              mode={bodyDisplayMode}
              loadRemoteContent={loadRemoteContent}
              onMeasuredHeight={handleMeasuredBodyHeight}
            />
          )}
        </div>

        {message.hasAttachments ? (
          <AttachmentDownloadRow
            state={attachmentState}
            onDownload={() => onDownloadAttachments(message)}
          />
        ) : null}
      </div>
    </article>
  );
}

function estimateReservedBodyHeight(message: TimelineMessage) {
  const textLength = message.textFallback?.length
    ?? visibleTextLength(message.sanitizedHTML)
    ?? message.subject?.length
    ?? 0;
  const lineEstimate = Math.ceil(textLength / 78);
  const subjectAllowance = message.subject ? 12 : 0;
  const attachmentAllowance = message.hasAttachments ? 34 : 0;
  const directionAllowance = message.direction === "outgoing" ? 18 : 34;
  return clampReservedHeight(
    92 + subjectAllowance + attachmentAllowance + directionAllowance + lineEstimate * 18,
    MAX_ESTIMATED_BODY_HEIGHT
  );
}

function visibleTextLength(html?: string | null) {
  if (!html) return undefined;
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim().length;
}

function clampReservedHeight(height: number, maxHeight = MAX_CACHED_BODY_HEIGHT) {
  return Math.max(MIN_RESERVED_BODY_HEIGHT, Math.min(Math.ceil(height), maxHeight));
}

function AttachmentDownloadRow({
  state,
  onDownload
}: {
  state: AttachmentDownloadState;
  onDownload(): void;
}) {
  const disabled = state.status === "downloading" || state.status === "downloaded";

  return (
    <div className="attachment-row">
      <span className="attachment-row__icon" aria-hidden="true">
        &#128206;
      </span>
      <div className="attachment-row__content">
        <AttachmentDownloadSummary state={state} />
      </div>
      <button
        className="attachment-row__button"
        type="button"
        disabled={disabled}
        onClick={onDownload}
      >
        {attachmentButtonText(state)}
      </button>
    </div>
  );
}

function AttachmentDownloadSummary({ state }: { state: AttachmentDownloadState }) {
  if (state.status === "downloaded") {
    const fileNames = state.result.fileNames;
    return (
      <>
        <div className="attachment-row__title">
          {fileNames.length > 0 ? fileNames.slice(0, 4).join(", ") : "Files saved"}
          {fileNames.length > 4 ? `, +${fileNames.length - 4} more` : ""}
        </div>
        <div className="attachment-row__detail">{state.result.directoryPath}</div>
      </>
    );
  }

  if (state.status === "failed") {
    return (
      <>
        <div className="attachment-row__title">Attachment files</div>
        <div className="attachment-row__detail attachment-row__detail--error">
          {state.message}
        </div>
      </>
    );
  }

  if (state.status === "downloading") {
    return <div className="attachment-row__title">Attachment files</div>;
  }

  return (
    <>
      <div className="attachment-row__title">Attachment files</div>
      <div className="attachment-row__detail">Ready to download</div>
    </>
  );
}

function attachmentButtonText(state: AttachmentDownloadState) {
  switch (state.status) {
    case "downloading":
      return "Downloading...";
    case "downloaded":
      return "Downloaded";
    case "failed":
    case "idle":
      return "Download";
  }
}

function formatDate(value?: string | null) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;

  return new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit"
  }).format(date);
}
