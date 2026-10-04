import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { api } from './api.js';
import { ClockIcon, FullscreenIcon, HomeIcon, LockIcon, PulseIcon, ShieldIcon, SpeakerIcon } from './icons.jsx';
import PushToTalkButton from './PushToTalkButton.jsx';
import RemoteCanvas from './RemoteCanvas.jsx';
import { useAudioStream } from './useAudioStream.js';
import { useControlSocket } from './useControlSocket.js';
import { useMicrophoneInput } from './useMicrophoneInput.js';
import { useVideoStream } from './useVideoStream.js';

const EMPTY_STATUS = Object.freeze({
  videoConnected: false,
  controlConnected: false,
  fps: null,
  frameAgeMs: null,
  deviceName: null
});

function formatMetric(value, suffix, digits = 0) {
  return Number.isFinite(value) ? `${value.toFixed(digits)} ${suffix}` : `— ${suffix}`;
}

function normalizedStatus(payload, fallback) {
  const video = payload?.usbVideo ?? payload?.video ?? {};
  const control = payload?.control ?? {};
  const videoConnected = video.connected === true || video.state === 'connected';
  const controlConnected = control.connected === true || control.state === 'connected';
  return {
    videoConnected,
    controlConnected,
    fps: Number.isFinite(video.fps) ? video.fps : fallback.fps,
    frameAgeMs: Number.isFinite(video.frameAgeMs) ? video.frameAgeMs : fallback.frameAgeMs,
    deviceName: payload?.device?.name ?? video.deviceName ?? fallback.deviceName
  };
}

function Login({ busy, error, onSubmit }) {
  const [password, setPassword] = useState('');

  const submit = (event) => {
    event.preventDefault();
    if (!password || busy) return;
    onSubmit(password);
  };

  return (
    <main className="login-page">
      <section className="login-card" aria-labelledby="login-title">
        <div className="login-mark"><LockIcon size={24} /></div>
        <p className="eyebrow">iPhone USB Console</p>
        <h1 id="login-title">访问控制台</h1>
        <p className="login-copy">输入网页访问密码以继续。</p>
        <form onSubmit={submit}>
          <label htmlFor="password">访问密码</label>
          <input
            autoComplete="current-password"
            autoFocus
            disabled={busy}
            id="password"
            onChange={(event) => setPassword(event.target.value)}
            spellCheck="false"
            type="password"
            value={password}
          />
          <div className="form-message" aria-live="polite">{error || '\u00a0'}</div>
          <button className="primary-button" disabled={!password || busy} type="submit">
            {busy ? '正在登录' : '登录'}
          </button>
        </form>
      </section>
    </main>
  );
}

function StatusDot({ active }) {
  return <span className={`status-dot ${active ? 'is-active' : ''}`} aria-hidden="true" />;
}

