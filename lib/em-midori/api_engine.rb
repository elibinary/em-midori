class Midori::APIEngine
  attr_accessor :routes
  def initialize(root_api, type = :sinatra)
    @routes = {
      GET: [],
      POST: [],
      PUT: [],
      DELETE: [],
      OPTIONS: [],
      LINK: [],
      UNLINK: [],
      WEBSOCKET: [],
      EVENTSOURCE: []
    }
    @root_api = root_api
    @type = type
    @routes = merge('', root_api, [])
    @routes.delete :MOUNT
    @routes.each do |method|
      method[1].each do |route|
        route.path = Mustermann.new(route.path, type: type)
      end
    end
  end

  def merge(prefix, root_api, middlewares)
    # Merge all routes with a Depth-first search
    root_api.routes[:MOUNT].each do |mount|
      root_api.routes.merge!(merge(mount[0], mount[1], root_api.scope_middlewares)) do |_key, old_val, new_val|
        old_val + new_val
      end
    end
    root_api.routes.delete :MOUNT
    root_api.routes.each do |method|
      method[1].each do |route|
        route.path = prefix + route.path
        route.middlewares = middlewares + route.middlewares
      end
    end
    root_api.routes
  end

  # Process after receive data from client
  # @param request [ Midori::Request ] Http Raw Request
  # @param connection [ EM::Connection ] A connection created by EventMachine
  # @return [ Midori::Response ] Http Response
  # @raise [ Midori::Error::NotFound ] If no route matched
  def receive(request, connection = nil)
    @routes[request.method].each do |route|
      params = route.path.params(request.path)
      next unless params
      request.params = params
      route.middlewares.each { |middleware| request = middleware.before(request) }
      clean_room = Midori::CleanRoom.new(request)
      if request.websocket?
        # Send 101 Switching Protocol
        connection.send_data Midori::Response.new(101, Midori::APIEngine.websocket_header(request.header['Sec-WebSocket-Key']), '')
        connection.websocket.request = request
        -> { clean_room.instance_exec(connection.websocket, &route.function) }.call
        return Midori::Response.new
      elsif request.eventsource?
        connection.send_data Midori::Response.new(200, Midori::Const::EVENTSOURCE_HEADER, '')
        -> { clean_room.instance_exec(connection.eventsource, &route.function) }.call
        return Midori::Response.new
      else
        result = -> { clean_room.instance_exec(&route.function) }.call
        clean_room.body = result if result.is_a?String
        response = clean_room.raw_response
        route.middlewares.reverse_each { |middleware| response = middleware.after(request, response) }
        return response
      end
    end
    raise Midori::Error::NotFound
  end

  # Return websocket header with given key
  # @param [String] key 'Sec-WebSocket-Key' in request header
  # @return [Hash] header
  def self.websocket_header(key)
    header = Midori::Const::WEBSOCKET_HEADER.clone
    header['Sec-WebSocket-Accept'] = Digest::SHA1.base64digest(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    header
  end
end
