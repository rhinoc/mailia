import { useEffect } from "react";
import type { AttachmentDownloadState, BodyDisplayMode, TimelineMessage } from "../types";
import { MessageBody } from "./MessageBody";

interface MessageCardProps {
  message: TimelineMessage;
  showSubject: boolean;
  cluster: "single" | "start" | "middle" | "end";
  bodyDisplayMode: BodyDisplayMode;
  attachmentState: AttachmentDownloadState;
  onRequestBody(message: TimelineMessage): void;
  onDownloadAttachments(message: TimelineMessage): void;
}

export function MessageCard({
  message,
  showSubject,
  cluster,
  bodyDisplayMode,
  attachmentState,
  onRequestBody,
  onDownloadAttachments
}: MessageCardProps) {
  const hasBody = Boolean(message.sanitizedHTML || message.textFallback);
  const shouldRequestBody = !hasBody && message.bodyStatus !== "loading";
  const showAvatar =
    message.direction === "incoming" && (cluster === "single" || cluster === "end");

  useEffect(() => {
    if (shouldRequestBody) {
      console.warn("[MailiaTimelineWebDebug] request body", {
        messageID: message.messageID,
        subject: message.subject ?? null
      });
      onRequestBody(message);
    }
  }, [message, onRequestBody, shouldRequestBody]);

  return (
    <article
      className="message-row"
      data-direction={message.direction}
      data-cluster={cluster}
    >
      <div
        className="message-avatar"
        aria-hidden="true"
      >
        {showAvatar && message.avatarImageDataURL ? (
          <img alt="" src={message.avatarImageDataURL} />
        ) : null}
      </div>
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

        {message.bodyStatus === "loading" && !hasBody ? (
          <div className="mail-body-frame mail-body--placeholder">Loading message body...</div>
        ) : (
          <MessageBody
            html={message.sanitizedHTML}
            text={message.textFallback}
            mode={bodyDisplayMode}
          />
        )}

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
