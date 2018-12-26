# gRPCController only a placeholder as of now
struct gRPCController <: ProtoRpcController
end

# gRPCChannel implementation
mutable struct gRPCChannel <: ProtoRpcChannel
    session::HTTPConnection
    stream_id::UInt32

    gRPCChannel(session::HTTPConnection) = new(session, 0)
end
close(channel::gRPCChannel) = close(channel.session)

function to_delimited_message_bytes(msg)
    iob = IOBuffer()
    write(iob, UInt8(0))
    write(iob, hton(UInt32(0)))
    data_len = writeproto(iob, msg)
    seek(iob, 1)
    write(iob, hton(UInt32(data_len)))
    take!(iob)
end

function from_delimited_message_bytes(data, t)
    iob = IOBuffer(data)
    compressed = read(iob, UInt8)
    datalen = ntoh(read(iob, UInt32))
    readproto(iob, t)
end

function check_grpc_status(headers)
    ("grpc-status" in keys(headers)) || (return (1, ""))

    grpc_status = parse(Int, headers["grpc-status"])
    (grpc_status == 0) && (return (0, ""))

    grpc_message = get(headers, "grpc-message", "unexpected grpc status: $grpc_status")
    (-1, grpc_message)
end

function check_http_status(headers)
    (":status" in keys(headers)) || (return (1, ""))
    status = parse(Int, headers[":status"])
    (status == 200) && (return (0, ""))
    (-1, "unexpected http status: $status")
end

assert_status(status) = (status[1] == -1) ? error(status[2]) : status
assert_http_status(headers) = assert_status(check_http_status(headers))
assert_grpc_status(headers) = assert_status(check_grpc_status(headers))
