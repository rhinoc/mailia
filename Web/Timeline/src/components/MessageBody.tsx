import { useLayoutEffect, useMemo, useRef } from "react";
import DOMPurify, { type Config as DOMPurifyConfig } from "dompurify";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import TurndownService from "turndown";
import type { BodyDisplayMode } from "../types";

const REMOTE_IMAGE_PLACEHOLDER =
  "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==";
const REMOTE_IMAGE_PLACEHOLDER_CLASS = "mailia-remote-image-placeholder";
const LEGACY_REMOTE_IMAGE_PLACEHOLDER_CLASS = "mail-body__blocked-image";
const BLOCKED_REMOTE_IMAGE_LABEL = "Remote image blocked";
const turndown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "fenced"
});
const HTML_SANITIZER_CONFIG: DOMPurifyConfig = {
  USE_PROFILES: { html: true },
  FORBID_TAGS: [
    "audio",
    "base",
    "button",
    "embed",
    "form",
    "iframe",
    "input",
    "link",
    "meta",
    "object",
    "option",
    "picture",
    "script",
    "select",
    "source",
    "style",
    "textarea",
    "track",
    "video"
  ],
  FORBID_ATTR: ["srcdoc"],
  ALLOW_UNKNOWN_PROTOCOLS: false,
  SANITIZE_DOM: true,
  SANITIZE_NAMED_PROPS: true,
  RETURN_TRUSTED_TYPE: false
};

turndown.addRule("blockedRemoteImage", {
  filter(node) {
    const classList = node.nodeType === 1
      ? (node as Element).classList
      : null;

    return (
      classList !== null &&
      (
        classList.contains(REMOTE_IMAGE_PLACEHOLDER_CLASS) ||
        classList.contains(LEGACY_REMOTE_IMAGE_PLACEHOLDER_CLASS)
      )
    );
  },
  replacement() {
    return " ";
  }
});

turndown.addRule("hiddenEmailNoise", {
  filter(node) {
    if (node.nodeType !== 1) return false;

    const element = node as Element;
    const style = element.getAttribute("style") ?? "";
    return isHiddenEmailElementStyle(style);
  },
  replacement() {
    return "";
  }
});

turndown.addRule("compactLink", {
  filter: "a",
  replacement(content, node) {
    const element = node as Element;
    const href = element.getAttribute("href")?.trim();
    const label = compactMarkdownText(content);
    if (!href) return label;
    if (!label) return "";

    return `[${escapeMarkdownLinkText(label)}](${href})`;
  }
});

function markdownComponents(loadRemoteContent: boolean): Components {
  return {
    h1({ node: _node, ...props }) {
      return <h1 className="mail-markdown__heading mail-markdown__heading--1" {...props} />;
    },
    h2({ node: _node, ...props }) {
      return <h2 className="mail-markdown__heading mail-markdown__heading--2" {...props} />;
    },
    h3({ node: _node, ...props }) {
      return <h3 className="mail-markdown__heading mail-markdown__heading--3" {...props} />;
    },
    p({ node: _node, ...props }) {
      return <p className="mail-markdown__paragraph" {...props} />;
    },
    ul({ node: _node, ...props }) {
      return <ul className="mail-markdown__list" {...props} />;
    },
    ol({ node: _node, ...props }) {
      return <ol className="mail-markdown__list mail-markdown__list--ordered" {...props} />;
    },
    li({ node: _node, ...props }) {
      return <li className="mail-markdown__list-item" {...props} />;
    },
    blockquote({ node: _node, ...props }) {
      return <blockquote className="mail-markdown__quote" {...props} />;
    },
    code({ node: _node, className, ...props }) {
      return <code className={classNames("mail-markdown__code", className)} {...props} />;
    },
    pre({ node: _node, ...props }) {
      return <pre className="mail-markdown__pre" {...props} />;
    },
    a({ node: _node, ...props }) {
      return <a className="mail-markdown__link" rel="noreferrer" {...props} />;
    },
    img({ node: _node, src, alt, ...props }) {
      if (!loadRemoteContent && src === REMOTE_IMAGE_PLACEHOLDER) {
        return <span className="mail-markdown__blocked-image" aria-label={BLOCKED_REMOTE_IMAGE_LABEL} />;
      }

      if (loadRemoteContent || !isRemoteURL(src)) {
        return <img className="mail-markdown__image" src={src} alt={alt ?? ""} {...props} />;
      }

      return <span className="mail-markdown__blocked-image" aria-label={BLOCKED_REMOTE_IMAGE_LABEL} />;
    },
    hr({ node: _node, ...props }) {
      return <hr className="mail-markdown__rule" {...props} />;
    }
  };
}

