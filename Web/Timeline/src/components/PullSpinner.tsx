import type { CSSProperties } from "react";

interface PullSpinnerProps {
  frame: number;
  isRefreshing: boolean;
}

const barOpacities = [1, 0.85, 0.75, 0.65, 0.55, 0.4, 0.25, 0.1];

export function PullSpinner({ frame, isRefreshing }: PullSpinnerProps) {
  const normalizedFrame = Math.min(8, Math.max(0, Math.round(frame)));

  return (
    <span
      className="pull-spinner"
      data-refreshing={isRefreshing}
      aria-hidden="true"
    >
      {barOpacities.map((_, index) => {
        const opacityIndex = (index - normalizedFrame + barOpacities.length) % barOpacities.length;
        return (
          <span
            className="pull-spinner__bar"
            key={index}
            style={
              {
                "--bar-angle": `${index * 45}deg`,
                "--bar-opacity": barOpacities[opacityIndex]
              } as CSSProperties
            }
          />
        );
      })}
    </span>
  );
}
