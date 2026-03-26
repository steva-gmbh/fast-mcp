# frozen_string_literal: true

module FastMcp
  module Transports
    # Base class for all MCP transports
    # This defines the interface that all transports must implement
    class BaseTransport
      attr_reader :server, :logger

      def initialize(server, logger: nil)
        @server = server
        @logger = logger || server.logger
      end

      # Start the transport
      # This method should be implemented by subclasses
      def start
        raise NotImplementedError, "#{self.class} must implement #start"
      end

      # Stop the transport
      # This method should be implemented by subclasses
      def stop
        raise NotImplementedError, "#{self.class} must implement #stop"
      end

      # Send a message to the client
      # This method should be implemented by subclasses
      def send_message(message)
        raise NotImplementedError, "#{self.class} must implement #send_message"
      end

      # Send a JSON-RPC response to a specific client (unicast).
      # Subclasses may override; default delegates to broadcast.
      def send_json_rpc_response(message)
        send_message(message)
      end

      # Protocol version advertised during initialize handshake.
      def protocol_version
        '2024-11-05'
      end

      # Process an incoming message
      # This is a helper method that can be used by subclasses
      def process_message(message, headers: {})
        server.handle_request(message, headers: headers)
      end
    end
  end
end
