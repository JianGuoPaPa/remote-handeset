import { useEffect, useRef, useState } from 'react';
import { websocketURL } from './api.js';

const HEADER_SIZE = 20;
const MAGIC = [0x49, 0x55, 0x56, 0x43]; // IUVC

function decodeBase64(value) {
  const binary = window.atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function parseFrame(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < HEADER_SIZE) return null;
  const bytes = new Uint8Array(buffer);
  if (!MAGIC.every((value, index) => bytes[index] === value) || bytes[4] !== 1) return null;
  const view = new DataView(buffer);
  const headerLength = view.getUint16(6, false);
  if (headerLength < HEADER_SIZE || headerLength > buffer.byteLength) return null;
  const timestamp = Number(view.getBigUint64(8, false));
  if (!Number.isSafeInteger(timestamp)) return null;
  return {
    key: (bytes[5] & 0x01) !== 0,
    timestamp,
    sequence: view.getUint32(16, false),
    data: new Uint8Array(buffer, headerLength)
  };
}

const INITIAL_STATE = Object.freeze({
  socket: 'disconnected',
  decoder: 'idle',
  fps: null,
  width: null,
  height: null,
  error: null
});

export function useVideoStream(canvasRef, enabled, onUnauthorized) {
  const [state, setState] = useState(INITIAL_STATE);

  useEffect(() => {
    if (!enabled) {
      setState(INITIAL_STATE);
      return undefined;
    }

    if (!('VideoDecoder' in window) || !('EncodedVideoChunk' in window)) {
      setState({ ...INITIAL_STATE, decoder: 'unsupported', error: '此浏览器不支持 H.264 WebCodecs' });
      return undefined;
    }

    let alive = true;
    let socket = null;
    let decoder = null;
    let retryTimer = null;
    let livenessTimer = null;
    let reconnectAttempt = 0;
    let configured = false;
    let activeDecoderConfig = null;
    let waitingForKey = true;
    let lastSequence = null;
    let lastResyncAt = 0;
    let pendingFrame = null;
    let drawRequest = null;
    let displayed = 0;
    let fpsWindowStarted = performance.now();
    let lastBinaryAt = performance.now();
    let lastDecodedAt = performance.now();

    const requestResync = () => {
      const now = performance.now();
      if (socket?.readyState !== WebSocket.OPEN || now - lastResyncAt < 250) return;
      lastResyncAt = now;
      socket.send(JSON.stringify({
        v: 1,
        type: 'resync',
        afterSequence: lastSequence
      }));
    };

    const resetForKeyframe = () => {
      waitingForKey = true;
      try {
        if (decoder?.state === 'configured') decoder.reset();
      } catch {
        // A close/reset race is harmless; the next configuration reinitializes decoding.
      }
      requestResync();
    };

    const drawLatest = () => {
      drawRequest = null;
      const frame = pendingFrame;
      pendingFrame = null;
      if (!frame) return;
      const canvas = canvasRef.current;
      if (!canvas) {
        frame.close();
        return;
      }
      const width = frame.displayWidth || frame.codedWidth;
      const height = frame.displayHeight || frame.codedHeight;
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        setState((current) => ({ ...current, width, height }));
      }
      const context = canvas.getContext('2d', { alpha: false, desynchronized: true });
      context.drawImage(frame, 0, 0, width, height);
      frame.close();
      displayed += 1;
      const now = performance.now();
      const elapsed = now - fpsWindowStarted;
      if (elapsed >= 1000) {
        const fps = displayed * 1000 / elapsed;
        displayed = 0;
        fpsWindowStarted = now;
        setState((current) => ({ ...current, fps }));
      }
    };

    const onDecodedFrame = (frame) => {
      if (!alive) {
        frame.close();
        return;
      }
      lastDecodedAt = performance.now();
      pendingFrame?.close();
      pendingFrame = frame;
      if (!drawRequest) drawRequest = window.requestAnimationFrame(drawLatest);
    };

    const createDecoder = (config) => {
      if (decoder && decoder.state !== 'closed') decoder.close();
      decoder = new VideoDecoder({
        output: onDecodedFrame,
        error: () => {
          if (!alive || !activeDecoderConfig) return;
          setState((current) => ({ ...current, decoder: 'recovering' }));
          try {
            createDecoder(activeDecoderConfig);
            configured = true;
            waitingForKey = true;
            requestResync();
          } catch {
            configured = false;
          }
        }
      });
      decoder.configure(config);
    };

    const configureDecoder = async (message) => {
      if (
        message?.v !== 1 || message.type !== 'config' || typeof message.codec !== 'string' ||
        !Number.isFinite(message.codedWidth) || !Number.isFinite(message.codedHeight) ||
        typeof message.description !== 'string'
      ) return;

      const config = {
        codec: message.codec,
        codedWidth: message.codedWidth,
        codedHeight: message.codedHeight,
        description: decodeBase64(message.description),
        hardwareAcceleration: 'prefer-hardware',
        optimizeForLatency: true
      };

      try {
        const support = await VideoDecoder.isConfigSupported(config);
        if (!alive || !support.supported) throw new Error('浏览器不支持当前 H.264 配置');
        activeDecoderConfig = support.config ?? config;
        createDecoder(activeDecoderConfig);
        configured = true;
        waitingForKey = true;
        lastSequence = null;
        setState((current) => ({
          ...current,
          decoder: 'ready',
          width: message.codedWidth,
          height: message.codedHeight,
          error: null
        }));
        requestResync();
      } catch (error) {
        configured = false;
        setState((current) => ({
          ...current,
          decoder: 'unsupported',
          error: error instanceof Error ? error.message : '视频解码初始化失败'
        }));
      }
    };

    const decodeFrame = (buffer) => {
      const frame = parseFrame(buffer);
      if (!frame || !configured || decoder?.state !== 'configured') return;

      if (lastSequence !== null && frame.sequence !== ((lastSequence + 1) >>> 0)) {
        resetForKeyframe();
      }
      lastSequence = frame.sequence;

      if (waitingForKey && !frame.key) {
        requestResync();
        return;
      }

      if (decoder.decodeQueueSize > 4) {
        resetForKeyframe();
        if (!frame.key) return;
      }

      if (frame.key) waitingForKey = false;

      try {
        decoder.decode(new EncodedVideoChunk({
          type: frame.key ? 'key' : 'delta',
          timestamp: frame.timestamp,
          data: frame.data
        }));
        setState((current) => current.decoder === 'ready' ? current : { ...current, decoder: 'ready' });
      } catch {
        resetForKeyframe();
      }
    };

    const scheduleReconnect = () => {
      if (!alive || retryTimer) return;
      const base = Math.min(5000, 350 * (2 ** Math.min(reconnectAttempt++, 4)));
      retryTimer = window.setTimeout(() => {
        retryTimer = null;
        connect();
      }, base + Math.random() * 250);
    };

    function connect() {
      if (!alive) return;
      socket = new WebSocket(websocketURL('/ws/video'));
      socket.binaryType = 'arraybuffer';
      setState((current) => ({ ...current, socket: 'connecting' }));

      socket.addEventListener('open', () => {
        reconnectAttempt = 0;
        lastBinaryAt = performance.now();
        lastDecodedAt = lastBinaryAt;
        setState((current) => ({ ...current, socket: 'connected', error: null }));
      });

      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          let message;
          try {
            message = JSON.parse(event.data);
          } catch {
            return;
          }
          if (message.type === 'config') configureDecoder(message);
          else if (message.type === 'error' && message.code === 'unauthorized') onUnauthorized?.();
        } else {
          lastBinaryAt = performance.now();
          decodeFrame(event.data);
        }
      });

      socket.addEventListener('close', (event) => {
        configured = false;
        activeDecoderConfig = null;
        waitingForKey = true;
        setState((current) => ({ ...current, socket: 'disconnected', decoder: 'idle', fps: null }));
        if (event.code === 4401) onUnauthorized?.();
        else scheduleReconnect();
      });

      socket.addEventListener('error', () => socket.close());
    }

    connect();
    livenessTimer = window.setInterval(() => {
      if (!alive || socket?.readyState !== WebSocket.OPEN) return;
      const now = performance.now();
      const binarySilence = now - lastBinaryAt;
      const decodedSilence = now - lastDecodedAt;

      if (binarySilence >= 2500 || decodedSilence >= 2500) {
        setState((current) => ({ ...current, decoder: 'recovering', fps: null }));
        resetForKeyframe();
      }
      if (binarySilence >= 5000 || decodedSilence >= 5000) {
        socket.close(4000, 'video stalled');
      }
    }, 1000);

    return () => {
      alive = false;
      window.clearTimeout(retryTimer);
      window.clearInterval(livenessTimer);
      if (drawRequest) window.cancelAnimationFrame(drawRequest);
      pendingFrame?.close();
      if (decoder && decoder.state !== 'closed') decoder.close();
      if (socket && socket.readyState < WebSocket.CLOSING) socket.close(1000, 'client closing');
    };
  }, [canvasRef, enabled, onUnauthorized]);

  return state;
}
