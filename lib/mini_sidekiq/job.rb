module MiniSidekiq
  module Job
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def mini_sidekiq_options(queue: DEFAULT_QUEUE)
        @mini_sidekiq_queue = queue.to_s
      end

      def mini_sidekiq_queue
        @mini_sidekiq_queue || DEFAULT_QUEUE
      end

      def perform_async(*args)
        Client.push(class_name: name, args: args, queue: mini_sidekiq_queue)
      end

      def perform_in(seconds, *args)
        Client.push(
          class_name: name,
          args: args,
          queue: mini_sidekiq_queue,
          run_at: Time.now.to_f + seconds.to_f
        )
      end

      def perform_at(time, *args)
        Client.push(
          class_name: name,
          args: args,
          queue: mini_sidekiq_queue,
          run_at: time.to_f
        )
      end

      def perform_inline(*args)
        new.perform(*args)
      end
    end
  end
end
