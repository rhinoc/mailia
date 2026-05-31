import { useCallback, useEffect, useMemo, useRef, useState } from "react";

type PullEdge = "top" | "bottom";

interface ElasticPullActionOptions {
  edge: PullEdge;
  enabled: boolean;
  isLoading?: boolean;
  triggerDistance?: number;
  maxDistance?: number;
  onTrigger(): void;
}

interface ElasticPullActionState {
  distance: number;
  progress: number;
  spinnerFrame: number;
  spinnerOpacity: number;
  willTrigger: boolean;
  isActive: boolean;
}

export function useElasticPullAction<T extends HTMLElement>({
  edge,
  enabled,
  isLoading = false,
  triggerDistance = 72,
  maxDistance = 116,
  onTrigger
}: ElasticPullActionOptions) {
  const hostRef = useRef<T | null>(null);
  const touchStartRef = useRef<{ y: number; active: boolean } | null>(null);
  const idleReleaseTimerRef = useRef<number | null>(null);
  const releaseRef = useRef<() => void>(() => {});
  const stateRef = useRef<ElasticPullActionState>({
    distance: 0,
    progress: 0,
    spinnerFrame: 0,
    spinnerOpacity: 0,
    willTrigger: false,
    isActive: false
  });
  const [state, setState] = useState<ElasticPullActionState>(stateRef.current);

  const setPullDistance = useCallback(
    (distance: number) => {
      const clamped = Math.max(0, Math.min(maxDistance, distance));
      const next = {
        distance: clamped,
        progress: Math.min(1, clamped / triggerDistance),
        spinnerFrame: spinnerFrameFor(clamped, triggerDistance),
        spinnerOpacity: spinnerOpacityFor(clamped, triggerDistance, maxDistance),
        willTrigger: clamped >= triggerDistance,
        isActive: clamped > 0
      };
      stateRef.current = next;
      setState(next);
    },
    [maxDistance, triggerDistance]
  );

  const clearIdleReleaseTimer = useCallback(() => {
    if (idleReleaseTimerRef.current === null) return;
    window.clearTimeout(idleReleaseTimerRef.current);
    idleReleaseTimerRef.current = null;
  }, []);

  const reset = useCallback(() => {
    clearIdleReleaseTimer();
    setPullDistance(0);
  }, [clearIdleReleaseTimer, setPullDistance]);

  const release = useCallback(() => {
    if (!stateRef.current.isActive) {
      return;
    }
    const shouldTrigger = enabled && !isLoading && stateRef.current.willTrigger;
    reset();
    if (shouldTrigger) {
      onTrigger();
    }
  }, [enabled, isLoading, onTrigger, reset]);

  useEffect(() => {
    releaseRef.current = release;
  }, [release]);

  const scheduleIdleRelease = useCallback(
    () => {
      clearIdleReleaseTimer();
      idleReleaseTimerRef.current = window.setTimeout(() => {
        idleReleaseTimerRef.current = null;
        if (!stateRef.current.isActive) return;
        releaseRef.current();
      }, 220);
    },
    [clearIdleReleaseTimer]
  );

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const handleWheel = (event: WheelEvent) => {
      if (!enabled || isLoading) return;
      const scrollElement = scrollContainerFor(host, event.target);
      if (!scrollElement || !isAtEdge(scrollElement, edge)) {
        if (stateRef.current.isActive) reset();
        return;
      }

      const pullDelta = edge === "top" ? -event.deltaY : event.deltaY;
      if (pullDelta <= 0 && !stateRef.current.isActive) return;

      event.preventDefault();
      const nextDistance =
        stateRef.current.distance + (pullDelta > 0 ? pullDelta * 0.55 : pullDelta * 0.9);
      setPullDistance(nextDistance);
      scheduleIdleRelease();
    };

    const handleTouchStart = (event: TouchEvent) => {
      clearIdleReleaseTimer();
      touchStartRef.current = {
        y: event.touches[0]?.clientY ?? 0,
        active: false
      };
    };

    const handleTouchMove = (event: TouchEvent) => {
      if (!enabled || isLoading) return;
      const start = touchStartRef.current;
      if (!start) return;
      const scrollElement = scrollContainerFor(host, event.target);
      if (!scrollElement || !isAtEdge(scrollElement, edge)) return;

      const currentY = event.touches[0]?.clientY ?? start.y;
      const deltaY = currentY - start.y;
      const pullDistance = edge === "top" ? deltaY : -deltaY;
      if (pullDistance <= 0 && !start.active) return;

      start.active = true;
      event.preventDefault();
      setPullDistance(pullDistance * 0.62);
    };

    const handleTouchEnd = () => {
      touchStartRef.current = null;
      release();
    };

    host.addEventListener("wheel", handleWheel, { passive: false });
    host.addEventListener("touchstart", handleTouchStart, { passive: true });
    host.addEventListener("touchmove", handleTouchMove, { passive: false });
    host.addEventListener("touchend", handleTouchEnd, { passive: true });
    host.addEventListener("touchcancel", handleTouchEnd, { passive: true });

    return () => {
      clearIdleReleaseTimer();
      host.removeEventListener("wheel", handleWheel);
      host.removeEventListener("touchstart", handleTouchStart);
      host.removeEventListener("touchmove", handleTouchMove);
      host.removeEventListener("touchend", handleTouchEnd);
      host.removeEventListener("touchcancel", handleTouchEnd);
    };
  }, [
    clearIdleReleaseTimer,
    edge,
    enabled,
    isLoading,
    release,
    reset,
    scheduleIdleRelease,
    setPullDistance
  ]);

  useEffect(() => {
    if (!enabled || isLoading) {
      reset();
    }
  }, [enabled, isLoading, reset]);

  return useMemo(
    () => ({
      ref: hostRef,
      state
    }),
    [state]
  );
}

function spinnerOpacityFor(distance: number, triggerDistance: number, maxDistance: number) {
  if (distance <= 0) return 0;
  const visibleRange = Math.max(Math.min(triggerDistance, maxDistance), 1);
  return Math.min(1, Math.max(0, distance / visibleRange));
}

function spinnerFrameFor(distance: number, triggerDistance: number) {
  if (distance <= 0) return 0;
  const progress = Math.min(1, distance / Math.max(triggerDistance, 1));
  return Math.min(8, Math.max(1, Math.round(progress * 8)));
}

function scrollContainerFor(host: HTMLElement, target: EventTarget | null) {
  let element = target instanceof Element ? target : host;
  while (element && element !== host.parentElement) {
    if (element instanceof HTMLElement && isScrollable(element)) {
      return element;
    }
    const parent = element.parentElement;
    if (!parent) break;
    element = parent;
  }
  return isScrollable(host) ? host : null;
}

function isScrollable(element: HTMLElement) {
  const overflowY = window.getComputedStyle(element).overflowY;
  return (
    element.scrollHeight > element.clientHeight + 1 &&
    (overflowY === "auto" || overflowY === "scroll" || overflowY === "overlay")
  );
}

function isAtEdge(element: HTMLElement, edge: PullEdge) {
  if (edge === "top") {
    return element.scrollTop <= 1;
  }
  return element.scrollTop + element.clientHeight >= element.scrollHeight - 1;
}
