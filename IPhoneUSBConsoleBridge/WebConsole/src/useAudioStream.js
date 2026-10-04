import { useCallback, useEffect, useRef, useState } from 'react';
import { websocketURL } from './api.js';
import { createMessageID } from './messageID.js';

const AUDIO_HEADER_BYTES = 24;
const AUDIO_MAGIC = [0x49, 0x55, 0x41, 0x43]; // IUAC
const WORKLET_URL = new URL('./audio-io-worklet.js', import.meta.url).href;
const AUDIO_HEARTBEAT_INTERVAL_MS = 5_000;
const AUDIO_HEARTBEAT_TIMEOUT_MS = 15_000;
const VIEWER_LIMIT_RETRY_MS = 15_000;
const PCM_CODEC = 'pcm_s16le';
const PCM_SAMPLE_RATE = 48_000;
const PCM_CHANNELS = 2;
const PCM_PACKET_FRAMES = 960;
const PCM_START_BUFFER_FRAMES = PCM_PACKET_FRAMES * 3;
const PCM_MAX_QUEUE_SECONDS = 0.24;
const PCM_START_LEAD_SECONDS = 0.01;

const INITIAL_STATE = Object.freeze({
  enabled: false,
  socket: 'disconnected',
  decoder: 'idle',
  muted: true,
  error: null
});

function parseAudioPacket(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < AUDIO_HEADER_BYTES) return null;
  const bytes = new Uint8Array(buffer);
  if (!AUDIO_MAGIC.every((value, index) => bytes[index] === value) || bytes[4] !== 1) return null;
  const view = new DataView(buffer);
  const headerLength = view.getUint16(6, false);
  const payloadLength = view.getUint16(22, false);
  if (headerLength !== AUDIO_HEADER_BYTES || payloadLength < 1 || headerLength + payloadLength !== buffer.byteLength) {
    return null;
  }
  const timestamp = Number(view.getBigUint64(8, false));
  if (!Number.isSafeInteger(timestamp)) return null;
  const durationFrames = view.getUint16(20, false);
  if (durationFrames < 1) return null;
  return {
    discontinuity: (bytes[5] & 0x01) !== 0,
    timestamp,
    sequence: view.getUint32(16, false),
    durationFrames,
    data: new Uint8Array(buffer, headerLength, payloadLength)
  };
}

function closeDecoder(decoder) {
  if (decoder && decoder.state !== 'closed') {
    try { decoder.close(); } catch { /* The decoder may already be closing. */ }
  }
}

function stopPCMPlayback(runtime) {
  if (!runtime || runtime.mode !== 'pcm') return;
  runtime.timelineGeneration += 1;
  for (const source of runtime.sources) {
    source.onended = null;
    try { source.stop(); } catch { /* It may already have ended. */ }
    source.disconnect();
  }
  runtime.sources.clear();
  runtime.pending.length = 0;
  runtime.pendingFrames = 0;
  runtime.nextStartTime = null;
  runtime.started = false;
}

function createPCMBuffer(runtime, packet, numberOfChannels) {
  const expectedBytes = packet.durationFrames * numberOfChannels * Int16Array.BYTES_PER_ELEMENT;
  if (
    packet.durationFrames !== PCM_PACKET_FRAMES ||
    numberOfChannels !== PCM_CHANNELS ||
    packet.data.byteLength !== expectedBytes
  ) return null;

  const buffer = runtime.context.createBuffer(numberOfChannels, packet.durationFrames, PCM_SAMPLE_RATE);
  const view = new DataView(packet.data.buffer, packet.data.byteOffset, packet.data.byteLength);
  const planes = Array.from({ length: numberOfChannels }, (_, channel) => buffer.getChannelData(channel));
  for (let frame = 0; frame < packet.durationFrames; frame += 1) {
    for (let channel = 0; channel < numberOfChannels; channel += 1) {
      planes[channel][frame] = view.getInt16((frame * numberOfChannels + channel) * 2, true) / 32768;
    }
  }
  return buffer;
}

