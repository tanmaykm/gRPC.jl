function write_request(channel::gRPCChannel,
                       controller::gRPCController,
                       service::ServiceDescriptor,
                       method::MethodDescriptor,
                       request)
    connection = channel.session
    path = "/" * service.name * "/" * method.name
    headers = [(":method", "POST"),
               (":path", path),
               (":scheme", "http"),
               ("content-type", "application/grpc+proto")]

    channel.stream_id = Session.next_free_stream_identifier(connection)
    @debug("writing request", stream_id=channel.stream_id)
    Session.put_act!(connection, Session.ActSendHeaders(channel.stream_id, headers, false))
    data_buff = to_delimited_message_bytes(request)
    Session.put_act!(channel.session, Session.ActSendData(channel.stream_id, data_buff, true))

    @debug("wrote request", stream_id=channel.stream_id, nbytes=length(data_buff))
    nothing
end

function read_response(channel::gRPCChannel, controller::gRPCController, response)
    connection = channel.session

    evt = Session.take_evt!(connection)

    if !isa(evt, EvtRecvHeaders)
        @warn("unexpected event while reading response (closing channel)", evt)
        close(channel)
        return response
    end

    @debug("read response",
           event_stream_id=evt.stream_identifier,
           channel_stream_id=channel.stream_id)

    headers = evt.headers
    @debug("read response", headers)
    assert_http_status(headers)
    ret, err = assert_grpc_status(headers)
    # check if we received only trailer headers, then there is no response to send
    (ret == 0) && (return response)

    @debug("reading next evt (data/trailer)")
    evt = Session.take_evt!(connection)
    if isa(evt, EvtRecvData)
        data = evt.data
        from_delimited_message_bytes(data, response)
    elseif isa(evt, EvtRecvHeaders) # trailer
        assert_grpc_status(evt.headers)
        return response
    end

    @debug("reading next evt (trailer)")
    evt = Session.take_evt!(connection)

    if !isa(evt, EvtRecvHeaders)
        @warn("unexpected event while reading response (closing channel)", evt)
        close(channel)
        return response
    end

    assert_grpc_status(evt.headers)
    return response
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

# Constructor with the address as a String
function gRPCClient(ip::String, port::Integer)
    ip_adress = parse(IPAddr,ip)
    gRPCClient(ip_adress,port)
end

Base.print(io::IO, client::gRPCClient) = Base.print(io,"gRPCClient($(client.sock))")
Base.show(io::IO, client::gRPCClient) = Base.print(io, client)

close(client::gRPCClient) = close(client.channel)
stub(client::gRPCClient, stubfn) = stubfn(client.channel)
