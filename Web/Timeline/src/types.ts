export type FolderRole =
  | "normal"
  | "sent"
  | "junk"
  | "trash"
  | "drafts"
  | "outbox"
  | "unknown";

export type MessageDirection = "incoming" | "outgoing";

export type EntityKind =
  | "person"
  | "organization"
  | "service"
  | "newsletter"
  | "unknown";

export type WorkspaceKind = "main" | "junk" | "flagged";
export type BodyDisplayMode = "html" | "markdown";

export type AttachmentDownloadState =
  | { status: "idle" }
  | { status: "downloading" }
  | { status: "downloaded"; result: { directoryPath: string; fileNames: string[] } }
  | { status: "failed"; message: string };

export interface MailAddress {
  displayName?: string | null;
  emailAddress: string;
}

export interface TimelineEntity {
  id: string;
  name: string;
  kind: EntityKind;
  primaryAddress?: string | null;
  emailAddresses?: string[];
  detail?: string | null;
  messageCount: number;
  unreadCount: number;
  lastMessageAt?: string | null;
  sourceAccounts: string[];
  avatarImageDataURL?: string | null;
}

export interface TimelineMessage {
  messageID: number | string;
  accountKey: string;
  folderName?: string | null;
  folderRole?: FolderRole | null;
  himalayaEnvelopeID?: string | null;
  flags: string[];
  subject?: string | null;
  from?: MailAddress | null;
  to: MailAddress[];
  cc: MailAddress[];
  messageDate?: string | null;
  direction: MessageDirection;
  hasAttachments: boolean;
  bodyStatus?: "notRequested" | "loading" | "loaded" | "failed";
  sanitizedHTML?: string | null;
  textFallback?: string | null;
  avatarSeed?: string | null;
  avatarName?: string | null;
  avatarImageDataURL?: string | null;
}

export interface TimelineScrollAnchor {
  id: TimelineMessage["messageID"];
  edge: "top" | "bottom";
  generation: number;
}

export interface TimelineState {
  workspace: WorkspaceKind;
  entities: TimelineEntity[];
  selectedEntityID?: string | null;
  messages: TimelineMessage[];
  isLoading: boolean;
  isLoadingOlderMessages?: boolean;
  isLoadingNewerMessages?: boolean;
  error?: string | null;
  syncStatus?: string | null;
  hasOlderMessages?: boolean;
  anchoredToBottom?: boolean;
  scrollAnchor?: TimelineScrollAnchor | null;
  bodyDisplayMode: BodyDisplayMode;
  loadRemoteContent: boolean;
  showTimelineAvatars: boolean;
  attachmentDownloadStates?: Record<string, AttachmentDownloadState>;
}
