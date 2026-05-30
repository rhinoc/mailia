import type { TimelineEntity } from "../types";

interface EntityListProps {
  entities: TimelineEntity[];
  selectedEntityID?: string | null;
  onSelect(entityID: string): void;
}

export function EntityList({ entities, selectedEntityID, onSelect }: EntityListProps) {
  return (
    <aside className="entity-list" aria-label="Entities">
      {entities.map((entity) => (
        <button
          className="entity-list__item"
          data-active={entity.id === selectedEntityID}
          key={entity.id}
          type="button"
          onClick={() => onSelect(entity.id)}
        >
          <span className="entity-list__name">{entity.name}</span>
          <span className="entity-list__detail">{entity.detail ?? entity.primaryAddress}</span>
          <span className="entity-list__meta">
            <span>{entity.kind}</span>
            <span>{entity.messageCount}</span>
            {entity.unreadCount > 0 ? <strong>{entity.unreadCount}</strong> : null}
          </span>
        </button>
      ))}
    </aside>
  );
}
