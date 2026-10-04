import { useCallback, useEffect, useRef, useState } from 'react';

const WORKLET_URL = new URL('./audio-io-worklet.js', import.meta.url).href;
const MICROPHONE_HEADER_BYTES = 28;
const MICROPHONE_SAMPLE_RATE = 48_000;
const MICROPHONE_PACKET_FRAMES = 960;
const MICROPHONE_START_TIMEOUT_MS = 1_500;
const FLAG_START = 0x01;
const FLAG_STOP = 0x02;
const FLAG_DATA = 0x04;

const INITIAL_STATE = Object.freeze({
  permission: 'idle',
  starting: false,
  active: false,
  error: null
});

function randomStreamID() {
  const values = new Uint32Array(1);
  do { crypto.getRandomValues(values); } while (values[0] === 0);
  return values[0];
}

function microphonePacket(flags, streamID, sequence, pcm) {
  const sampleCount = pcm?.length ?? 0;
  const buffer = new ArrayBuffer(MICROPHONE_HEADER_BYTES + sampleCount * 2);
  const bytes = new Uint8Array(buffer);
  bytes.set([0x49, 0x55, 0x4d, 0x43], 0); // IUMC
  bytes[4] = 1;
  bytes[5] = flags;
  const view = new DataView(buffer);
  view.setUint16(6, MICROPHONE_HEADER_BYTES, false);
  view.setUint32(8, streamID, false);
  view.setUint32(12, sequence, false);
  const timestampMicroseconds = BigInt(Math.floor((performance.timeOrigin + performance.now()) * 1_000));
  view.setBigUint64(16, timestampMicroseconds, false);
  view.setUint16(24, sampleCount, false);
  bytes[26] = 1; // mono
  bytes[27] = 1; // signed 16-bit little-endian PCM
  for (let index = 0; index < sampleCount; index += 1) {
    view.setInt16(MICROPHONE_HEADER_BYTES + index * 2, pcm[index], true);
  }
  return buffer;
}

