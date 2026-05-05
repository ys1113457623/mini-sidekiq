import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from '../career_hubs/App'
import '../shared/styles/application.css'

const root = createRoot(document.getElementById('root'))
root.render(
  <BrowserRouter basename="/career-hubs">
    <App />
  </BrowserRouter>
)
