module gRPC

using ProtoBuf
using HTTP2
using HTTP2.Session

import Base: TCPServer, close, run
import ProtoBuf: call_method
import HTTP2: Headers
import HTTP2.Session: HTTPConnection, EvtGoaway, EvtRecvHeaders, EvtRecvData

include("common.jl")
include("server.jl")
include("client.jl")

export gRPCController
export gRPCClient, close, stub
export gRPCServer, close, run

end # module
