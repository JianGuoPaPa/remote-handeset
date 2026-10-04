import { useCallback, useEffect, useRef, useState } from 'react';
import { websocketURL } from './api.js';
import { createMessageID } from './messageID.js';

const INITIAL_STATE = Object.freeze({
  socket: 'disconnected',
  control: 'unknown',
  usbVideo: 'unknown',
  deviceName: null,
  width: null,
  height: null,
  microphone: 'unknown',
  microphoneStreamID: null,
  microphoneRevision: 0,
  microphoneError: null,
  rttMs: null,
  error: null
});

const MICROPHONE_PACKET_BYTES = 28 + 960 * 2;
const MICROPHONE_SOFT_BUFFER_LIMIT = MICROPHONE_PACKET_BYTES * 2;
const MICROPHONE_HARD_BUFFER_LIMIT = MICROPHONE_PACKET_BYTES * 3;
const CONTROL_HEARTBEAT_INTERVAL_MS = 2_000;
const CONTROL_HEARTBEAT_TIMEOUT_MS = 8_000;
const CONTROLLER_BUSY_RETRY_MS = 15_000;

function isOpen(socket) {
  return socket?.readyState === WebSocket.OPEN;
}

export function useControlSocket(enabled, onUnauthorized) {
  const socketRef = useRef(null);
  const retryRef = useRef(null);
  const pingTimerRef = useRef(null);
  const reconnectAttemptRef = useRef(0);
  const retryFloorRef = useRef(0);
  const pingSentAtRef = useRef(new Map());
  const lastPongAtRef = useRef(0);
  const sequenceRef = useRef(0);
  const aliveRef = useRef(false);
  const [state, setState] = useState(INITIAL_STATE);

  const send = useCallback((message) => {
    const socket = socketRef.current;
    if (!isOpen(socket)) return false;
    socket.send(JSON.stringify({ v: 1, ...message }));
    return true;
  }, []);

  const sendBinary = useCallback((payload, options = {}) => {
    const socket = socketRef.current;
    if (!isOpen(socket) || !(payload instanceof ArrayBuffer || ArrayBuffer.isView(payload))) return false;
    const critical = options.critical === true;
    if (socket.bufferedAmount >= MICROPHONE_HARD_BUFFER_LIMIT) {
      if (critical) socket.close(4002, 'microphone backpressure');
      return false;
    }
    if (!critical && socket.bufferedAmount >= MICROPHONE_SOFT_BUFFER_LIMIT) return false;
    socket.send(payload);
    return true;
  }, []);

  const resetConnection = useCallback((reason = 'client resync') => {
    const socket = socketRef.current;
    if (!socket || socket.readyState >= WebSocket.CLOSING) return false;
    socket.close(4001, String(reason).slice(0, 96));
    return true;
  }, []);

  const nextSequence = useCallback(() => {
    sequenceRef.current = (sequenceRef.current + 1) >>> 0;
    return sequenceRef.current;
  }, []);

  useEffect(() => {
    aliveRef.current = enabled;
    if (!enabled) {
      setState(INITIAL_STATE);
      return undefined;
    }

    const clearTimers = () => {
      window.clearTimeout(retryRef.current);
      window.clearInterval(pingTimerRef.current);
      retryRef.current = null;
      pingTimerRef.current = null;
    };

    const scheduleReconnect = () => {
      if (!aliveRef.current || retryRef.current) return;
      const attempt = reconnectAttemptRef.current++;
      const base = Math.min(5000, 350 * (2 ** Math.min(attempt, 4)));
      const delay = Math.max(base, retryFloorRef.current) + Math.random() * 250;
      retryFloorRef.current = 0;
      retryRef.current = window.setTimeout(() => {
        retryRef.current = null;
        connect();
      }, delay);
    };

    const startPings = () => {
      window.clearInterval(pingTimerRef.current);
      pingTimerRef.current = window.setInterval(() => {
        const socket = socketRef.current;
        if (!isOpen(socket)) return;
        if (performance.now() - lastPongAtRef.current > CONTROL_HEARTBEAT_TIMEOUT_MS) {
          socket.close(4000, 'control heartbeat timeout');
          return;
        }
        const id = createMessageID();
        const sentAt = performance.now();
        pingSentAtRef.current.set(id, sentAt);
        socket.send(JSON.stringify({
          v: 1,
          type: 'ping',
          id,
          clientTimeMs: performance.timeOrigin + sentAt
        }));
        if (pingSentAtRef.current.size > 8) {
          const oldest = pingSentAtRef.current.keys().next().value;
          pingSentAtRef.current.delete(oldest);
        }
      }, CONTROL_HEARTBEAT_INTERVAL_MS);
    };

    function connect() {
      if (!aliveRef.current) return;
      const socket = new WebSocket(websocketURL('/ws/control'));
      socketRef.current = socket;
      setState((current) => ({ ...current, socket: 'connecting' }));

      socket.addEventListener('open', () => {
        if (socketRef.current !== socket) return;
        pingSentAtRef.current.clear();
        lastPongAtRef.current = performance.now();
        setState((current) => ({ ...current, socket: 'connected' }));
        startPings();
      });

      socket.addEventListener('message', (event) => {
        if (socketRef.current !== socket) return;
        if (typeof event.data !== 'string') return;
        let message;
        try {
          message = JSON.parse(event.data);
        } catch {
          return;
        }
        if (message?.v !== 1) return;

        if (message.type === 'state') {
          reconnectAttemptRef.current = 0;
          setState((current) => ({
            ...current,
            control: message.control ?? current.control,
            usbVideo: message.usbVideo ?? current.usbVideo,
            deviceName: message.deviceName ?? current.deviceName,
            width: Number.isFinite(message.width) ? message.width : current.width,
            height: Number.isFinite(message.height) ? message.height : current.height,
            error: message.control === 'connected' ? null : current.error
          }));
        } else if (message.type === 'microphoneState') {
          const streamID = Number.isInteger(message.streamID) && message.streamID > 0
            ? (message.streamID >>> 0)
            : null;
          setState((current) => ({
            ...current,
            microphone: typeof message.state === 'string' ? message.state : current.microphone,
            microphoneStreamID: streamID,
            microphoneRevision: current.microphoneRevision + 1,
            microphoneError: message.state === 'active' || message.state === 'ready'
              ? null
              : (typeof message.message === 'string' ? message.message : current.microphoneError)
          }));
        } else if (message.type === 'pong' && message.id) {
          const sentAt = pingSentAtRef.current.get(message.id);
          if (sentAt !== undefined) {
            pingSentAtRef.current.delete(message.id);
            lastPongAtRef.current = performance.now();
            reconnectAttemptRef.current = 0;
            const rttMs = Math.max(0, Math.round(performance.now() - sentAt));
            setState((current) => ({ ...current, rttMs }));
          }
        } else if (message.type === 'error' && message.code === 'unauthorized') {
          onUnauthorized?.();
        } else if (message.type === 'error') {
          const microphoneError = message.code === 'microphone_busy' || message.code === 'microphone_unavailable';
          if (message.code === 'controller_busy') retryFloorRef.current = CONTROLLER_BUSY_RETRY_MS;
          setState((current) => ({
            ...current,
            control: message.code === 'controller_busy' || message.code === 'control_unavailable'
              ? 'disconnected'
              : current.control,
            microphone: microphoneError ? 'unavailable' : current.microphone,
            microphoneStreamID: microphoneError ? null : current.microphoneStreamID,
            microphoneRevision: microphoneError
              ? current.microphoneRevision + 1
              : current.microphoneRevision,
            microphoneError: microphoneError && typeof message.message === 'string'
              ? message.message
              : current.microphoneError,
            error: typeof message.message === 'string' ? message.message : current.error
          }));
        }
      });

      socket.addEventListener('close', (event) => {
        if (socketRef.current !== socket) return;
        window.clearInterval(pingTimerRef.current);
        pingTimerRef.current = null;
        socketRef.current = null;
        pingSentAtRef.current.clear();
        setState((current) => ({
          ...current,
          socket: 'disconnected',
          control: 'unknown',
          microphone: 'unknown',
          microphoneStreamID: null,
          microphoneRevision: current.microphoneRevision + 1,
          microphoneError: null
        }));
        if (event.code === 4401) onUnauthorized?.();
        else scheduleReconnect();
      });

      socket.addEventListener('error', () => {
        socket.close();
      });
    }

    connect();

    return () => {
      aliveRef.current = false;
      clearTimers();
      pingSentAtRef.current.clear();
      const socket = socketRef.current;
      socketRef.current = null;
      if (socket && socket.readyState < WebSocket.CLOSING) socket.close(1000, 'client closing');
    };
  }, [enabled, onUnauthorized]);

  return { state, send, sendBinary, nextSequence, resetConnection };
}
