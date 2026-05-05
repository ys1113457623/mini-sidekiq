import { useEffect, useState } from 'react'
import { api } from '../api/client'
import consumer from '../cable/consumer'

// Sanity-demo card. Proves: API + CSRF + Sidekiq enqueue + Redis cache
// + Action Cable broadcast all wired correctly for the host app.
//
// Props:
//   appName — display name (e.g., "Mentee")
//   appKey  — namespace (e.g., "mentee") used for the API path and channel.
export default function PingCard({ appName, appKey }) {
  const [status, setStatus] = useState('idle')
  const [latestPing, setLatestPing] = useState(null)

  useEffect(() => {
    const subscription = consumer.subscriptions.create(
      { channel: 'PingChannel', app: appKey },
      {
        received(data) {
          setLatestPing(data)
          setStatus('received')
        },
      }
    )
    return () => subscription.unsubscribe()
  }, [appKey])

  const sendPing = async () => {
    setStatus('sending')
    try {
      await api(`/${appKey}/ping`, { method: 'POST' })
      setStatus('queued')
    } catch (err) {
      setStatus('error')
      setLatestPing({ error: err.message })
    }
  }

  return (
    <div className="max-w-xl mx-auto mt-16 p-8 bg-white rounded-2xl shadow-sm border border-slate-200">
      <h1 className="text-3xl font-semibold tracking-tight">{appName}</h1>
      <p className="mt-2 text-slate-600">
        Sandbox app running on Rails 8 + React 19 + Vite + Tailwind 4.
      </p>

      <button
        onClick={sendPing}
        disabled={status === 'sending'}
        className="mt-6 px-4 py-2 rounded-lg bg-slate-900 text-white text-sm font-medium hover:bg-slate-700 disabled:opacity-50"
      >
        {status === 'sending' ? 'Pinging…' : 'Ping Sidekiq + Redis + Action Cable'}
      </button>

      <div className="mt-4 text-sm">
        <span className="font-medium text-slate-700">status:</span>{' '}
        <code className="px-1.5 py-0.5 rounded bg-slate-100 text-slate-800">{status}</code>
      </div>

      {latestPing && (
        <pre className="mt-4 p-3 rounded-lg bg-slate-900 text-slate-100 text-xs overflow-x-auto">
{JSON.stringify(latestPing, null, 2)}
        </pre>
      )}
    </div>
  )
}