function schedulePCMBuffer(runtime, buffer) {
  const now = runtime.context.currentTime;
  const startAt = runtime.nextStartTime ?? (now + PCM_START_LEAD_SECONDS);
  if (
    startAt < now - 0.002 ||
    Math.max(0, startAt - now) + buffer.duration > PCM_MAX_QUEUE_SECONDS
  ) return false;

  const generation = runtime.timelineGeneration;
  const source = runtime.context.createBufferSource();
  source.buffer = buffer;
  source.connect(runtime.gainNode);
  runtime.sources.add(source);
  source.onended = () => {
    runtime.sources.delete(source);
    source.disconnect();
    if (runtime.timelineGeneration === generation && runtime.sources.size === 0 && runtime.pending.length === 0) {
      runtime.started = false;
      runtime.nextStartTime = null;
    }
  };
  source.start(startAt);
  runtime.nextStartTime = startAt + buffer.duration;
  return true;
}

function enqueuePCMBuffer(runtime, buffer) {
  if (!runtime.started) {
    runtime.pending.push(buffer);
    runtime.pendingFrames += buffer.length;
    if (runtime.pendingFrames < PCM_START_BUFFER_FRAMES) return;
    runtime.started = true;
    runtime.nextStartTime = runtime.context.currentTime + PCM_START_LEAD_SECONDS;
    const startup = runtime.pending.splice(0);
    runtime.pendingFrames = 0;
    for (const pendingBuffer of startup) {
      if (!schedulePCMBuffer(runtime, pendingBuffer)) {
        stopPCMPlayback(runtime);
        runtime.pending.push(buffer);
        runtime.pendingFrames = buffer.length;
        return;
      }
    }
    return;
  }

  if (!schedulePCMBuffer(runtime, buffer)) {
    stopPCMPlayback(runtime);
    runtime.pending.push(buffer);
    runtime.pendingFrames = buffer.length;
  }
}

function disposeRuntime(runtime) {
  if (!runtime) return;
  if (runtime.mode === 'opus') {
    runtime.outputNode.port.postMessage({ type: 'reset' });
    runtime.outputNode.disconnect();
  } else {
    stopPCMPlayback(runtime);
  }
  runtime.gainNode.disconnect();
  void runtime.context.close().catch(() => {});
}

