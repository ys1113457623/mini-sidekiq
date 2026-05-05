import { Routes, Route, Link } from 'react-router-dom'
import PingCard from '../shared/ui/PingCard'

function Home() {
  return <PingCard appName="Mentee" appKey="mentee" />
}

function NotFound() {
  return (
    <div className="max-w-xl mx-auto mt-16 p-8 text-center">
      <h2 className="text-2xl font-semibold">Not found</h2>
      <Link to="/" className="text-sky-600 hover:underline mt-4 inline-block">
        Back to home
      </Link>
    </div>
  )
}

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Home />} />
      <Route path="*" element={<NotFound />} />
    </Routes>
  )
}
