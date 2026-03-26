# frozen_string_literal: true

RSpec.describe FastMcp::Transports::StreamableHttpTransport do
  let(:app) { ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['OK']] } }
  let(:tools_response) { { jsonrpc: '2.0', id: 1, result: { tools: [] } } }
  let(:server) do
    instance_double(FastMcp::Server,
      logger: Logger.new(nil),
      transport: nil,
      'transport=' => nil,
      contains_filters?: false,
      handle_request: nil)
  end
  let(:logger) { Logger.new(nil) }
  let(:transport) { described_class.new(app, server, logger: logger, localhost_only: false) }

  let(:accept_header) { 'application/json, text/event-stream' }

  def post_env(body, path: '/mcp', accept: accept_header, extra_headers: {})
    env = Rack::MockRequest.env_for(
      path,
      method: 'POST',
      input: body.is_a?(String) ? body : JSON.generate(body),
      'CONTENT_TYPE' => 'application/json',
      'HTTP_ACCEPT' => accept,
      'HTTP_HOST' => 'localhost'
    )
    extra_headers.each { |k, v| env[k] = v }
    env
  end

  def get_env(path: '/mcp')
    Rack::MockRequest.env_for(path, method: 'GET', 'HTTP_HOST' => 'localhost')
  end

  def delete_env(path: '/mcp')
    Rack::MockRequest.env_for(path, method: 'DELETE', 'HTTP_HOST' => 'localhost')
  end

  def options_env(path: '/mcp')
    Rack::MockRequest.env_for(path, method: 'OPTIONS', 'HTTP_HOST' => 'localhost')
  end

  describe '#protocol_version' do
    it 'returns 2025-03-26' do
      expect(transport.protocol_version).to eq('2025-03-26')
    end
  end

  describe '#start / #stop' do
    it 'toggles running state' do
      transport.start
      expect(transport.instance_variable_get(:@running)).to be true
      transport.stop
      expect(transport.instance_variable_get(:@running)).to be false
    end
  end

  describe 'POST requests' do
    before { transport.start }

    context 'initialize request' do
      let(:init_body) { { jsonrpc: '2.0', id: 1, method: 'initialize', params: { capabilities: {} } } }

      it 'returns 200 with Mcp-Session-Id header' do
        allow(server).to receive(:handle_request) do |_body, **_opts|
          transport.send_json_rpc_response(
            { jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-03-26', capabilities: {} } }
          )
        end

        status, headers, body = transport.call(post_env(init_body))

        expect(status).to eq(200)
        expect(headers['Mcp-Session-Id']).to match(/\A[0-9a-f-]{36}\z/)
        expect(headers['Content-Type']).to eq('application/json')
        parsed = JSON.parse(body.first)
        expect(parsed['result']['protocolVersion']).to eq('2025-03-26')
      end
    end

    context 'tools/list request' do
      let(:request_body) { { jsonrpc: '2.0', id: 2, method: 'tools/list' } }

      it 'returns 200 with JSON-RPC response in body' do
        allow(server).to receive(:handle_request) do |_body, **_opts|
          transport.send_json_rpc_response(tools_response)
        end

        status, headers, body = transport.call(post_env(request_body))

        expect(status).to eq(200)
        expect(headers['Content-Type']).to eq('application/json')
        parsed = JSON.parse(body.first)
        expect(parsed['id']).to eq(1)
        expect(parsed['result']).to have_key('tools')
      end
    end

    context 'notification (no id)' do
      let(:notification_body) { { jsonrpc: '2.0', method: 'notifications/initialized' } }

      it 'returns 202 Accepted' do
        allow(server).to receive(:handle_request)

        status, _headers, body = transport.call(post_env(notification_body))

        expect(status).to eq(202)
        expect(body).to eq([])
      end
    end

    context 'missing Accept header' do
      it 'returns 406' do
        body = { jsonrpc: '2.0', id: 1, method: 'tools/list' }
        status, _headers, resp = transport.call(post_env(body, accept: 'application/json'))

        expect(status).to eq(406)
        parsed = JSON.parse(resp.first)
        expect(parsed['error']['code']).to eq(-32_600)
      end
    end

    context 'invalid JSON body' do
      it 'returns 400' do
        status, _headers, resp = transport.call(post_env('not json{'))

        expect(status).to eq(400)
        parsed = JSON.parse(resp.first)
        expect(parsed['error']['code']).to eq(-32_700)
      end
    end
  end

  describe 'GET requests' do
    before { transport.start }

    it 'returns 405 Method Not Allowed' do
      status, _headers, _body = transport.call(get_env)
      expect(status).to eq(405)
    end
  end

  describe 'DELETE requests' do
    before { transport.start }

    it 'returns 200' do
      status, _headers, _body = transport.call(delete_env)
      expect(status).to eq(200)
    end
  end

  describe 'OPTIONS requests' do
    before { transport.start }

    it 'returns 204 with CORS headers' do
      status, headers, _body = transport.call(options_env)

      expect(status).to eq(204)
      expect(headers['Access-Control-Allow-Methods']).to include('POST')
      expect(headers['Access-Control-Allow-Headers']).to include('Mcp-Session-Id')
    end
  end

  describe 'origin validation' do
    let(:restricted_transport) do
      described_class.new(app, server, logger: logger, localhost_only: false,
                                       allowed_origins: ['allowed.example.com'])
    end

    before { restricted_transport.start }

    it 'blocks requests from disallowed origins' do
      env = post_env({ jsonrpc: '2.0', id: 1, method: 'ping' })
      env['HTTP_ORIGIN'] = 'http://evil.example.com'
      env['HTTP_HOST'] = 'evil.example.com'

      status, _headers, _body = restricted_transport.call(env)
      expect(status).to eq(403)
    end

    it 'allows requests from allowed origins' do
      allow(server).to receive(:handle_request) do |_body, **_opts|
        transport.send_json_rpc_response({ jsonrpc: '2.0', id: 1, result: {} })
      end

      env = post_env({ jsonrpc: '2.0', id: 1, method: 'ping' })
      env['HTTP_ORIGIN'] = 'http://allowed.example.com'
      env['HTTP_HOST'] = 'allowed.example.com'

      status, _headers, _body = restricted_transport.call(env)
      expect(status).to eq(200)
    end
  end

  describe 'pass-through' do
    before { transport.start }

    it 'delegates non-MCP paths to the inner app' do
      env = Rack::MockRequest.env_for('/other', method: 'GET', 'HTTP_HOST' => 'localhost')
      status, _headers, body = transport.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['OK'])
    end
  end

  describe '#send_json_rpc_response' do
    it 'stores message in thread-local' do
      msg = { jsonrpc: '2.0', id: 1, result: {} }
      transport.send_json_rpc_response(msg)
      expect(Thread.current[:fast_mcp_streamable_response]).to eq(msg)
    ensure
      Thread.current[:fast_mcp_streamable_response] = nil
    end
  end

  describe 'two concurrent clients' do
    before { transport.start }

    it 'returns correct responses to each client without cross-talk' do
      client_a_body = { jsonrpc: '2.0', id: 10, method: 'tools/list' }
      client_b_body = { jsonrpc: '2.0', id: 20, method: 'tools/list' }

      response_a = { jsonrpc: '2.0', id: 10, result: { tools: [{ name: 'tool_a' }] } }
      response_b = { jsonrpc: '2.0', id: 20, result: { tools: [{ name: 'tool_b' }] } }

      allow(server).to receive(:handle_request) do |body_str, **_opts|
        parsed = JSON.parse(body_str)
        if parsed['id'] == 10
          transport.send_json_rpc_response(response_a)
        else
          transport.send_json_rpc_response(response_b)
        end
      end

      status_a, _, body_a = transport.call(post_env(client_a_body))
      status_b, _, body_b = transport.call(post_env(client_b_body))

      expect(status_a).to eq(200)
      expect(status_b).to eq(200)
      expect(JSON.parse(body_a.first)['id']).to eq(10)
      expect(JSON.parse(body_b.first)['id']).to eq(20)
    end
  end
end