interface MessageBodyProps {
  html?: string | null;
  text?: string | null;
  mode: BodyDisplayMode;
  loadRemoteContent: boolean;
  hideQuotedReplyText: boolean;
  onMeasuredHeight?(height: number): void;
}

export function MessageBody({
  html,
  text,
  mode,
  loadRemoteContent,
  hideQuotedReplyText,
  onMeasuredHeight
}: MessageBodyProps) {
  const markdownFrameRef = useRef<HTMLDivElement>(null);
  const displayText = useMemo(() => {
    if (!text) return "";
    return hideQuotedReplyText ? stripTrailingQuotedReplyText(text) : text;
  }, [hideQuotedReplyText, text]);

  const normalizedHTML = useMemo(() => {
    if (html) return html;
    if (!text) return "<p>No body content is available for this message.</p>";
    if (!displayText.trim()) return "";

    return `<pre>${escapeHTML(displayText)}</pre>`;
  }, [displayText, html, text]);

  const sanitizedHTML = useMemo(
    () => sanitizeEmailHTML(normalizedHTML, hideQuotedReplyText),
    [hideQuotedReplyText, normalizedHTML]
  );

  const displayHTML = useMemo(() => {
    if (loadRemoteContent) return sanitizedHTML;
    return blockRemoteImages(sanitizedHTML);
  }, [loadRemoteContent, sanitizedHTML]);

  const markdown = useMemo(() => {
    if (mode !== "markdown") return "";
    if (html) return turndown.turndown(displayHTML).trim();
    if (text) return displayText.trim();
    return "No body content is available for this message.";
  }, [displayHTML, displayText, html, mode, text]);

  const markdownRenderers = useMemo(
    () => markdownComponents(loadRemoteContent),
    [loadRemoteContent]
  );

  if (mode === "markdown") {
    return (
      <div
        ref={markdownFrameRef}
        className="mail-body-frame mail-body-frame--markdown"
      >
        <div className="mail-markdown">
          <ReactMarkdown components={markdownRenderers}>{markdown}</ReactMarkdown>
        </div>
        <MeasuredHeightReporter
          targetRef={markdownFrameRef}
          contentSignature={markdown}
          onMeasuredHeight={onMeasuredHeight}
        />
      </div>
    );
  }

  return <HTMLMessageBody displayHTML={displayHTML} onMeasuredHeight={onMeasuredHeight} />;
}

function HTMLMessageBody({
  displayHTML,
  onMeasuredHeight
}: {
  displayHTML: string;
  onMeasuredHeight?(height: number): void;
}) {
  const frameRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);

  useHTMLBodyFit(frameRef, contentRef, displayHTML);

  return (
    <div className="mail-body-frame" ref={frameRef}>
      <div className="mail-body mail-body--html">
        <div
          ref={contentRef}
          className="mail-body__content"
          dangerouslySetInnerHTML={{ __html: displayHTML }}
        />
      </div>
      <MeasuredHeightReporter
        targetRef={frameRef}
        contentSignature={displayHTML}
        onMeasuredHeight={onMeasuredHeight}
      />
    </div>
  );
}

function MeasuredHeightReporter({
  targetRef,
  contentSignature,
  onMeasuredHeight
}: {
  targetRef: React.RefObject<HTMLDivElement | null>;
  contentSignature: string;
  onMeasuredHeight?: (height: number) => void;
}) {
  useLayoutEffect(() => {
    const target = targetRef.current;
    if (!target || !onMeasuredHeight) return;

    let cancelled = false;
    let rafID = 0;

    const measure = () => {
      if (cancelled) return;
      const height = Math.ceil(Math.max(target.scrollHeight, target.getBoundingClientRect().height));
      if (height > 1) {
        onMeasuredHeight(height);
      }
    };

    const scheduleMeasure = () => {
      cancelAnimationFrame(rafID);
      rafID = requestAnimationFrame(measure);
    };

    scheduleMeasure();

    const resizeObserver = new ResizeObserver(scheduleMeasure);
    resizeObserver.observe(target);

    const mutationObserver = new MutationObserver(scheduleMeasure);
    mutationObserver.observe(target, {
      childList: true,
      subtree: true
    });

    target.addEventListener("load", scheduleMeasure, true);

    return () => {
      cancelled = true;
      cancelAnimationFrame(rafID);
      resizeObserver.disconnect();
      mutationObserver.disconnect();
      target.removeEventListener("load", scheduleMeasure, true);
    };
  }, [contentSignature, onMeasuredHeight, targetRef]);

  return null;
}