export function useAudioStream(authenticated, onUnauthorized) {
  const [requested, setRequested] = useState(false);
  const [state, setState] = useState(INITIAL_STATE);
  const runtimeRef = useRef(null);
  const initializationRef = useRef(null);
  const generationRef = useRef(0);
  const authenticatedRef = useRef(authenticated);
  authenticatedRef.current = authenticated;

  const destroyRuntime = useCallback(() => {
    generationRef.current += 1;
    const runtime = runtimeRef.current;
    runtimeRef.current = null;
    disposeRuntime(runtime);
  }, []);

  const enable = useCallback(() => {
    if (!authenticatedRef.current) return Promise.resolve(false);
    const existingInitialization = initializationRef.current;
    if (existingInitialization) {
      if (existingInitialization.generation === generationRef.current) {
        return existingInitialization.promise;
      }
      return existingInitialization.promise.then(() => enable());
    }
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) {
      setState({ ...INITIAL_STATE, decoder: 'unsupported', error: '此浏览器不支持低延迟音频' });
      return Promise.resolve(false);
    }
    const supportsOpusPath = (
      'AudioDecoder' in window &&
      'EncodedAudioChunk' in window &&
      'AudioWorkletNode' in window
    );

    const generation = generationRef.current + 1;
    generationRef.current = generation;
    const initialize = async () => {
      let createdRuntime = null;
      let initializingContext = null;
      try {
        let runtime = runtimeRef.current;
        if (!runtime || runtime.context.state === 'closed') {
          let context;
          try {
            context = new AudioContextClass({ latencyHint: 'interactive', sampleRate: PCM_SAMPLE_RATE });
          } catch {
            context = new AudioContextClass();
          }
          initializingContext = context;
          await context.resume();
          if (generationRef.current !== generation || !authenticatedRef.current) {
            await context.close();
            initializingContext = null;
            return false;
          }

          if (supportsOpusPath && context.sampleRate === PCM_SAMPLE_RATE && context.audioWorklet) {
            try {
              const decoderSupport = await AudioDecoder.isConfigSupported({
                codec: 'opus',
                sampleRate: PCM_SAMPLE_RATE,
                numberOfChannels: PCM_CHANNELS
              });
              if (!decoderSupport.supported) throw new Error('unsupported_opus');
              await context.audioWorklet.addModule(WORKLET_URL);
              if (generationRef.current !== generation || !authenticatedRef.current) {
                await context.close();
                initializingContext = null;
                return false;
              }
              const outputNode = new AudioWorkletNode(context, 'phone-audio-output', {
                numberOfInputs: 0,
                numberOfOutputs: 1,
                outputChannelCount: [2]
              });
              const gainNode = context.createGain();
              gainNode.gain.value = 1;
              outputNode.connect(gainNode).connect(context.destination);
              createdRuntime = { mode: 'opus', context, outputNode, gainNode };
            } catch {
              // PCM over an ordinary AudioContext is the intentional fallback
              // for non-secure contexts and browsers without AudioWorklet.
            }
          }

          if (!createdRuntime) {
            const gainNode = context.createGain();
            gainNode.gain.value = 1;
            gainNode.connect(context.destination);
            createdRuntime = {
              mode: 'pcm',
              context,
              gainNode,
              sources: new Set(),
              pending: [],
              pendingFrames: 0,
              nextStartTime: null,
              started: false,
              timelineGeneration: 0
            };
          }
          initializingContext = null;
          runtime = createdRuntime;
        } else {
          await runtime.context.resume();
        }

        if (generationRef.current !== generation || !authenticatedRef.current) {
          if (createdRuntime) disposeRuntime(createdRuntime);
          return false;
        }
        if (createdRuntime) {
          const previousRuntime = runtimeRef.current;
          runtimeRef.current = createdRuntime;
          if (previousRuntime && previousRuntime !== createdRuntime) disposeRuntime(previousRuntime);
          createdRuntime = null;
        }
        runtime.gainNode.gain.setValueAtTime(1, runtime.context.currentTime);
        setRequested(true);
        setState((current) => ({ ...current, enabled: true, muted: false, error: null }));
        return true;
      } catch {
        if (initializingContext) void initializingContext.close().catch(() => {});
        if (createdRuntime) disposeRuntime(createdRuntime);
        if (generationRef.current !== generation || !authenticatedRef.current) return false;
        const currentRuntime = runtimeRef.current;
        runtimeRef.current = null;
        disposeRuntime(currentRuntime);
        setRequested(false);
        setState({ ...INITIAL_STATE, decoder: 'unsupported', error: '声音初始化失败' });
        return false;
      }
    };

    const promise = initialize().finally(() => {
      if (initializationRef.current?.promise === promise) initializationRef.current = null;
    });
    initializationRef.current = { generation, promise };
    return promise;
  }, []);

  const disable = useCallback(() => {
    generationRef.current += 1;
    setRequested(false);
    const runtime = runtimeRef.current;
    if (runtime) {
      if (runtime.mode === 'opus') runtime.outputNode.port.postMessage({ type: 'reset' });
      else stopPCMPlayback(runtime);
      runtime.gainNode.gain.setValueAtTime(0, runtime.context.currentTime);
      void runtime.context.suspend().catch(() => {});
    }
    setState((current) => ({
      ...INITIAL_STATE,
      decoder: current.decoder === 'unsupported' ? 'unsupported' : 'idle',
      error: current.decoder === 'unsupported' ? current.error : null
    }));
  }, []);

  const setDucked = useCallback((ducked) => {
    const runtime = runtimeRef.current;
    if (!runtime || runtime.context.state === 'closed') return;
    const now = runtime.context.currentTime;
    const gain = runtime.gainNode.gain;
    gain.cancelScheduledValues(now);
    gain.setValueAtTime(gain.value, now);
    gain.linearRampToValueAtTime(ducked ? 0.2 : 1, now + 0.015);
  }, []);

  useEffect(() => {
    if (authenticated) return;
    setRequested(false);
    destroyRuntime();
    setState(INITIAL_STATE);
  }, [authenticated, destroyRuntime]);

  useEffect(() => {
    if (!authenticated || !requested || !runtimeRef.current) return undefined;

    const runtimeMode = runtimeRef.current.mode;
    let alive = true;
    let socket = null;
    let decoder = null;
    let retryTimer = null;
    let heartbeatTimer = null;
    let reconnectAttempt = 0;
    let retryFloor = 0;
    let fatal = false;
    let activeConfig = null;
    let lastSequence = null;
    let lastInboundAt = 0;

    const stopHeartbeat = () => {
      window.clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    };

    const resetPlayback = () => {
      const runtime = runtimeRef.current;
      if (!runtime) return;
      if (runtime.mode === 'opus') runtime.outputNode.port.postMessage({ type: 'reset' });
      else stopPCMPlayback(runtime);
    };

    const resetPipeline = () => {
      resetPlayback();
      lastSequence = null;
      if (runtimeMode !== 'opus') return;
      if (!decoder || !activeConfig || decoder.state === 'closed') return;
      try {
        decoder.reset();
        decoder.configure(activeConfig);
      } catch {
        closeDecoder(decoder);
        decoder = null;
      }
    };

    const deliverDecodedAudio = (audioData) => {
      const runtime = runtimeRef.current;
      if (!alive || !runtime || runtime.mode !== 'opus') {
        audioData.close();
        return;
      }
      try {
        const planes = [];
        const transfers = [];
        for (let channel = 0; channel < audioData.numberOfChannels; channel += 1) {
          const plane = new Float32Array(audioData.numberOfFrames);
          audioData.copyTo(plane, { planeIndex: channel, format: 'f32-planar' });
          planes.push(plane.buffer);
          transfers.push(plane.buffer);
        }
        runtime.outputNode.port.postMessage({ type: 'audio', frames: audioData.numberOfFrames, planes }, transfers);
      } finally {
        audioData.close();
      }
    };

    const createDecoder = (config) => {
      closeDecoder(decoder);
      decoder = new AudioDecoder({
        output: deliverDecodedAudio,
        error: () => {
          if (!alive || !activeConfig) return;
          setState((current) => ({ ...current, decoder: 'recovering' }));
          try {
            createDecoder(activeConfig);
            resetPlayback();
            lastSequence = null;
          } catch {
            closeDecoder(decoder);
            decoder = null;
          }
        }
      });
      decoder.configure(config);
    };

    const configure = async (message, sourceSocket) => {
      if (
        message?.v !== 1 || (message.type !== 'config' && message.type !== 'audioConfig') ||
        message.sampleRate !== PCM_SAMPLE_RATE || message.numberOfChannels !== PCM_CHANNELS ||
        message.frameDurationUs !== 20_000 ||
        message.codec !== (runtimeMode === 'opus' ? 'opus' : PCM_CODEC) ||
        (runtimeMode === 'pcm' && message.sampleFormat !== 's16le-interleaved')
      ) return;

      if (runtimeMode === 'pcm') {
        if (!alive || socket !== sourceSocket) return;
        activeConfig = {
          codec: PCM_CODEC,
          sampleRate: PCM_SAMPLE_RATE,
          numberOfChannels: PCM_CHANNELS
        };
        lastSequence = null;
        reconnectAttempt = 0;
        resetPlayback();
        setState((current) => ({ ...current, decoder: 'ready', error: null }));
        return;
      }

      const config = {
        codec: 'opus',
        sampleRate: message.sampleRate,
        numberOfChannels: message.numberOfChannels
      };
      try {
        const support = await AudioDecoder.isConfigSupported(config);
        if (!alive || socket !== sourceSocket) return;
        if (!support.supported) throw new Error('unsupported');
        activeConfig = support.config ?? config;
        createDecoder(activeConfig);
        lastSequence = null;
        reconnectAttempt = 0;
        resetPlayback();
        setState((current) => ({ ...current, decoder: 'ready', error: null }));
      } catch {
        fatal = true;
        setState((current) => ({ ...current, decoder: 'unsupported', error: '浏览器不支持当前手机音频格式' }));
        socket?.close(1000, 'unsupported audio');
      }
    };

    const decodePacket = (buffer) => {
      const packet = parseAudioPacket(buffer);
      if (!packet || !activeConfig) return;
      const expected = lastSequence === null ? packet.sequence : ((lastSequence + 1) >>> 0);

      if (runtimeMode === 'pcm') {
        if (packet.discontinuity || packet.sequence !== expected) resetPipeline();
        const runtime = runtimeRef.current;
        if (!runtime || runtime.mode !== 'pcm') return;
        const pcmBuffer = createPCMBuffer(runtime, packet, activeConfig.numberOfChannels);
        if (!pcmBuffer) {
          resetPipeline();
          return;
        }
        lastSequence = packet.sequence;
        enqueuePCMBuffer(runtime, pcmBuffer);
        return;
      }

      if (decoder?.state !== 'configured') return;
      if (packet.discontinuity || packet.sequence !== expected || decoder.decodeQueueSize > 8) {
        resetPipeline();
        if (!decoder || decoder.state !== 'configured') return;
      }
      lastSequence = packet.sequence;
      try {
        decoder.decode(new EncodedAudioChunk({
          type: 'key',
          timestamp: packet.timestamp,
          duration: Math.round(packet.durationFrames * 1_000_000 / activeConfig.sampleRate),
          data: packet.data
        }));
      } catch {
        resetPipeline();
      }
    };

    const scheduleReconnect = () => {
      if (!alive || fatal || retryTimer) return;
      const base = Math.min(5_000, 350 * (2 ** Math.min(reconnectAttempt++, 4)));
      const delay = Math.max(base, retryFloor) + Math.random() * 250;
      retryFloor = 0;
      retryTimer = window.setTimeout(() => {
        retryTimer = null;
        connect();
      }, delay);
    };

    const startHeartbeat = (targetSocket) => {
      stopHeartbeat();
      lastInboundAt = performance.now();
      heartbeatTimer = window.setInterval(() => {
        if (socket !== targetSocket || targetSocket.readyState !== WebSocket.OPEN) return;
        if (performance.now() - lastInboundAt > AUDIO_HEARTBEAT_TIMEOUT_MS) {
          targetSocket.close(4000, 'audio heartbeat timeout');
          return;
        }
        targetSocket.send(JSON.stringify({
          v: 1,
          type: 'ping',
          id: createMessageID(),
          clientTimeMs: performance.timeOrigin + performance.now()
        }));
      }, AUDIO_HEARTBEAT_INTERVAL_MS);
    };

    function connect() {
      if (!alive) return;
      const endpoint = runtimeMode === 'opus' ? '/ws/audio' : '/ws/audio-pcm';
      const nextSocket = new WebSocket(websocketURL(endpoint));
      socket = nextSocket;
      nextSocket.binaryType = 'arraybuffer';
      setState((current) => ({ ...current, enabled: true, muted: false, socket: 'connecting' }));

      nextSocket.addEventListener('open', () => {
        if (socket !== nextSocket) return;
        setState((current) => ({ ...current, socket: 'connected', error: null }));
        startHeartbeat(nextSocket);
      });
      nextSocket.addEventListener('message', (event) => {
        if (socket !== nextSocket) return;
        lastInboundAt = performance.now();
        if (typeof event.data === 'string') {
          let message;
          try { message = JSON.parse(event.data); } catch { return; }
          if (message?.type === 'config' || message?.type === 'audioConfig') configure(message, nextSocket);
          else if (message?.type === 'pong') reconnectAttempt = 0;
          else if (message?.type === 'error' && message.code === 'unauthorized') onUnauthorized?.();
          else if (message?.type === 'error') {
            if (message.code === 'viewer_limit') retryFloor = VIEWER_LIMIT_RETRY_MS;
            setState((current) => ({ ...current, error: message.message || current.error }));
          }
        } else {
          decodePacket(event.data);
        }
      });
      nextSocket.addEventListener('close', (event) => {
        if (socket !== nextSocket) return;
        stopHeartbeat();
        socket = null;
        closeDecoder(decoder);
        decoder = null;
        activeConfig = null;
        lastSequence = null;
        resetPlayback();
        setState((current) => ({ ...current, socket: 'disconnected', decoder: fatal ? current.decoder : 'idle' }));
        if (event.code === 4401) onUnauthorized?.();
        else scheduleReconnect();
      });
      nextSocket.addEventListener('error', () => nextSocket.close());
    }

    connect();
    return () => {
      alive = false;
      window.clearTimeout(retryTimer);
      stopHeartbeat();
      closeDecoder(decoder);
      resetPlayback();
      if (socket && socket.readyState < WebSocket.CLOSING) socket.close(1000, 'client closing');
    };
  }, [authenticated, onUnauthorized, requested]);

  useEffect(() => () => {
    destroyRuntime();
  }, [destroyRuntime]);

  return { state, enable, disable, setDucked };
}
