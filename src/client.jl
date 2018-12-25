function write_request(channel::gRPCChannel, controller::gRPCController, service::ServiceDescriptor, method::MethodDescriptor, request)
    connection = channel.session
    path = "/" * service.name * "/" * method.name
    headers = Headers(":method" => "POST",
                      ":path" => path,
                      ":scheme" => "http",
                      "content-type" => "application/grpc+proto")

    channel.stream_id = Session.next_free_stream_identifier(connection)
    debug_log(controller, "Stream Id: $(channel.stream_id)")
    Session.put_act!(connection, Session.ActSendHeaders(channel.stream_id, headers, false))
    data_buff = to_delimited_message_bytes(request)
    Session.put_act!(channel.session, Session.ActSendData(channel.stream_id, data_buff, true))

    debug_log(controller, "sent data $(length(data_buff)) bytes")
    nothing
end

function read_response(channel::gRPCChannel, controller::gRPCController, response)
    connection = channel.session

    evt = Session.take_evt!(connection)

    if !isa(evt, EvtRecvHeaders)
        debug_log(controller, "unexpected event $evt")
        close(channel)
        return response
    end

    debug_log(controller, "got stream id: $(evt.stream_identifier)")
    debug_log(controller, "channel stream id: $(channel.stream_id)")

    headers = evt.headers
    debug_log(controller, "received_headers: $headers")
    assert_http_status(headers)
    ret, err = assert_grpc_status(headers)
    # check if we received only trailer headers, then there is no response to send
    (ret == 0) && (return response)

    debug_log(controller, "reading next evt (data/trailer)")
    evt = Session.take_evt!(connection)
    if isa(evt, EvtRecvData)
        data = evt.data
        from_delimited_message_bytes(data, response)
    elseif isa(evt, EvtRecvHeaders) # trailer
        assert_grpc_status(evt.headers)
        return response
    end

    debug_log(controller, "reading next evt (trailer)")
    evt = Session.take_evt!(connection)

    if !isa(evt, EvtRecvHeaders)
        debug_log(controller, "unexpected event $evt")
        close(channel)
        return response
    end

    assert_grpc_status(evt.headers)
    return response
end

function call_method(channel::gRPCChannel, service::ServiceDescriptor, method::MethodDescriptor, controller::gRPCController, request)
    write_request(channel, controller, service, method, request)
    response_type = get_response_type(method)
    response = response_type()
    read_response(channel, controller, response)
end

# gRPC client implementation
# 
mutable struct gRPCClient
    sock::TCPSocket
    channel::gRPCChannel

    gRPCClient(port::Integer) = gRPCClient(ip"127.0.0.1", port)
    function gRPCClient(ip::IPv4, port::Integer)
        buffer = connect(ip, port)
        connection = Session.new_connection(buffer; isclient=true)
        channel = gRPCChannel(connection)
        new(buffer, channel)
    end
end

close(client::gRPCClient) = close(client.channel)
stub(client::gRPCClient, stubfn) = stubfn(client.channel)
