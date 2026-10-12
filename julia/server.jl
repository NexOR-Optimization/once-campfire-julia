if !isdefined(@__MODULE__, :Campfire)
    using Campfire
end
using .Campfire

function main(args = ARGS)
    args = copy(args)
    prototype = !isempty(args) && args[1] == "--prototype"
    prototype && popfirst!(args)
    isempty(args) && push!(
        args,
        get(ENV, "DATABASE_PATH", joinpath(@__DIR__, "../storage/julia.sqlite3")),
    )
    store =
        prototype ? Store(args[1]) :
        Campfire.Web.WebApp(
            args[1];
            origin = get(ENV, "CAMPFIRE_ORIGIN", ""),
            storage_root = get(
                ENV,
                "STORAGE_PATH",
                joinpath(dirname(abspath(args[1])), "storage"),
            ),
        )
    try
        serve_function = prototype ? serve : Campfire.Web.start_server
        server = serve_function(
            store;
            host = get(ENV, "CAMPFIRE_HOST", "127.0.0.1"),
            port = length(args) > 1 ? parse(Int, args[2]) :
                   parse(Int, get(ENV, "PORT", "3001")),
        )
        try
            wait(server)
        finally
            close(server)
        end
    finally
        close(store)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
