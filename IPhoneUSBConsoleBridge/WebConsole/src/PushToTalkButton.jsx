import { useEffect, useRef } from 'react';
import { MicrophoneIcon } from './icons.jsx';

export default function PushToTalkButton({
  active,
  starting,
  canControl,
  permission,
  onEnable,
  onStart,
  onStop
}) {
  const pointerRef = useRef(null);
  const keyRef = useRef(null);
  const ready = permission === 'ready';
  const requesting = permission === 'requesting';

  useEffect(() => {
    if (!canControl || !ready) onStop();
  }, [canControl, onStop, ready]);

  useEffect(() => {
    const releaseKeyboard = (event) => {
      if (keyRef.current === null) return;
      if (event?.type === 'keyup' && event.key !== keyRef.current) return;
      if (event?.cancelable) event.preventDefault();
      keyRef.current = null;
      onStop();
    };
    window.addEventListener('keyup', releaseKeyboard);
    window.addEventListener('blur', releaseKeyboard);
    return () => {
      window.removeEventListener('keyup', releaseKeyboard);
      window.removeEventListener('blur', releaseKeyboard);
      if (keyRef.current !== null || pointerRef.current !== null) onStop();
      keyRef.current = null;
      pointerRef.current = null;
    };
  }, [onStop]);

  const pointerDown = (event) => {
    if (!ready || !canControl || pointerRef.current !== null) return;
    event.preventDefault();
    pointerRef.current = event.pointerId;
    event.currentTarget.setPointerCapture(event.pointerId);
    if (!onStart()) {
      pointerRef.current = null;
      if (event.currentTarget.hasPointerCapture(event.pointerId)) {
        event.currentTarget.releasePointerCapture(event.pointerId);
      }
    }
  };

  const pointerRelease = (event) => {
    if (pointerRef.current !== event.pointerId) return;
    event.preventDefault();
    pointerRef.current = null;
    onStop();
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };

  const keyDown = (event) => {
    if (
      !ready || !canControl || event.repeat || keyRef.current !== null ||
      (event.key !== ' ' && event.key !== 'Enter')
    ) return;
    event.preventDefault();
    keyRef.current = event.key;
    if (!onStart()) keyRef.current = null;
  };

  const keyUp = (event) => {
    if (keyRef.current === null || event.key !== keyRef.current) return;
    event.preventDefault();
    keyRef.current = null;
    onStop();
  };

  const blur = () => {
    const wasPressed = keyRef.current !== null || pointerRef.current !== null;
    keyRef.current = null;
    pointerRef.current = null;
    if (wasPressed) onStop();
  };

  if (!ready) {
    return (
      <button
        className="command-button microphone-button"
        disabled={requesting || !canControl}
        onClick={onEnable}
        type="button"
      >
        <MicrophoneIcon />
        <span>{requesting ? '等待麦克风权限' : '启用麦克风'}</span>
      </button>
    );
  }

  return (
    <button
      aria-pressed={active || starting}
      className={`command-button microphone-button ${active ? 'is-talking' : ''}`}
      disabled={!canControl}
      onBlur={blur}
      onContextMenu={(event) => event.preventDefault()}
      onKeyDown={keyDown}
      onKeyUp={keyUp}
      onLostPointerCapture={pointerRelease}
      onPointerCancel={pointerRelease}
      onPointerDown={pointerDown}
      onPointerUp={pointerRelease}
      type="button"
    >
      <MicrophoneIcon />
      <span>{active ? '正在说话，松开结束' : (starting ? '正在连接，松开取消' : '按住说话')}</span>
    </button>
  );
}
