import { memo, useLayoutEffect, useMemo, useRef } from "react";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import TurndownService from "turndown";
import type { BodyDisplayMode, TimelineHTMLVariants } from "../types";

const REMOTE_IMAGE_PLACEHOLDER_CLASS = "mailia-remote-image-placeholder";
const turndown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "fenced"
});
const MAX_CONTENT_WIDTH_CACHE_ENTRIES = 500;
const htmlContentWidthCache = new Map<string, number>();

turndown.addRule("blockedRemoteImage", {
  filter(node) {
    const classList = node.nodeType === 1
      ? (node as Element).classList
      : null;

    return (
      classList !== null &&
      classList.contains(REMOTE_IMAGE_PLACEHOLDER_CLASS)
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

function markdownComponents(): Components {
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
      return <img className="mail-markdown__image" src={src} alt={alt ?? ""} {...props} />;
    },
    hr({ node: _node, ...props }) {
      return <hr className="mail-markdown__rule" {...props} />;
    }
  };
}

interface MessageBodyProps {
  html?: string | null;
  htmlVariants?: TimelineHTMLVariants | null;
  mode: BodyDisplayMode;
  loadRemoteContent: boolean;
  hideQuotedReplyText: boolean;
  onMeasuredHeight?(height: number): void;
}

export const MessageBody = memo(function MessageBody({
  html,
  htmlVariants,
  mode,
  loadRemoteContent,
  hideQuotedReplyText,
  onMeasuredHeight
}: MessageBodyProps) {
  const markdownFrameRef = useRef<HTMLDivElement>(null);
  const displayHTML = useMemo(() => {
    return displayHTMLForOptions(html, htmlVariants, loadRemoteContent, hideQuotedReplyText);
  }, [hideQuotedReplyText, html, htmlVariants, loadRemoteContent]);

  const markdown = useMemo(() => {
    if (mode !== "markdown") return "";
    return turndown.turndown(displayHTML).trim() || "No body content is available for this message.";
  }, [displayHTML, mode]);

  const markdownRenderers = useMemo(() => markdownComponents(), []);

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
});

const HTMLMessageBody = memo(function HTMLMessageBody({
  displayHTML,
  onMeasuredHeight
}: {
  displayHTML: string;
  onMeasuredHeight?(height: number): void;
}) {
  const frameRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const dangerousHTML = useMemo(
    () => ({ __html: displayHTML }),
    [displayHTML]
  );

  useHTMLBodyFit(frameRef, contentRef, displayHTML);

  return (
    <div className="mail-body-frame" ref={frameRef}>
      <div className="mail-body mail-body--html">
        <div
          ref={contentRef}
          className="mail-body__content"
          dangerouslySetInnerHTML={dangerousHTML}
        />
      </div>
      <MeasuredHeightReporter
        targetRef={frameRef}
        contentSignature={displayHTML}
        onMeasuredHeight={onMeasuredHeight}
      />
    </div>
  );
});

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

    target.addEventListener("load", scheduleMeasure, true);

    return () => {
      cancelled = true;
      cancelAnimationFrame(rafID);
      resizeObserver.disconnect();
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
    let observedFrameWidth = Math.round(frame.getBoundingClientRect().width);

    const applyFit = () => {
      if (cancelled) return;

      content.style.zoom = "1";
      const availableWidth = content.clientWidth;
      if (availableWidth <= 1) return;

      const cheapContentWidth = Math.max(content.scrollWidth, content.offsetWidth, 1);
      const contentWidth = cheapContentWidth > availableWidth + 1
        ? cachedHTMLContentWidth(content, displayHTML, availableWidth)
        : cheapContentWidth;
      const zoom = fitHTMLZoom(contentWidth, availableWidth);
      content.style.zoom = zoom === 1 ? "" : String(zoom);
    };

    const scheduleFit = () => {
      cancelAnimationFrame(rafID);
      rafID = requestAnimationFrame(applyFit);
    };

    scheduleFit();

    const resizeObserver = new ResizeObserver((entries) => {
      const width = Math.round(entries[0]?.contentRect.width ?? frame.getBoundingClientRect().width);
      if (Math.abs(width - observedFrameWidth) <= 1) return;

      observedFrameWidth = width;
      scheduleFit();
    });
    resizeObserver.observe(frame);

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
      content.removeEventListener("load", onImageLoad, true);
      content.style.zoom = "";
    };
  }, [contentRef, displayHTML, frameRef]);
}

function cachedHTMLContentWidth(root: HTMLElement, displayHTML: string, availableWidth: number) {
  const key = `${htmlCacheKey(displayHTML)}:${Math.round(availableWidth)}`;
  const cachedWidth = htmlContentWidthCache.get(key);
  if (cachedWidth !== undefined) {
    htmlContentWidthCache.delete(key);
    htmlContentWidthCache.set(key, cachedWidth);
    return cachedWidth;
  }

  const width = measureHTMLContentWidth(root);
  htmlContentWidthCache.set(key, width);
  if (htmlContentWidthCache.size > MAX_CONTENT_WIDTH_CACHE_ENTRIES) {
    const oldestKey = htmlContentWidthCache.keys().next().value;
    if (oldestKey !== undefined) {
      htmlContentWidthCache.delete(oldestKey);
    }
  }
  return width;
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

function htmlCacheKey(value: string) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${value.length}:${hash >>> 0}`;
}

function fitHTMLZoom(contentWidth: number, availableWidth: number) {
  if (contentWidth <= availableWidth + 1) return 1;
  return Math.min(1, availableWidth / contentWidth);
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

function displayHTMLForOptions(
  html: string | null | undefined,
  variants: TimelineHTMLVariants | null | undefined,
  loadRemoteContent: boolean,
  hideQuotedReplyText: boolean
) {
  if (!html) return "<p>No body content is available for this message.</p>";
  if (hideQuotedReplyText && !loadRemoteContent) {
    return variants?.quotedReplyHiddenRemoteContentBlockedHTML ?? "";
  }
  if (hideQuotedReplyText) {
    return variants?.quotedReplyHiddenHTML ?? "";
  }
  if (!loadRemoteContent) {
    return variants?.remoteContentBlockedHTML ?? "";
  }
  return html;
}
