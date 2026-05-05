import { createConsumer } from '@rails/actioncable'

// Single shared Action Cable connection. Each per-app feature subscribes to
// its own channel through this consumer.
const consumer = createConsumer('/cable')

export default consumer
