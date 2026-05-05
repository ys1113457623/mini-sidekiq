import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from '../assessments/App'
import '../shared/styles/application.css'

const root = createRoot(document.getElementById('root'))
root.render(
  <BrowserRouter basename="/assessments">
    <App />
  </BrowserRouter>
)
