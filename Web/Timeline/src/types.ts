export type MessageDirection = "incoming" | "outgoing";

export type EntityKind =
  | "person"
  | "organization"
  | "service"
  | "newsletter"
  | "unknown";

export type WorkspaceKind = "main" | "junk" | "flagged";
export type BodyDisplayMode = "html" | "markdown";

export type TimelineBodyState =
  | { status: "notRequested" }
  | { status: "loading" }
  | { status: "loaded"; body: TimelineBody }
  | { status: "failed"; message: string };

export type AttachmentDownloadState =
  | { status: "idle" }
  | { status: "downloading" }
  | { status: "downloaded"; result: AttachmentDownloadResult }
  | { status: "failed"; message: string };

export type ReplySendState =
  | { status: "idle" }
  | { status: "sending" }
  | { status: "sent" }
  | { status: "failed"; message: string };

export interface TimelineState {
  entity: TimelineEntity | null;
  items: TimelineItem[];
  isLoadingTimeline: boolean;
  isLoadingOlderTimeline: boolean;
  isLoadingNewerTimeline: boolean;
  hasOlderTimeline: boolean;
  hasNewerTimeline: boolean;
  bodyStates: Record<string, TimelineBodyState>;
  attachmentDownloadStates: Record<string, AttachmentDownloadState>;
  replySendState: ReplySendState;
  sendAccounts: SendAccount[];
  selectedSendAccountKey?: string | null;
  scrollAnchor?: TimelineScrollAnchor | null;
  displayOptions: TimelineDisplayOptions;
  windowState: TimelineWindowState;
}

export interface TimelineDisplayOptions {
  bodyDisplayMode: BodyDisplayMode | string;
  loadRemoteContent: boolean;
  showTimelineAvatars: boolean;
  showOwnTimelineAvatars: boolean;
  hideQuotedReplyText: boolean;
  hideReplySubjects: boolean;
}

export interface TimelineWindowState {
  bottomOverlayHeight: number;
}

export interface TimelineEntity {
  id: number;
  displayName: string;
  primaryEmailAddress?: string | null;
  emailAddresses: string[];
  kind: EntityKind | string;
  unreadCount: number;
  latestSubject: string;
  latestBodyPreview?: string | null;
  latestDate?: string | null;
  accountLabel: string;
  workspace: WorkspaceKind | string;
  avatarImageDataURL?: string | null;
}

export interface TimelineItem {
  id: number;
  entityID: number;
  direction: MessageDirection | string;
  subject: string;
  preview: string;
  html?: string | null;
  date?: string | null;
  accountLabel: string;
  accountEmoji?: string | null;
  accountAvatarImageDataURL?: string | null;
  folderLabel: string;
  envelopeID: string;
  isFlagged: boolean;
  fromLabel: string;
  toLabel: string;
  hasAttachments: boolean;
}

export interface SendAccount {
  id: string;
  label: string;
  emailAddress?: string | null;
  isDefault: boolean;
  emoji?: string | null;
}

export interface TimelineBody {
  html?: string | null;
  text?: string | null;
}

export interface AttachmentDownloadResult {
  directoryPath: string;
  fileNames: string[];
}

export interface TimelineScrollAnchor {
  id: number;
  edge: "top" | "bottom";
  generation: number;
}

export interface TimelineEntityOption {
  id: number;
  name: string;
  kind: EntityKind;
  primaryAddress?: string | null;
  detail?: string | null;
  unreadCount: number;
  lastMessageAt?: string | null;
  avatarImageDataURL?: string | null;
}

export interface TimelineMessageView {
  messageID: TimelineItem["id"];
  accountKey: string;
  folderName?: string | null;
  himalayaEnvelopeID?: string | null;
  flags: string[];
  subject?: string | null;
  fromLabel?: string | null;
  toLabel?: string | null;
  messageDate?: string | null;
  direction: MessageDirection;
  hasAttachments: boolean;
  bodyStatus?: TimelineBodyState["status"];
  sanitizedHTML?: string | null;
  textFallback?: string | null;
  avatarSeed?: string | null;
  avatarName?: string | null;
  avatarEmoji?: string | null;
  avatarImageDataURL?: string | null;
}
