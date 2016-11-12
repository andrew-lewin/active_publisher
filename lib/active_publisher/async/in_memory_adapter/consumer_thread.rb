require 'pry'
module ActivePublisher
  module Async
    module InMemoryAdapter
      class ConsumerThread
        attr_reader :current_message, :thread, :queue

        if ::RUBY_PLATFORM == "java"
          NETWORK_ERRORS = [::MarchHare::Exception, ::Java::ComRabbitmqClient::AlreadyClosedException, ::Java::JavaIo::IOException].freeze
        else
          NETWORK_ERRORS = [::Bunny::Exception, ::Timeout::Error, ::IOError].freeze
        end

        def initialize(listen_queue)
          @queue = listen_queue
          start_thread
        end

        def alive?
          @thread && @thread.alive?
        end

        def kill
          @thread.kill if @thread
          @thread = nil
        end

        private

        def await_network_reconnect
          sleep ::ActivePublisher::RabbitConnection::NETWORK_RECOVERY_INTERVAL
        end

        def start_thread
          return if alive?
          @thread = ::Thread.new do
            loop do
              # Write "current_message" so we can requeue should something happen to the consumer.
              @current_message = message = queue.pop

              begin
                ::ActivePublisher.publish(message.route, message.payload, message.exchange_name, message.options)

                # Reset
                @current_message = nil
              rescue *NETWORK_ERRORS
                # Sleep because connection is down
                await_network_reconnect

                # Requeue and try again.
                queue.push(@current_message) if @current_message
              rescue => unknown_error
                # Do not requeue the message because something else horrible happened.
                @current_message = nil

                ::ActivePublisher.configuration.error_handler.call(unknown_error, {:route => message.route, :payload => message.payload, :exchange_name => message.exchange_name, :options => message.options})

                # TODO: Find a way to bubble this out of the thread for logging purposes.
                # Reraise the error out of the publisher loop. The Supervisor will restart the consumer.
                raise unknown_error
              end
            end
          end
        end
      end
    end
  end
end