export default function App() {
  const [auth, setAuth] = useState({ state: 'checking', csrfToken: null });
  const [loginBusy, setLoginBusy] = useState(false);
  const [loginError, setLoginError] = useState('');
  const [logoutBusy, setLogoutBusy] = useState(false);
  const [logoutError, setLogoutError] = useState('');
  const [status, setStatus] = useState(EMPTY_STATUS);
  const canvasRef = useRef(null);
  const workspaceRef = useRef(null);

  const markUnauthorized = useCallback(() => {
    setAuth({ state: 'anonymous', csrfToken: null });
    setStatus(EMPTY_STATUS);
    setLogoutBusy(false);
    setLogoutError('');
  }, []);

  const authenticated = auth.state === 'authenticated';
  const control = useControlSocket(authenticated, markUnauthorized);
  const video = useVideoStream(canvasRef, authenticated, markUnauthorized);
  const audio = useAudioStream(authenticated, markUnauthorized);
  const canControl = control.state.socket === 'connected' && control.state.control === 'connected';
  const microphone = useMicrophoneInput({
    enabled: authenticated,
    canControl,
    controlSocketState: control.state.socket,
    remoteMicrophone: control.state.microphone,
    remoteMicrophoneStreamID: control.state.microphoneStreamID,
    remoteMicrophoneRevision: control.state.microphoneRevision,
    remoteMicrophoneError: control.state.microphoneError,
    sendBinary: control.sendBinary,
    resetConnection: control.resetConnection,
    setDucked: audio.setDucked
  });

  useEffect(() => {
    let cancelled = false;
    api.session()
      .then((session) => {
        if (cancelled) return;
        setAuth(session?.authenticated
          ? { state: 'authenticated', csrfToken: session.csrfToken ?? null }
          : { state: 'anonymous', csrfToken: null });
      })
      .catch((error) => {
        if (cancelled) return;
        if (error.status === 401) setAuth({ state: 'anonymous', csrfToken: null });
        else {
          setAuth({ state: 'anonymous', csrfToken: null });
          setLoginError('无法连接到控制台');
        }
      });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    if (!authenticated) return undefined;
    let cancelled = false;
    let timer = null;

    const poll = async () => {
      try {
        const payload = await api.status();
        if (!cancelled) setStatus((current) => normalizedStatus(payload, current));
      } catch (error) {
        if (error.status === 401 && !cancelled) markUnauthorized();
      } finally {
        if (!cancelled) timer = window.setTimeout(poll, 1000);
      }
    };
    poll();
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [authenticated, markUnauthorized]);

  const login = async (password) => {
    setLoginBusy(true);
    setLoginError('');
    try {
      const session = await api.login(password);
      setAuth({ state: 'authenticated', csrfToken: session?.csrfToken ?? null });
    } catch (error) {
      if (error.status === 429) setLoginError('尝试次数过多，请稍后再试');
      else if (error.status === 401) setLoginError('密码不正确');
      else setLoginError(error.message || '登录失败');
    } finally {
      setLoginBusy(false);
    }
  };

  const logout = async () => {
    if (logoutBusy) return;
    const csrfToken = auth.csrfToken;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 10_000);
    setLogoutBusy(true);
    setLogoutError('');
    try {
      await api.logout(csrfToken, controller.signal);
      markUnauthorized();
    } catch {
      setLogoutError('退出未完成，请重试');
    } finally {
      window.clearTimeout(timeout);
      setLogoutBusy(false);
    }
  };

  const sendCommand = (name) => {
    control.send({
      type: 'command',
      seq: control.nextSequence(),
      name,
      clientTimeMs: performance.timeOrigin + performance.now()
    });
  };

  const enterFullscreen = async () => {
    const element = workspaceRef.current;
    if (!element) return;
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else {
        try {
          await element.requestFullscreen({ navigationUI: 'hide' });
        } catch {
          await element.requestFullscreen();
        }
      }
    } catch {
      // Unsupported/fullscreen-denied state leaves the console usable in place.
    }
  };

  const videoConnected = video.socket === 'connected' && video.decoder === 'ready';
  const audioPlaying = audio.state.enabled && audio.state.socket === 'connected' && audio.state.decoder === 'ready';
  const audioStatus = audio.state.error || (audioPlaying
    ? '手机声音正在播放'
    : (audio.state.enabled ? '正在连接手机声音' : '手机声音已关闭'));
  const microphoneStatus = microphone.state.error || control.state.microphoneError || (() => {
    switch (microphone.state.permission) {
    case 'requesting': return '等待浏览器麦克风权限';
    case 'ready':
      if (microphone.state.starting) return '正在等待手机麦克风确认';
      if (microphone.state.active) return '语音正在传入手机';
      return canControl ? '麦克风已就绪，仅按住时传输' : '麦克风已就绪，等待控制连接';
    case 'denied': return '浏览器未允许麦克风';
    case 'unsupported': return '当前浏览器无法使用麦克风';
    default: return '启用后可按住说话';
    }
  })();
  const effectiveStatus = useMemo(() => ({
    // Report what this browser is actually decoding, rather than retaining an
    // upstream capture status after this viewer's stream has stalled.
    videoConnected,
    controlConnected: canControl,
    fps: video.fps ?? null,
    frameAgeMs: status.frameAgeMs,
    deviceName: status.deviceName ?? control.state.deviceName ?? 'iPhone (USB)'
  }), [canControl, control.state.deviceName, status, video.fps, videoConnected]);

  if (auth.state === 'checking') {
    return <div className="boot-state"><span className="spinner" /><span>正在连接控制台</span></div>;
  }

  if (!authenticated) {
    return <Login busy={loginBusy} error={loginError} onSubmit={login} />;
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <h1>iPhone USB Console</h1>
        <div className="topbar-actions">
          <span className="secure-label"><ShieldIcon size={18} />会话安全</span>
          {logoutError ? <span className="logout-error" role="status">{logoutError}</span> : null}
          <button className="quiet-button" disabled={logoutBusy} onClick={logout} type="button">
            {logoutBusy ? '正在退出' : '退出'}
          </button>
        </div>
      </header>

      <main className="console-layout" ref={workspaceRef}>
        <section className="stage" aria-label="iPhone 视频与控制区域">
          <RemoteCanvas
            canControl={canControl}
            canvasRef={canvasRef}
            nextSequence={control.nextSequence}
            send={control.send}
            videoState={video}
          />
        </section>

        <aside className="control-panel" aria-label="控制面板">
          <div className="panel-heading">
            <span>USB 音视频</span>
            <span className="connection-line">
              <StatusDot active={effectiveStatus.controlConnected} />
              {effectiveStatus.controlConnected ? '控制已连接' : '等待控制'}
            </span>
          </div>

          <div className="metrics">
            <span><PulseIcon size={18} />{formatMetric(effectiveStatus.fps, 'fps', 1)}</span>
            <span><ClockIcon size={18} />{formatMetric(control.state.rttMs, 'ms')}</span>
          </div>

          <div className="panel-rule" />

          <div className="command-list">
            <button className="command-button is-primary" disabled={!canControl} onClick={() => sendCommand('home')} type="button">
              <HomeIcon />
              <span>主屏幕</span>
            </button>
            <button className="command-button" disabled={!canControl} onClick={() => sendCommand('lockWake')} type="button">
              <LockIcon />
              <span>锁屏 / 唤醒</span>
            </button>
            <button
              aria-pressed={audio.state.enabled}
              className={`command-button audio-button ${audio.state.enabled ? 'is-audio-on' : ''}`}
              onClick={audio.state.enabled ? audio.disable : audio.enable}
              type="button"
            >
              <SpeakerIcon />
              <span>{audio.state.enabled ? '关闭手机声音' : '开启手机声音'}</span>
            </button>
            <PushToTalkButton
              active={microphone.state.active}
              canControl={canControl}
              onEnable={microphone.enable}
              onStart={microphone.startTalking}
              onStop={microphone.stopTalking}
              permission={microphone.state.permission}
              starting={microphone.state.starting}
            />
            <button className="command-button" onClick={enterFullscreen} type="button">
              <FullscreenIcon />
              <span>全屏</span>
            </button>
          </div>

          <div className="audio-state" aria-live="polite">
            <span>{audioStatus}</span>
            <span>{microphoneStatus}</span>
          </div>
        </aside>

        <footer className="statusbar" aria-label="连接状态">
          <span className="status-item"><StatusDot active={effectiveStatus.videoConnected && effectiveStatus.controlConnected} />{effectiveStatus.videoConnected ? '已连接' : '等待视频'}</span>
          <span className="status-divider" />
          <span className="status-item">{effectiveStatus.deviceName}</span>
          <span className="status-divider" />
          <span className="status-item">视频：{formatMetric(effectiveStatus.fps, 'fps', 1)}</span>
          <span className="status-divider" />
          <span className="status-item">帧龄：{formatMetric(effectiveStatus.frameAgeMs, 'ms')}</span>
          <span className="status-divider" />
          <span className="status-item">声音：{audioPlaying ? '播放中' : '关闭'}</span>
        </footer>
      </main>
    </div>
  );
}
