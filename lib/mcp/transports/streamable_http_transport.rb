# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'rack'
require_relative 'base_transport'

module FastMcp
  module Transports
    # Streamable HTTP transport for MCP (spec 2025-03-26).
    #
    # Unlike the legacy HTTP+SSE transport, JSON-RPC responses are returned
    # directly in the HTTP POST response body. No persistent SSE connection is
    # required for basic request/response, which eliminates process-affinity
    # problems in multi-worker setups (e.g. Puma with WEB_CONCURRENCY > 1).
    class StreamableHttpTransport < BaseTransport
      PROTOCOL_VERSION = '2025-03-26'

      DEFAULT_ALLOWED_ORIGINS = ['localhost', '127.0.0.1', '[::1]'].freeze
      DEFAULT_ALLOWED_IPS = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].freeze

      CORS_HEADERS = {
        'Access-Control-Allow-Origin' => '*',
        'Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS',
        'Access-Control-Allow-Headers' => 'Content-Type, Accept, Mcp-Session-Id',
        'Access-Control-Expose-Headers' => 'Mcp-Session-Id',
        'Access-Control-Max-Age' => '86400'
      }.freeze

      attr_reader :app, :path_prefix, :allowed_origins, :localhost_only, :allowed_ips

      def initialize(app, server, options = {})
        super(server, logger: options[:logger])
        @app = app
        @path_prefix = options[:path_prefix] || '/mcp'
        @allowed_origins = options[:allowed_origins] || DEFAULT_ALLOWED_ORIGINS
        @localhost_only = options.fetch(:localhost_only, true)
        @allowed_ips = options[:allowed_ips] || DEFAULT_ALLOWED_IPS
        @running = false
      end

      def protocol_version
        PROTOCOL_VERSION
      end

      def start
        @logger.debug("Starting Streamable HTTP transport on #{@path_prefix}")
        @running = true
      end

      def stop
        @logger.debug('Stopping Streamable HTTP transport')
        @running = false
      end

      # Capture response in thread-local for direct HTTP delivery.
      def send_json_rpc_response(message)
        Thread.current[:fast_mcp_streamable_response] = message
      end

      # Broadcast notifications. Phase 1: log only (no GET SSE stream yet).
      def send_message(message)
        @logger.debug("Streamable HTTP broadcast (no-op in Phase 1): #{message.inspect}")
      end

      # Rack interface
      def call(env)
        request = Rack::Request.new(env)

        if request.path == @path_prefix || request.path == "#{@path_prefix}/"
          @server.transport = self
          handle_streamable_request(request, env)
        else
          @app.call(env)
        end
      end

      private

      def handle_streamable_request(request, env)
        return forbidden_response('Forbidden: Remote IP not allowed') unless valid_client_ip?(request)
        return forbidden_response('Forbidden: Origin validation failed') unless validate_origin(request, env)

        case request.request_method
        when 'POST'   then handle_post(request, env)
        when 'GET'    then handle_get
        when 'DELETE'  then handle_delete
        when 'OPTIONS' then handle_options
        else
          [405, { 'Content-Type' => 'application/json', 'Allow' => 'POST, GET, DELETE, OPTIONS' },
           [JSON.generate(jsonrpc_error(-32_601, 'Method not allowed'))]]
        end
      end

      # --- POST: the core Streamable HTTP handler ---

      def handle_post(request, env)
        accept = request.get_header('HTTP_ACCEPT') || ''
        unless accept.include?('application/json') && accept.include?('text/event-stream')
          return [406, { 'Content-Type' => 'application/json' },
                  [JSON.generate(jsonrpc_error(-32_600,
                    'Accept header must include application/json and text/event-stream'))]]
        end

        body = request.body.read
        begin
          parsed = JSON.parse(body)
        rescue JSON::ParserError => e
          @logger.error("Invalid JSON: #{e.message}")
          return [400, { 'Content-Type' => 'application/json' },
                  [JSON.generate(jsonrpc_error(-32_700, 'Parse error: Invalid JSON'))]]
        end

        request_server = get_server_for_request(request, env)
        if request_server != @server
          original_transport = request_server.transport
          request_server.transport = self
        end

        begin
          if notification_or_response?(parsed)
            headers = extract_headers(request)
            request_server.handle_request(body, headers: headers)
            [202, {}, []]
          else
            process_request(parsed, body, request, request_server)
          end
        ensure
          request_server.transport = original_transport if original_transport
        end
      end

      def process_request(parsed, body, request, request_server)
        headers = extract_headers(request)

        Thread.current[:fast_mcp_streamable_response] = nil
        request_server.handle_request(body, headers: headers)
        response = Thread.current[:fast_mcp_streamable_response]

        response_headers = { 'Content-Type' => 'application/json' }.merge(CORS_HEADERS)

        if parsed['method'] == 'initialize'
          session_id = SecureRandom.uuid
          response_headers['Mcp-Session-Id'] = session_id
        end

        if response
          [200, response_headers, [response.is_a?(String) ? response : JSON.generate(response)]]
        else
          [200, response_headers, ['{}' ]]
        end
      end

      # --- GET: SSE for server-initiated notifications (Phase 2) ---

      def handle_get
        [405, { 'Content-Type' => 'application/json', 'Allow' => 'POST, DELETE, OPTIONS' },
         [JSON.generate(jsonrpc_error(-32_601, 'GET SSE stream not yet supported'))]]
      end

      # --- DELETE: session termination ---

      def handle_delete
        [200, { 'Content-Type' => 'application/json' }, ['{}' ]]
      end

      # --- OPTIONS: CORS preflight ---

      def handle_options
        [204, CORS_HEADERS.merge('Content-Type' => 'text/plain'), []]
      end

      # --- Helpers ---

      def notification_or_response?(parsed)
        if parsed.is_a?(Array)
          parsed.all? { |msg| msg.is_a?(Hash) && msg['id'].nil? }
        else
          parsed.is_a?(Hash) && !parsed.key?('id')
        end
      end

      def extract_headers(request)
        request.env.select { |k, _v| k.start_with?('HTTP_') }
               .transform_keys { |k| k.sub('HTTP_', '').downcase.tr('_', '-') }
      end

      def get_server_for_request(request, env)
        if env['fast_mcp.server']
          return env['fast_mcp.server']
        end

        if @server.contains_filters?
          cache_key = { path: request.path, params: request.params.sort.to_h }.hash
          @filtered_servers_cache ||= {}
          @filtered_servers_cache[cache_key] ||= @server.create_filtered_copy(request)
          return @filtered_servers_cache[cache_key]
        end

        @server
      end

      def valid_client_ip?(request)
        return true unless @localhost_only

        client_ip = request.ip
        unless @allowed_ips.include?(client_ip)
          @logger.warn("Blocked connection from non-localhost IP: #{client_ip}")
          return false
        end
        true
      end

      def validate_origin(request, env)
        origin = env['HTTP_ORIGIN']
        origin = env['HTTP_REFERER'] || request.host if origin.nil? || origin.empty?
        hostname = extract_hostname(origin)

        if hostname && !allowed_origins.empty?
          is_allowed = allowed_origins.any? do |allowed|
            allowed.is_a?(Regexp) ? hostname.match?(allowed) : hostname == allowed
          end
          unless is_allowed
            @logger.warn("Blocked request with origin: #{hostname}")
            return false
          end
        end
        true
      end

      def extract_hostname(url)
        return nil if url.nil? || url.empty?

        has_scheme = url.match?(%r{^[a-zA-Z][a-zA-Z0-9+.-]*://})
        parsing_url = has_scheme ? url : "http://#{url}"
        uri = URI.parse(parsing_url)
        return nil if uri.host.nil? || uri.host.empty?

        uri.host
      rescue URI::InvalidURIError
        url.split(':').first if url.match?(%r{^([^:/]+)(:\d+)?$})
      end

      def forbidden_response(message)
        [403, { 'Content-Type' => 'application/json' },
         [JSON.generate(jsonrpc_error(-32_600, message))]]
      end

      def jsonrpc_error(code, message, id = nil)
        { jsonrpc: '2.0', error: { code: code, message: message }, id: id }
      end
    end
  end
end
