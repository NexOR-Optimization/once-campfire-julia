module BackendBenchmark

using DBInterface, HTTP, SQLite, Statistics, TOML

include(joinpath(@__DIR__, "..", "src", "Campfire.jl"))
using .Campfire

const ROUTES = (
    ("room", "/rooms/1", collect(81:120)),
    ("messages", "/rooms/1/messages?before=60", collect(20:59)),
    ("sidebar", "/users/me/sidebar", Int[]),
    ("search", "/searches?q=coffee", collect(21:120)),
)

function validate(result, name, expected_ids)
    result.status == 200 || error("$name returned HTTP $(result.status)")
    HTTP.header(result, "Content-Type") == "text/html; charset=utf-8" ||
        error("$name returned the wrong content type")
    body = String(copy(result.body))
    ids = [parse(Int, m[1]) for m in eachmatch(r"data-message-id=\"(\d+)\"", body)]
    ids == expected_ids || error("$name returned the wrong message window")
    if name != "messages"
        startswith(body, "<!DOCTYPE html>") && endswith(body, "</html>") ||
            error("$name returned incomplete HTML")
    end
    if name == "sidebar"
        occursin("shared_rooms", body) &&
        occursin("Watercooler", body) &&
        !occursin("Private", body) || error("incorrect sidebar visibility")
    else
        for id in expected_ids
            occursin("id=\"message_$id\"", body) || error("missing message DOM id")
            occursin("Message $id: coffee, Julia &amp; &lt;friends&gt; — ☕", body) ||
                error("missing or incorrectly escaped message body")
        end
    end
    return copy(result.body)
end

function batch!(store, request, iterations)
    sink = UInt(0)
    for _ in 1:iterations
        result = handle(store, request)
        sink += UInt(result.status) + UInt(length(result.body))
        isempty(result.body) || (sink ⊻= UInt(result.body[end]))
    end
    return sink
end

function benchmark(; iterations::Int = 200, samples::Int = 5)
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    samples > 0 || throw(ArgumentError("samples must be positive"))
    rows = Dict{String,Any}[]
    previous_gc = GC.enable(true)
    try
        mktempdir() do directory
            path = joinpath(directory, "campfire.sqlite3")
            token = seed!(path; messages = 120)
            reference = Dict{String,Vector{UInt8}}()
            for cached in (false, true)
                store = Store(path; cache_budget = cached ? 64 * 1024^2 : 0)
                try
                    for (name, target, expected_ids) in ROUTES
                        # Request construction and response validation stay outside timing.
                        request = HTTP.Request(
                            "GET",
                            target,
                            ["Authorization" => "Bearer $token"],
                        )
                        initial = handle(store, request)
                        body = validate(initial, name, expected_ids)
                        if haskey(reference, name)
                            body == reference[name] || error("cache changed $name body")
                        else
                            reference[name] = body
                        end
                        batch!(store, request, 8)
                        repeated = handle(store, request)
                        (repeated.body === initial.body) == cached ||
                            error("unexpected cache behavior for $name")
                        timings = Float64[]
                        sink = UInt(0)
                        for _ in 1:samples
                            GC.gc()
                            started = time_ns()
                            sink ⊻= batch!(store, request, iterations)
                            push!(timings, (time_ns() - started) / iterations)
                        end
                        allocated = @allocated batch!(store, request, iterations)
                        validate(handle(store, request), name, expected_ids) == body ||
                            error("$name body changed during timing")
                        push!(
                            rows,
                            Dict{String,Any}(
                                "route" => name,
                                "cache" => cached ? "warm" : "disabled",
                                "median_ns_per_op" => median(timings),
                                "samples_ns_per_op" => timings,
                                "julia_allocated_bytes_per_op" => allocated / iterations,
                                "body_bytes" => length(body),
                                "sink" => string(sink),
                            ),
                        )
                    end
                finally
                    close(store)
                end
            end
        end
    finally
        GC.enable(previous_gc)
    end
    return Dict{String,Any}(
        "metadata" => Dict{String,Any}(
            "scope" => "Sequential Julia handler with SQLite authentication, authorization, cache checks and rendering; excludes request construction, TCP, HTTP parsing, gzip and writes. Not full application throughput or a C/Rust comparison.",
            "julia" => string(VERSION),
            "cpu" => Sys.CPU_NAME,
            "architecture" => string(Sys.ARCH),
            "threads" => Threads.nthreads(),
            "http" => string(pkgversion(HTTP)),
            "sqlite" => string(pkgversion(SQLite)),
            "dbinterface" => string(pkgversion(DBInterface)),
            "gc_enabled" => true,
            "iterations" => iterations,
            "samples" => samples,
            "fixture_messages" => 120,
            "allocation_scope" => "Julia-managed allocations only; excludes SQLite/libc allocations.",
        ),
        "results" => rows,
    )
end

function main(args = ARGS)
    iterations, samples = 200, 5
    output = nothing
    index = 1
    while index <= length(args)
        option = args[index]
        option in ("--iterations", "--samples", "--output") ||
            error("unknown option: $option")
        index < length(args) || error("missing value for $option")
        value = args[index+1]
        if option == "--iterations"
            iterations = parse(Int, value)
        elseif option == "--samples"
            samples = parse(Int, value)
        else
            output = value
        end
        index += 2
    end
    report = benchmark(; iterations, samples)
    if isnothing(output)
        TOML.print(stdout, report; sorted = true)
    else
        open(output, "w") do io
            return TOML.print(io, report; sorted = true)
        end
    end
    return report
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    BackendBenchmark.main()
end