export function useMicrophoneInput({
  enabled,
  canControl,
  controlSocketState,
  remoteMicrophone,
  remoteMicrophoneStreamID,
  remoteMicrophoneRevision,
  remoteMicrophoneError,
  sendBinary,
  resetConnection,
  setDucked
}) {
  const [state, setState] = useState(INITIAL_STATE);
  const runtimeRef = useRef(null);
  const initializingRef = useRef(null);
  const initializationGenerationRef = useRef(0);
  const mountedRef = useRef(true);
  const enabledRef = useRef(enabled);
  const canControlRef = useRef(canControl);
  const activeRef = useRef(false);
  const streamIDRef = useRef(0);
  const packetSequenceRef = useRef(0);
  const pendingStartRef = useRef(null);
  const stopRef = useRef(() => {});
  const abortRef = useRef(() => {});

  enabledRef.current = enabled;
  canControlRef.current = canControl;

  const clearPendingStart = useCallback(() => {
    const pending = pendingStartRef.current;
    if (pending?.timer) window.clearTimeout(pending.timer);
    pendingStartRef.current = null;
  }, []);

  const stopLocalCapture = useCallback((error = null) => {
    const runtime = runtimeRef.current;
    runtime?.captureNode.port.postMessage({ type: 'stop' });
    for (const track of runtime?.stream.getAudioTracks() ?? []) track.enabled = false;
    activeRef.current = false;
    setDucked(false);
    if (!mountedRef.current) return;
    setState((current) => ({
      ...current,
      starting: false,
      active: false,
      error: error ?? current.error
    }));
  }, [setDucked]);

  const releaseWithoutProtocol = useCallback((error = null) => {
    clearPendingStart();
    streamIDRef.current = 0;
    packetSequenceRef.current = 0;
    stopLocalCapture(error);
  }, [clearPendingStart, stopLocalCapture]);

  const abortTalking = useCallback((error) => {
    releaseWithoutProtocol(error);
    resetConnection('microphone stream resync');
  }, [releaseWithoutProtocol, resetConnection]);

  abortRef.current = abortTalking;

  const destroyRuntime = useCallback(() => {
    initializationGenerationRef.current += 1;
    initializingRef.current = null;
    const runtime = runtimeRef.current;
    runtimeRef.current = null;
    releaseWithoutProtocol();
    if (!runtime) return;
    runtime.captureNode.port.postMessage({ type: 'stop' });
    for (const track of runtime.stream.getTracks()) track.stop();
    runtime.sourceNode.disconnect();
    runtime.captureNode.disconnect();
    runtime.silentGain.disconnect();
    void runtime.context.close().catch(() => {});
  }, [releaseWithoutProtocol]);

  const stopTalking = useCallback((error = null) => {
    const pending = pendingStartRef.current;
    if (pending) {
      pending.cancelled = true;
      stopLocalCapture(error);
      return;
    }
    if (!activeRef.current) return;

    const streamID = streamIDRef.current;
    packetSequenceRef.current = (packetSequenceRef.current + 1) >>> 0;
    const stopped = sendBinary(
      microphonePacket(FLAG_STOP, streamID, packetSequenceRef.current, null),
      { critical: true }
    );
    streamIDRef.current = 0;
    packetSequenceRef.current = 0;
    stopLocalCapture(error);
    if (!stopped) resetConnection('microphone stop failed');
  }, [resetConnection, sendBinary, stopLocalCapture]);

  stopRef.current = stopTalking;

  const enable = useCallback(async () => {
    if (!enabled || !canControl || initializingRef.current !== null || runtimeRef.current) return;
    if (!window.isSecureContext) {
      setState({ permission: 'unsupported', starting: false, active: false, error: '麦克风需要安全连接' });
      return;
    }
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass || !('AudioWorkletNode' in window) || !navigator.mediaDevices?.getUserMedia) {
      setState({ permission: 'unsupported', starting: false, active: false, error: '此浏览器不支持麦克风输入' });
      return;
    }

    const generation = initializationGenerationRef.current + 1;
    initializationGenerationRef.current = generation;
    initializingRef.current = generation;
    setState({ permission: 'requesting', starting: false, active: false, error: null });
    let context = null;
    let stream = null;
    try {
      context = new AudioContextClass({ latencyHint: 'interactive', sampleRate: MICROPHONE_SAMPLE_RATE });
      const resumePromise = context.resume();
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true
        },
        video: false
      });
      await Promise.all([
        resumePromise,
        context.audioWorklet.addModule(WORKLET_URL)
      ]);
      if (
        !mountedRef.current ||
        initializationGenerationRef.current !== generation ||
        !enabledRef.current ||
        !canControlRef.current ||
        context.sampleRate !== MICROPHONE_SAMPLE_RATE
      ) {
        throw new Error('unsupported_sample_rate');
      }

      const sourceNode = context.createMediaStreamSource(stream);
      const captureNode = new AudioWorkletNode(context, 'console-microphone-capture', {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [1]
      });
      const silentGain = context.createGain();
      silentGain.gain.value = 0;
      sourceNode.connect(captureNode).connect(silentGain).connect(context.destination);
      for (const track of stream.getAudioTracks()) {
        track.enabled = false;
        track.addEventListener('ended', () => abortRef.current('麦克风设备已断开'), { once: true });
      }

      const runtime = { context, stream, sourceNode, captureNode, silentGain };
      captureNode.port.onmessage = ({ data }) => {
        if (!activeRef.current || data?.type !== 'microphoneData' || !(data.pcm instanceof ArrayBuffer)) return;
        const pcm = new Int16Array(data.pcm);
        if (pcm.length !== MICROPHONE_PACKET_FRAMES) return;
        packetSequenceRef.current = (packetSequenceRef.current + 1) >>> 0;
        const sent = sendBinary(
          microphonePacket(
            FLAG_DATA,
            streamIDRef.current,
            packetSequenceRef.current,
            pcm
          )
        );
        if (!sent) abortRef.current('网络拥塞，语音输入已停止');
      };
      if (
        !mountedRef.current ||
        initializationGenerationRef.current !== generation ||
        !enabledRef.current ||
        !canControlRef.current
      ) {
        for (const track of stream.getTracks()) track.stop();
        sourceNode.disconnect();
        captureNode.disconnect();
        silentGain.disconnect();
        await context.close();
        return;
      }
      runtimeRef.current = runtime;
      setState({ permission: 'ready', starting: false, active: false, error: null });
    } catch (error) {
      for (const track of stream?.getTracks() ?? []) track.stop();
      if (context) void context.close().catch(() => {});
      if (
        !mountedRef.current ||
        initializationGenerationRef.current !== generation ||
        !enabledRef.current
      ) return;
      const denied = error?.name === 'NotAllowedError' || error?.name === 'SecurityError';
      setState({
        permission: denied ? 'denied' : 'unsupported',
        starting: false,
        active: false,
        error: denied ? '未允许浏览器使用麦克风' : '麦克风初始化失败'
      });
    } finally {
      if (initializingRef.current === generation) initializingRef.current = null;
    }
  }, [canControl, enabled, sendBinary]);

  const startTalking = useCallback(() => {
    const runtime = runtimeRef.current;
    if (
      !enabled || !canControl || controlSocketState !== 'connected' || !runtime ||
      activeRef.current || pendingStartRef.current
    ) return false;

    const streamID = randomStreamID();
    streamIDRef.current = streamID;
    packetSequenceRef.current = 0;
    const started = sendBinary(
      microphonePacket(FLAG_START, streamID, packetSequenceRef.current, null),
      { critical: true }
    );
    if (!started) {
      streamIDRef.current = 0;
      setState((current) => ({ ...current, error: '控制连接暂时不可用' }));
      return false;
    }

    const pending = {
      streamID,
      afterRevision: remoteMicrophoneRevision,
      cancelled: false,
      timer: null
    };
    pending.timer = window.setTimeout(() => {
      if (pendingStartRef.current !== pending) return;
      releaseWithoutProtocol('麦克风启动确认超时');
      resetConnection('microphone start timeout');
    }, MICROPHONE_START_TIMEOUT_MS);
    pendingStartRef.current = pending;
    setState((current) => ({ ...current, starting: true, active: false, error: null }));
    return true;
  }, [
    canControl,
    controlSocketState,
    enabled,
    releaseWithoutProtocol,
    remoteMicrophoneRevision,
    resetConnection,
    sendBinary
  ]);

  useEffect(() => {
    const pending = pendingStartRef.current;
    if (pending && remoteMicrophoneRevision > pending.afterRevision) {
      if (remoteMicrophone === 'active' && remoteMicrophoneStreamID === pending.streamID) {
        clearPendingStart();
        if (pending.cancelled) {
          packetSequenceRef.current = (packetSequenceRef.current + 1) >>> 0;
          const stopped = sendBinary(
            microphonePacket(FLAG_STOP, pending.streamID, packetSequenceRef.current, null),
            { critical: true }
          );
          streamIDRef.current = 0;
          packetSequenceRef.current = 0;
          if (!stopped) resetConnection('microphone cancelled start');
          return;
        }

        const runtime = runtimeRef.current;
        if (!runtime || !canControlRef.current) {
          packetSequenceRef.current = (packetSequenceRef.current + 1) >>> 0;
          const stopped = sendBinary(
            microphonePacket(FLAG_STOP, pending.streamID, packetSequenceRef.current, null),
            { critical: true }
          );
          streamIDRef.current = 0;
          packetSequenceRef.current = 0;
          if (!stopped) resetConnection('microphone unavailable after start');
          return;
        }

        activeRef.current = true;
        for (const track of runtime.stream.getAudioTracks()) track.enabled = true;
        runtime.captureNode.port.postMessage({ type: 'start' });
        setDucked(true);
        setState((current) => ({ ...current, starting: false, active: true, error: null }));
        return;
      }

      if (remoteMicrophone === 'busy' || remoteMicrophone === 'unavailable') {
        releaseWithoutProtocol(remoteMicrophoneError || '麦克风输入暂时不可用');
        return;
      }
    }

    if (
      activeRef.current &&
      remoteMicrophoneRevision > 0 &&
      remoteMicrophone !== 'active'
    ) {
      releaseWithoutProtocol(remoteMicrophoneError);
    }
  }, [
    clearPendingStart,
    releaseWithoutProtocol,
    remoteMicrophone,
    remoteMicrophoneError,
    remoteMicrophoneRevision,
    remoteMicrophoneStreamID,
    resetConnection,
    sendBinary,
    setDucked
  ]);

  useEffect(() => {
    if (controlSocketState === 'connected') return;
    releaseWithoutProtocol();
  }, [controlSocketState, releaseWithoutProtocol]);

  useEffect(() => {
    if (enabled && canControl) return;
    if (controlSocketState === 'connected') stopTalking();
    else releaseWithoutProtocol();
  }, [canControl, controlSocketState, enabled, releaseWithoutProtocol, stopTalking]);

  useEffect(() => {
    if (enabled) return;
    destroyRuntime();
    setState(INITIAL_STATE);
  }, [destroyRuntime, enabled]);

  useEffect(() => {
    mountedRef.current = true;
    const release = () => stopRef.current();
    const visibilityChanged = () => {
      if (document.visibilityState !== 'visible') release();
    };
    window.addEventListener('blur', release);
    window.addEventListener('pagehide', release);
    document.addEventListener('visibilitychange', visibilityChanged);
    return () => {
      mountedRef.current = false;
      window.removeEventListener('blur', release);
      window.removeEventListener('pagehide', release);
      document.removeEventListener('visibilitychange', visibilityChanged);
      release();
      destroyRuntime();
    };
  }, [destroyRuntime]);

  return { state, enable, startTalking, stopTalking };
}
