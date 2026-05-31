const DEBUG_PREFIX = "[MailiaTimelineWebDebug]";

declare const __MAILIA_TIMELINE_DEBUG__: boolean;

export const debugLogEnabled = __MAILIA_TIMELINE_DEBUG__;

export function debugLog(message: string, detail?: Record<string, unknown>) {
  if (!debugLogEnabled) return;

  const payload = detail ? `${message} ${safeStringify(detail)}` : message;

  try {
    window.webkit?.messageHandlers?.mailiaTimeline?.postMessage({
      type: "log",
      payload: {
        level: "debug",
        message: `${DEBUG_PREFIX} ${payload}`
      }
    } as never);
  } catch {
    // The dev bridge does not expose the native message handler.
  }

  console.debug(DEBUG_PREFIX, message, detail ?? "");
}

function safeStringify(value: unknown) {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}
