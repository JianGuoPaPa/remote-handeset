const JSON_HEADERS = Object.freeze({ 'Content-Type': 'application/json' });

async function request(path, options = {}) {
  const response = await fetch(path, {
    credentials: 'same-origin',
    cache: 'no-store',
    ...options,
    headers: {
      ...(options.body ? JSON_HEADERS : {}),
      ...(options.headers ?? {})
    }
  });

  const contentType = response.headers.get('content-type') ?? '';
  const payload = contentType.includes('application/json')
    ? await response.json().catch(() => null)
    : null;

  if (!response.ok) {
    const error = new Error(payload?.message || `请求失败 (${response.status})`);
    error.status = response.status;
    error.code = payload?.code;
    throw error;
  }

  return payload;
}

export const api = {
  session: () => request('/api/session'),
  login: (password) => request('/api/login', {
    method: 'POST',
    body: JSON.stringify({ password })
  }),
  logout: (csrfToken, signal) => request('/api/logout', {
    method: 'POST',
    headers: csrfToken ? { 'X-CSRF-Token': csrfToken } : undefined,
    signal
  }),
  status: () => request('/api/status')
};

export function websocketURL(path) {
  const scheme = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${window.location.host}${path}`;
}
