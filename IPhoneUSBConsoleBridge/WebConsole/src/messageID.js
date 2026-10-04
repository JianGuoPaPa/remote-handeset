let fallbackCounter = 0;

/// IDs are used only to correlate heartbeat replies; they are not credentials.
/// randomUUID is SecureContext-only in some browsers, while getRandomValues is
/// available on non-secure contexts as well.
export function createMessageID() {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID();
  }
  if (typeof globalThis.crypto?.getRandomValues === 'function') {
    const values = new Uint32Array(4);
    globalThis.crypto.getRandomValues(values);
    return Array.from(values, (value) => value.toString(16).padStart(8, '0')).join('');
  }
  fallbackCounter = (fallbackCounter + 1) >>> 0;
  return `${Date.now().toString(36)}-${fallbackCounter.toString(36)}-${Math.random().toString(36).slice(2)}`;
}