function useHTMLBodyFit(
  frameRef: React.RefObject<HTMLDivElement | null>,
  contentRef: React.RefObject<HTMLDivElement | null>,
  displayHTML: string
) {
  useLayoutEffect(() => {
    const frame = frameRef.current;
    const content = contentRef.current;
    if (!frame || !content) return;

    let cancelled = false;
    let rafID = 0;

    const applyFit = () => {
      if (cancelled) return;

      content.style.zoom = "1";
      const availableWidth = content.clientWidth;
      if (availableWidth <= 1) return;

      const cheapContentWidth = Math.max(content.scrollWidth, content.offsetWidth, 1);
      const contentWidth = cheapContentWidth > availableWidth + 1
        ? measureHTMLContentWidth(content)
        : cheapContentWidth;
      const zoom = fitHTMLZoom(contentWidth, availableWidth);
      content.style.zoom = zoom === 1 ? "" : String(zoom);
    };

    const scheduleFit = () => {
      cancelAnimationFrame(rafID);
      rafID = requestAnimationFrame(applyFit);
    };

    scheduleFit();

    const resizeObserver = new ResizeObserver(scheduleFit);
    resizeObserver.observe(frame);

    const mutationObserver = new MutationObserver(scheduleFit);
    mutationObserver.observe(content, {
      childList: true,
      subtree: true
    });

    const onImageLoad = (event: Event) => {
      if (event.target instanceof HTMLImageElement && content.contains(event.target)) {
        scheduleFit();
      }
    };

    content.addEventListener("load", onImageLoad, true);
    for (const image of content.querySelectorAll("img")) {
      if (!image.complete) {
        image.addEventListener("load", scheduleFit, { once: true });
        image.addEventListener("error", scheduleFit, { once: true });
      }
    }

    return () => {
      cancelled = true;
      cancelAnimationFrame(rafID);
      resizeObserver.disconnect();
      mutationObserver.disconnect();
      content.removeEventListener("load", onImageLoad, true);
      content.style.zoom = "";
    };
  }, [contentRef, displayHTML, frameRef]);
}

function measureHTMLContentWidth(root: HTMLElement) {
  const rootRect = root.getBoundingClientRect();
  let width = Math.max(root.scrollWidth, root.offsetWidth, 1);

  for (const element of root.querySelectorAll("*")) {
    const style = window.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden") continue;

    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;

    width = Math.max(width, rect.right - rootRect.left);
  }

  return width;
}

function fitHTMLZoom(contentWidth: number, availableWidth: number) {
  if (contentWidth <= availableWidth + 1) return 1;
  return Math.min(1, availableWidth / contentWidth);
}

