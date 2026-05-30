import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import TurndownService from "turndown";
import type { BodyDisplayMode } from "../types";

const HTML_DEFAULT_SCALE = 0.8;
const turndown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "fenced"
});

const markdownComponents: Components = {
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
  hr({ node: _node, ...props }) {
    return <hr className="mail-markdown__rule" {...props} />;
  }
};

interface MessageBodyProps {
  html?: string | null;
  text?: string | null;
  mode: BodyDisplayMode;
}

export function MessageBody({ html, text, mode }: MessageBodyProps) {
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const [metrics, setMetrics] = useState({
    scale: 1,
    height: 0,
    contentHeight: 0
  });

  const normalizedHTML = useMemo(() => {
    if (html) return html;
    if (!text) return "<p>No body content is available for this message.</p>";

    return `<pre>${escapeHTML(text)}</pre>`;
  }, [html, text]);

  const markdown = useMemo(() => {
    if (html) return turndown.turndown(html).trim();
    return text?.trim() || "No body content is available for this message.";
  }, [html, text]);

  const measure = useCallback(() => {
    const viewport = viewportRef.current;
    const content = contentRef.current;
    if (!viewport || !content) return;

    const availableWidth = Math.max(1, viewport.clientWidth);
    const naturalWidth = Math.max(content.scrollWidth, content.offsetWidth, availableWidth);
    const baseScale = html ? HTML_DEFAULT_SCALE : 1;
    const scaledWidth = naturalWidth * baseScale;
    const fitScale =
      scaledWidth > availableWidth
        ? availableWidth / naturalWidth
        : baseScale;
    const naturalHeight = Math.max(content.scrollHeight, content.offsetHeight, 1);
    const scaledHeight = Math.ceil(naturalHeight * fitScale);

    const nextMetrics = {
      scale: fitScale,
      height: scaledHeight,
      contentHeight: scaledHeight
    };

    setMetrics((current) => {
      if (
        current.scale === nextMetrics.scale &&
        current.height === nextMetrics.height &&
        current.contentHeight === nextMetrics.contentHeight
      ) {
        return current;
      }
      return nextMetrics;
    });
  }, [html]);

  useEffect(() => {
    measure();
    const viewport = viewportRef.current;
    const content = contentRef.current;
    if (!viewport || !content) return;

    const resizeObserver = new ResizeObserver(measure);
    resizeObserver.observe(viewport);
    resizeObserver.observe(content);

    const images = Array.from(content.querySelectorAll("img"));
    for (const image of images) {
      image.addEventListener("load", measure);
    }

    return () => {
      resizeObserver.disconnect();
      for (const image of images) {
        image.removeEventListener("load", measure);
      }
    };
  }, [measure, normalizedHTML]);

  if (mode === "markdown") {
    return (
      <div className="mail-body-frame mail-body-frame--markdown">
        <div className="mail-markdown">
          <ReactMarkdown components={markdownComponents}>{markdown}</ReactMarkdown>
        </div>
      </div>
    );
  }

  return (
    <div
      className="mail-body-frame"
      style={{ height: metrics.height || undefined }}
    >
      <div
        className="mail-body"
        ref={viewportRef}
      >
        <div
          className="mail-body__surface"
          style={{ height: metrics.contentHeight || undefined }}
        >
          <div
            className="mail-body__scale"
            style={{
              transform: `scale(${metrics.scale})`,
              width: `${100 / metrics.scale}%`
            }}
          >
            <div
              className="mail-body__content"
              ref={contentRef}
              dangerouslySetInnerHTML={{ __html: normalizedHTML }}
            />
          </div>
        </div>
      </div>
    </div>
  );
}

function escapeHTML(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function classNames(...values: Array<string | undefined>) {
  return values.filter(Boolean).join(" ");
}
