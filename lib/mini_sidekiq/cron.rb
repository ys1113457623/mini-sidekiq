module MiniSidekiq
  class Cron
    POLL_INTERVAL = 5.0

    Entry = Struct.new(:name, :expression, :job_class, :queue, :next_fire_at, keyword_init: true)

    @entries = []

    class << self
      attr_reader :entries

      def register(name, expression, job_class, queue: DEFAULT_QUEUE)
        parser = Fugit.parse_cron(expression)
        raise ArgumentError, "invalid cron expression: #{expression.inspect}" unless parser

        @entries << Entry.new(
          name: name,
          expression: parser,
          job_class: job_class,
          queue: queue.to_s,
          next_fire_at: parser.next_time(Time.now).to_f
        )
      end

      def reset!
        @entries = []
      end
    end

    def initialize(shutdown_flag, entries: Cron.entries)
      @shutdown = shutdown_flag
      @entries = entries
    end

    def run
      until @shutdown.true?
        tick
        sleep POLL_INTERVAL
      end
    end

    def tick(now = Time.now.to_f)
      @entries.each do |entry|
        next if entry.next_fire_at > now

        Client.push(class_name: entry.job_class.name, queue: entry.queue)
        entry.next_fire_at = entry.expression.next_time(Time.at(now)).to_f
      end
    end
  end
end
