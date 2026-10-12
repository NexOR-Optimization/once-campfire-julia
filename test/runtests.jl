# Julia backend tests; the Rails suite continues to use bin/rails test.
include("julia_rendering.jl")
include("julia_backend.jl")
include("julia_benchmark.jl")
include("julia_handler_benchmark.jl")

include("julia_web_auth.jl")
include("julia_web_messages.jl")
include("julia_web_views.jl")
include("julia_web_server.jl")
include("julia_web_cable.jl")
include("julia_web_unfurl.jl")
include("julia_web_push.jl")
