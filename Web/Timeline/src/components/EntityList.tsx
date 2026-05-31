import type { CSSProperties } from "react";
import type { TimelineEntityOption } from "../types";
import { PullSpinner } from "./PullSpinner";
import { useElasticPullAction } from "./useElasticPullAction";

interface EntityListProps {
  entities: TimelineEntityOption[];
  selectedEntityID?: number | null;
  isRefreshing?: boolean;
  onSelect(entityID: number): void;
  onRefresh(): void;
}

export function EntityList({
  entities,
  selectedEntityID,
  isRefreshing = false,
  onSelect,
  onRefresh
}: EntityListProps) {
  const pull = useElasticPullAction<HTMLElement>({
    edge: "top",
    enabled: true,
    isLoading: isRefreshing,
    onTrigger: onRefresh
  });

  return (
    <aside className="entity-list" aria-label="Entities" ref={pull.ref}>
      <div
        className="elastic-pull elastic-pull--top"
        aria-hidden="true"
        data-visible={pull.state.isActive || isRefreshing}
        data-ready={pull.state.willTrigger}
        data-refreshing={isRefreshing}
        style={
          {
            "--pull-distance": `${isRefreshing ? 34 : pull.state.distance}px`,
            "--pull-opacity": pull.state.isActive || isRefreshing ? "1" : "0"
          } as CSSProperties
        }
      >
        <PullSpinner frame={isRefreshing ? 8 : pull.state.spinnerFrame} isRefreshing={isRefreshing} />
      </div>
      {entities.map((entity) => {
        const isSelected = entity.id === selectedEntityID;
        const showUnreadDot = entity.unreadCount > 0 && !isSelected;

        return (
        <button
          className="entity-list__item"
          data-active={isSelected}
          key={entity.id}
          type="button"
          onClick={() => onSelect(entity.id)}
        >
          {showUnreadDot ? <span className="entity-list__unread-dot" /> : null}
          <span className="entity-list__avatar" aria-hidden="true">
            {entity.avatarImageDataURL ? (
              <img alt="" src={entity.avatarImageDataURL} />
            ) : (
              initialsFor(entity.name)
            )}
          </span>
          <span className="entity-list__content">
            <span className="entity-list__headline">
              <span className="entity-list__name">{entity.name}</span>
              <span className="entity-list__time">{formatEntityDate(entity.lastMessageAt)}</span>
            </span>
            <span className="entity-list__preview">
              {entity.detail ?? entity.primaryAddress ?? entity.kind}
            </span>
          </span>
        </button>
        );
      })}
    </aside>
  );
}

function initialsFor(name: string) {
  const initials = name
    .split(/\s+/)
    .map((part) => part[0])
    .join("")
    .slice(0, 2)
    .toUpperCase();

  return initials || "?";
}

function formatEntityDate(value?: string | null) {
  if (!value) {
    return "";
  }

  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) {
    return "";
  }

  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) {
    return new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit"
    }).format(date);
  }

  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (date.toDateString() === yesterday.toDateString()) {
    return "Yesterday";
  }

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric"
  }).format(date);
}