function escapeHTML(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function compactMarkdownText(value: string) {
  return value
    .replace(/[\u200B-\u200D\uFEFF]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function escapeMarkdownLinkText(value: string) {
  return value.replace(/([\\\[\]])/g, "\\$1");
}

function isHiddenEmailElementStyle(style: string) {
  const declarations = style
    .split(";")
    .map((declaration) => {
      const [rawProperty, ...rawValue] = declaration.split(":");
      return {
        property: rawProperty?.trim().toLowerCase(),
        value: rawValue.join(":").trim().toLowerCase()
      };
    })
    .filter((declaration) => declaration.property && declaration.value);

  return declarations.some(({ property, value }) => (
    (property === "display" && value.startsWith("none")) ||
    (property === "max-height" && value.startsWith("0")) ||
    (property === "max-width" && value.startsWith("0")) ||
    (property === "opacity" && value.startsWith("0")) ||
    (property === "font-size" && value.startsWith("0"))
  ));
}

function classNames(...values: Array<string | undefined>) {
  return values.filter(Boolean).join(" ");
}

function sanitizeEmailHTML(html: string, hideQuotedReplyText: boolean) {
  const sanitized = DOMPurify.sanitize(html, HTML_SANITIZER_CONFIG);
  const template = document.createElement("template");
  template.innerHTML = sanitized;

  normalizeSanitizedEmailDOM(template.content);
  if (hideQuotedReplyText) {
    stripQuotedReplyHTML(template.content);
  }
  return template.innerHTML;
}

function normalizeSanitizedEmailDOM(root: DocumentFragment) {
  for (const element of Array.from(root.querySelectorAll("*"))) {
    removeUnsafeInlineStyle(element);
    sanitizeEmailURLAttributes(element);
  }
}

function removeUnsafeInlineStyle(element: Element) {
  const style = element.getAttribute("style");
  if (!style) return;

  if (!isSafeInlineStyle(style)) {
    element.removeAttribute("style");
  }
}

function isSafeInlineStyle(style: string) {
  const lowercased = style.toLowerCase();
  return !(
    lowercased.includes("url(") ||
    lowercased.includes("@import") ||
    lowercased.includes("expression(") ||
    lowercased.includes("behavior:")
  );
}

function sanitizeEmailURLAttributes(element: Element) {
  if (element.localName === "a") {
    const href = element.getAttribute("href");
    if (href && !isAllowedLinkURL(href)) {
      element.removeAttribute("href");
    }
  }

  for (const attribute of ["action", "background", "formaction", "poster"]) {
    element.removeAttribute(attribute);
  }
}

function stripTrailingQuotedReplyText(text: string) {
  const normalized = text
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n");
  const lines = normalized.split("\n");

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (!isReplyAttributionLine(lines[index])) continue;

    const followingLines = lines.slice(index + 1);
    const nonBlankFollowingLines = followingLines.filter((line) => line.trim() !== "");
    if (nonBlankFollowingLines.length === 0) continue;
    if (!nonBlankFollowingLines.every(isQuotedTextLine)) continue;

    const keptLines = lines.slice(0, index);
    while (keptLines.length > 0 && keptLines.at(-1)?.trim() === "") {
      keptLines.pop();
    }
    return keptLines.join("\n");
  }

  return text;
}

function isReplyAttributionLine(line: string) {
  return /^On\s+.+\swrote:\s*$/i.test(line.trim());
}

function isQuotedTextLine(line: string) {
  return line.trimStart().startsWith(">");
}

function stripQuotedReplyHTML(root: DocumentFragment) {
  removeOutlookQuotedReplyHTML(root);
  removeKnownQuotedReplyContainers(root);
}

function removeOutlookQuotedReplyHTML(root: DocumentFragment) {
  for (const header of Array.from(root.querySelectorAll('[id$="divRplyFwdMsg"]'))) {
    if (!isOutlookReplyHeader(header)) continue;

    removeNodeAndFollowingSiblings(outlookReplyStartNode(header));
  }
}

function isOutlookReplyHeader(element: Element) {
  const text = compactMarkdownText(element.textContent ?? "").toLowerCase();
  const labels = [
    "from:",
    "sent:",
    "to:",
    "subject:",
    "发件人:",
    "发送时间:",
    "收件人:",
    "主题:"
  ];
  return labels.filter((label) => text.includes(label.toLowerCase())).length >= 3;
}

function outlookReplyStartNode(header: Element) {
  const previous = previousElementSibling(header);
  if (previous?.localName === "hr") {
    const beforeRule = previousElementSibling(previous);
    if (beforeRule && hasIDEnding(beforeRule, "appendonsend")) {
      return beforeRule;
    }
    return previous;
  }

  const beforeHeader = previousElementSibling(header);
  if (beforeHeader && hasIDEnding(beforeHeader, "appendonsend")) {
    return beforeHeader;
  }

  return header;
}

function hasIDEnding(element: Element | null | undefined, suffix: string) {
  return element?.id.toLowerCase().endsWith(suffix.toLowerCase()) === true;
}

function previousElementSibling(element: Element) {
  let sibling = element.previousSibling;
  while (sibling) {
    if (sibling.nodeType === Node.ELEMENT_NODE) {
      return sibling as Element;
    }
    if ((sibling.textContent ?? "").trim() !== "") {
      return null;
    }
    sibling = sibling.previousSibling;
  }
  return null;
}

function removeNodeAndFollowingSiblings(node: ChildNode) {
  let current: ChildNode | null = node;
  while (current) {
    const next: ChildNode | null = current.nextSibling;
    current.remove();
    current = next;
  }
}

function removeKnownQuotedReplyContainers(root: DocumentFragment) {
  const selectors = [
    ".gmail_quote",
    ".gmail_extra",
    "blockquote[type='cite']"
  ];

  for (const element of Array.from(root.querySelectorAll(selectors.join(",")))) {
    element.remove();
  }
}

function isAllowedLinkURL(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return true;
  if (/[\u0000-\u001F\u007F]/.test(trimmed)) return false;
  if (trimmed.startsWith("#")) return true;
  if (trimmed.startsWith("/") && !trimmed.startsWith("//")) return true;

  const schemeMatch = /^[A-Za-z][A-Za-z0-9+.-]*:/.exec(trimmed);
  if (!schemeMatch) return !trimmed.startsWith("//");

  return ["http:", "https:", "mailto:"].includes(schemeMatch[0].toLowerCase());
}

function blockRemoteImages(html: string) {
  const template = document.createElement("template");
  template.innerHTML = html;

  for (const image of Array.from(template.content.querySelectorAll("img"))) {
    const src = image.getAttribute("src") ?? "";
    const srcset = image.getAttribute("srcset") ?? "";
    if (!isRemoteURL(src) && !srcsetContainsRemoteURL(srcset)) continue;

    const placeholder = remoteImagePlaceholder(image);
    const imageOnlyLink = imageOnlyLinkParent(image);
    if (imageOnlyLink) {
      imageOnlyLink.replaceWith(placeholder);
    } else {
      image.replaceWith(placeholder);
    }
  }

  return template.innerHTML;
}

function imageOnlyLinkParent(image: HTMLImageElement) {
  const parent = image.parentElement;
  if (!parent || parent.localName !== "a" || !parent.parentNode) return null;

  for (const child of Array.from(parent.childNodes)) {
    if (child === image) continue;
    if (child.nodeType === Node.TEXT_NODE && (child.textContent ?? "").trim() === "") continue;
    if (child.nodeType === Node.COMMENT_NODE) continue;
    return null;
  }

  return parent;
}

function remoteImagePlaceholder(image: HTMLImageElement) {
  const placeholder = document.createElement("span");
  placeholder.className = REMOTE_IMAGE_PLACEHOLDER_CLASS;
  placeholder.setAttribute("role", "img");
  placeholder.setAttribute("aria-label", BLOCKED_REMOTE_IMAGE_LABEL);
  placeholder.textContent = " ";
  placeholder.setAttribute("style", preservedImageBoxStyle(image));
  return placeholder;
}

function preservedImageBoxStyle(image: HTMLImageElement) {
  const declarations = new Map<string, string>();
  for (const declaration of (image.getAttribute("style") ?? "").split(";")) {
    const [rawProperty, ...rawValue] = declaration.split(":");
    const property = rawProperty?.trim().toLowerCase();
    const value = rawValue.join(":").trim();
    if (!property || !value) continue;
    if (!isSafeBoxDeclaration(property, value)) continue;
    declarations.set(property, value);
  }

  const width = sanitizedDimension(image.getAttribute("width"));
  const height = sanitizedDimension(image.getAttribute("height"));
  if (width && !declarations.has("width")) declarations.set("width", width);
  if (height && !declarations.has("height")) declarations.set("height", height);
  declarations.set("display", "inline-flex");
  if (!declarations.has("vertical-align")) declarations.set("vertical-align", "middle");
  if (!declarations.has("width")) declarations.set("min-width", declarations.get("min-width") ?? "120px");
  if (!declarations.has("height")) declarations.set("min-height", declarations.get("min-height") ?? "32px");

  return Array.from(declarations.entries())
    .map(([property, value]) => `${property}: ${value}`)
    .join("; ");
}

function isSafeBoxDeclaration(property: string, value: string) {
  return (
    [
      "width",
      "height",
      "min-width",
      "min-height",
      "max-width",
      "max-height",
      "display",
      "vertical-align"
    ].includes(property) && isSafeCSSValue(value)
  );
}

function isSafeCSSValue(value: string) {
  const lowercased = value.toLowerCase();
  return !(
    lowercased.includes("url(") ||
    lowercased.includes("@import") ||
    lowercased.includes("expression(") ||
    lowercased.includes("behavior:") ||
    lowercased.includes("!important")
  );
}

function sanitizedDimension(value: string | null) {
  const trimmed = value?.trim() ?? "";
  return /^\d{1,5}(\.\d{1,2})?$/.test(trimmed) ? `${trimmed}px` : null;
}

function isRemoteURL(value?: string | null) {
  const trimmed = value?.trim() ?? "";
  return /^https?:\/\//i.test(trimmed) || trimmed.startsWith("//");
}

function srcsetContainsRemoteURL(value: string) {
  return value
    .split(",")
    .map((candidate) => candidate.trim().split(/\s+/)[0] ?? "")
    .some(isRemoteURL);
}
