import { isDevTimelineBridge, type TimelineBridge } from "../bridge/timelineBridge";
import type { TimelineState } from "../types";

interface DevHarnessProps {
  bridge: TimelineBridge;
  state: TimelineState;
}

export function DevHarness({ bridge, state }: DevHarnessProps) {
  if (!isDevTimelineBridge(bridge)) {
    return null;
  }

  return (
    <section className="dev-harness" aria-label="Timeline development harness">
      <label>
        Fixture
        <select
          value={bridge.getFixtureID()}
          onChange={(event) => bridge.setFixture(event.currentTarget.value)}
        >
          {bridge.getFixtures().map((fixture) => (
            <option key={fixture.id} value={fixture.id}>
              {fixture.label}
            </option>
          ))}
        </select>
      </label>

      <label>
        Entity
        <select
          value={state.selectedEntityID ?? ""}
          onChange={(event) =>
            bridge.send({ type: "selectEntity", entityID: event.currentTarget.value })
          }
        >
          {state.entities.map((entity) => (
            <option key={entity.id} value={entity.id}>
              {entity.name}
            </option>
          ))}
        </select>
      </label>

      <div className="dev-harness__meta">
        <span>{bridge.mode}</span>
        <span>{state.messages.length} messages</span>
      </div>
    </section>
  );
}
