import { useCallback, useEffect, useRef } from 'react';

const MOVE_INTERVAL_MS = 1000 / 60;

function modifiers(event) {
  return {
    alt: event.altKey,
    control: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey
  };
}

export default function RemoteCanvas({ canvasRef, canControl, send, nextSequence, videoState }) {
  const activePointerRef = useRef(null);
  const pendingMoveRef = useRef(null);
  const moveFrameRef = useRef(null);
  const lastMoveSentAtRef = useRef(-Infinity);
  const pressedKeysRef = useRef(new Map());
  const isLandscape = Number.isFinite(videoState.width) && Number.isFinite(videoState.height)
    && videoState.width > videoState.height;

  const sendPointer = useCallback((phase, point, buttons) => send({
    type: 'pointer',
    seq: nextSequence(),
    phase,
    x: point.x,
    y: point.y,
    buttons,
    pointerType: point.pointerType,
    clientTimeMs: performance.timeOrigin + performance.now()
  }), [nextSequence, send]);

  const pointFromEvent = useCallback((event, clampOutside = false) => {
    const canvas = event.currentTarget;
    const rectangle = event.currentTarget.getBoundingClientRect();
    const sourceWidth = canvas.width;
    const sourceHeight = canvas.height;
    if (rectangle.width <= 0 || rectangle.height <= 0 || sourceWidth <= 0 || sourceHeight <= 0) {
      return null;
    }

    const sourceAspect = sourceWidth / sourceHeight;
    const elementAspect = rectangle.width / rectangle.height;
    let visibleWidth = rectangle.width;
    let visibleHeight = rectangle.height;
    let visibleLeft = rectangle.left;
    let visibleTop = rectangle.top;

    if (sourceAspect > elementAspect) {
      visibleHeight = rectangle.width / sourceAspect;
      visibleTop += (rectangle.height - visibleHeight) / 2;
    } else if (sourceAspect < elementAspect) {
      visibleWidth = rectangle.height * sourceAspect;
      visibleLeft += (rectangle.width - visibleWidth) / 2;
    }

    const rawX = (event.clientX - visibleLeft) / visibleWidth;
    const rawY = (event.clientY - visibleTop) / visibleHeight;
    const inside = rawX >= 0 && rawX <= 1 && rawY >= 0 && rawY <= 1;
    if (!inside && !clampOutside) return null;

    return {
      x: Math.min(1, Math.max(0, rawX)),
      y: Math.min(1, Math.max(0, rawY)),
      pointerType: event.pointerType || 'mouse'
    };
  }, []);

  const flushMove = useCallback((timestamp, force = false) => {
    moveFrameRef.current = null;
    const point = pendingMoveRef.current;
    if (!point || !activePointerRef.current) return;
    if (!force && timestamp - lastMoveSentAtRef.current < MOVE_INTERVAL_MS) {
      moveFrameRef.current = requestAnimationFrame((nextTimestamp) => flushMove(nextTimestamp));
      return;
    }
    pendingMoveRef.current = null;
    lastMoveSentAtRef.current = timestamp;
    sendPointer('move', point, 1);
  }, [sendPointer]);

  const releasePointer = useCallback((phase = 'cancel') => {
    const active = activePointerRef.current;
    if (!active) return;
    if (moveFrameRef.current) cancelAnimationFrame(moveFrameRef.current);
    moveFrameRef.current = null;
    const finalPoint = pendingMoveRef.current ?? active.lastPoint;
    pendingMoveRef.current = null;
    if (phase === 'up') {
      // Preserve the last pressed coordinate before releasing the remote pointer.
      sendPointer('move', finalPoint, 1);
      sendPointer('up', finalPoint, 0);
    } else {
      sendPointer('cancel', finalPoint, 0);
    }
    activePointerRef.current = null;
  }, [sendPointer]);

  const releaseKeys = useCallback(() => {
    for (const [code, key] of pressedKeysRef.current) {
      send({
        type: 'key',
        seq: nextSequence(),
        phase: 'up',
        code,
        key,
        modifiers: { alt: false, control: false, meta: false, shift: false },
        repeat: false,
        clientTimeMs: performance.timeOrigin + performance.now()
      });
    }
    pressedKeysRef.current.clear();
  }, [nextSequence, send]);

  useEffect(() => {
    const onBlur = () => {
      releasePointer('cancel');
      releaseKeys();
    };
    const onVisibility = () => {
      if (document.visibilityState !== 'visible') onBlur();
    };
    window.addEventListener('blur', onBlur);
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      window.removeEventListener('blur', onBlur);
      document.removeEventListener('visibilitychange', onVisibility);
      onBlur();
    };
  }, [releaseKeys, releasePointer]);

  useEffect(() => {
    if (!canControl) {
      releasePointer('cancel');
      releaseKeys();
    }
  }, [canControl, releaseKeys, releasePointer]);

  const onPointerDown = (event) => {
    if (!canControl || activePointerRef.current) return;
    const point = pointFromEvent(event);
    if (!point) return;
    event.preventDefault();
    event.currentTarget.focus({ preventScroll: true });
    event.currentTarget.setPointerCapture(event.pointerId);
    activePointerRef.current = { id: event.pointerId, lastPoint: point };
    lastMoveSentAtRef.current = performance.now();
    sendPointer('down', point, 1);
  };

  const onPointerMove = (event) => {
    const active = activePointerRef.current;
    if (!active || active.id !== event.pointerId) return;
    event.preventDefault();
    const point = pointFromEvent(event, true);
    if (!point) return;
    active.lastPoint = point;
    pendingMoveRef.current = point;
    if (!moveFrameRef.current) moveFrameRef.current = requestAnimationFrame((timestamp) => flushMove(timestamp));
  };

  const onPointerUp = (event) => {
    if (activePointerRef.current?.id !== event.pointerId) return;
    event.preventDefault();
    const point = pointFromEvent(event, true);
    if (!point) {
      releasePointer('cancel');
      return;
    }
    activePointerRef.current.lastPoint = point;
    pendingMoveRef.current = point;
    releasePointer('up');
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  };

  const onPointerCancel = (event) => {
    if (activePointerRef.current?.id !== event.pointerId) return;
    releasePointer('cancel');
  };

  const onKeyDown = (event) => {
    if (!canControl || event.isComposing || event.key === 'Process') return;
    event.preventDefault();
    if (!pressedKeysRef.current.has(event.code)) pressedKeysRef.current.set(event.code, event.key);
    send({
      type: 'key',
      seq: nextSequence(),
      phase: 'down',
      code: event.code,
      key: event.key,
      modifiers: modifiers(event),
      repeat: event.repeat,
      clientTimeMs: performance.timeOrigin + performance.now()
    });
  };

  const onKeyUp = (event) => {
    if (!pressedKeysRef.current.has(event.code)) return;
    event.preventDefault();
    pressedKeysRef.current.delete(event.code);
    send({
      type: 'key',
      seq: nextSequence(),
      phase: 'up',
      code: event.code,
      key: event.key,
      modifiers: modifiers(event),
      repeat: false,
      clientTimeMs: performance.timeOrigin + performance.now()
    });
  };

  return (
    <div className={`phone-shell ${canControl ? 'is-controllable' : ''} ${isLandscape ? 'is-landscape' : 'is-portrait'}`}>
      <canvas
        aria-label="iPhone 远程画面"
        className="remote-canvas"
        onContextMenu={(event) => event.preventDefault()}
        onKeyDown={onKeyDown}
        onKeyUp={onKeyUp}
        onPointerCancel={onPointerCancel}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        ref={canvasRef}
        role="application"
        tabIndex={canControl ? 0 : -1}
        width={videoState.width ?? 828}
        height={videoState.height ?? 1792}
      />
      {videoState.socket !== 'connected' || videoState.decoder !== 'ready' ? (
        <div className="canvas-state" aria-live="polite">
          <span className="canvas-state-dot" />
          <span>{videoState.error || (videoState.socket === 'connecting' ? '正在连接视频' : '等待 USB 视频')}</span>
        </div>
      ) : null}
    </div>
  );
}
