function read_request(channel::gRPCChannel, controller::gRPCController, services)
    connection = channel.session
    evt = Session.take_evt!(connection)

    if isa(evt, EvtGoaway)
        @debug("received EvtGoaway")
        close(channel)
        return (nothing, nothing, nothing)
    end

    if !isa(evt, EvtRecvHeaders)
        @debug("unexpected event while reading request (closing channel)", evt)
        close(channel)
        return (nothing, nothing, nothing)
    end

    channel.stream_id = evt.stream_identifier

    headers = evt.headers
    method = headers[":method"]
    path = headers[":path"]
    pathcomps = split(path, "/"; keep=false)
    if length(pathcomps) != 2
        @debug("unexpected path while reading request (closing channel)", path)
        close(channel)
        return (nothing, nothing, nothing)
    end

    servicename, methodname = split(path, "/"; keep=false)

    if evt.is_end_stream
        data = UInt8[]
    else
        data_evt = Session.take_evt!(connection)
        data = data_evt.data
    end

    @debug("received request", method, path, stream_id=channel.stream_id, servicename,
           methodname, nbytes=length(data))

    service = services[servicename]
    method = find_method(service, methodname)
    request_type = get_request_type(service, method)
    request = request_type()
    from_delimited_message_bytes(data, request)

    service, method, request
end

function write_response(channel::gRPCChannel, controller::gRPCController, response)
    sending_headers = [(":status", "200")]
    data_buff = to_delimited_message_bytes(response)

    Session.put_act!(channel.session,
                     Session.ActSendHeaders(channel.stream_id, sending_headers, false))
    Session.put_act!(channel.session,
                     Session.ActSendData(channel.stream_id, data_buff, true))
    nothing
end

function call_method(channel::gRPCChannel,
                     service::ServiceDescriptor,
                     method::MethodDescriptor,
                     controller::gRPCController,
                     request)
    write_request(channel, controller, service, method, request)
    response_type = get_response_type(method)
    response = response_type()
    read_response(channel, controller, response)
end


# gRPC server implementation
# 
mutable struct gRPCServer
    sock::TCPServer
    services::Dict{String, ProtoService}
    run::Bool

    gRPCServer(services::Tuple{ProtoService}, ip::IPv4, port::Integer) =
        gRPCServer(services, listen(ip, port))
    gRPCServer(services::Tuple{ProtoService}, port::Integer) =
        gRPCServer(services, listen(port))
    function gRPCServer(services::Tuple{ProtoService}, sock::TCPServer)
        svcdict = Dict{String,ProtoService}()
        for svc in services
            svcdict[svc.desc.name] = svc
        end
        new(sock, svcdict, true)
    end
end

# TODO: close all channels, wait for/interrupt processors
close(srvr::gRPCServer) = close(srvr.sock)

function process(controller::gRPCController, srvr::gRPCServer, channel::gRPCChannel)
    @info("start processing channel")
    try
        while(!channel.session.closed)
            service, method, request = read_request(channel, controller, srvr.services)
            (service === nothing) && continue

            response = call_method(service, method, controller, request)
            #@debug("response from method", response)
            write_response(channel, controller, response)
        end
    catch ex
        @warn("channel stopped with exception", ex)
    end
    # TODO: close channel if not closed, remove reference from srvr
    @info("stopped processing channel")
end

function run(srvr::gRPCServer)
    controller = gRPCController()
    try
        while(srvr.run)
            buffer = accept(srvr.sock)
            connection = Session.new_connection(buffer; isclient=false)

            # TODO: keep channel reference in server
            channel = gRPCChannel(connection)
            @async process(controller, srvr, channel)
        end
    catch ex
        @warn("server stopped with exception", ex)
    end
    @info("stopped server")
end
