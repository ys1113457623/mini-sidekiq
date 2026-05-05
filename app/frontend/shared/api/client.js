// Shared API client. All JSON traffic goes through here so CSRF + content-type
// concerns are centralized. Same-origin cookies authenticate the user once
// auth lands.

const csrfToken = () =>
  document.querySelector('meta[name="csrf-token"]')?.content || ''

export class ApiError extends Error {
  constructor(status, payload) {
    super(payload?.message || payload?.error || `HTTP ${status}`)
    this.status = status
    this.payload = payload
  }
}

export async function api(path, { method = 'GET', body, headers = {} } = {}) {
  const res = await fetch(`/api/v1${path}`, {
    method,
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
      'X-CSRF-Token': csrfToken(),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  })

  const text = await res.text()
  const json = text ? JSON.parse(text) : null

  if (!res.ok) throw new ApiError(res.status, json)
  return json
}
