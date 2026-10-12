module RenderBenchmark

using Libdl
using Printf
using Statistics
using TOML

include(joinpath(@__DIR__, "..", "src", "Rendering.jl"))
using .Rendering

const C_FLAGS = ["-O3", "-march=native", "-std=c11", "-shared", "-fPIC"]
const RUST_FLAGS = [
    "--edition=2021",
    "--crate-type=cdylib",
    "-C",
    "opt-level=3",
    "-C",
    "target-cpu=native",
    "-C",
    "panic=abort",
]

# A simple byte-by-byte baseline. Capacity is checked once, before the hot loop.
function scalar_escape!(out::Buffer, input::AbstractVector{UInt8})
    required = out.used + 6length(input)
    length(out.data) < required && resize!(out.data, required)
    position = out.used
    @inbounds for c in input
        entity = if c == UInt8('&')
            "&amp;"
        elseif c == UInt8('<')
            "&lt;"
        elseif c == UInt8('>')
            "&gt;"
        elseif c == UInt8('"')
            "&quot;"
        elseif c == UInt8('\'')
            "&#39;"
        else
            ""
        end
        if isempty(entity)
            position += 1
            out.data[position] = c
        else
            for byte in codeunits(entity)
                position += 1
                out.data[position] = byte
            end
        end
    end
    out.used = position
    return out
end

struct Fixture
    ids::Vector{UInt64}
    users::Vector{Vector{UInt8}}
    bodies::Vector{Vector{UInt8}}
    user_pointers::Vector{Ptr{UInt8}}
    body_pointers::Vector{Ptr{UInt8}}
    user_lengths::Vector{Csize_t}
    body_lengths::Vector{Csize_t}
end

function Fixture(ids, users, bodies)
    length(ids) == length(users) == length(bodies) || throw(DimensionMismatch())
    user_bytes = [collect(codeunits(s)) for s in users]
    body_bytes = [collect(codeunits(s)) for s in bodies]
    return Fixture(
        UInt64.(ids),
        user_bytes,
        body_bytes,
        pointer.(user_bytes),
        pointer.(body_bytes),
        Csize_t.(length.(user_bytes)),
        Csize_t.(length.(body_bytes)),
    )
end

function fixture(kind::Symbol; count = 40)
    # All languages receive these same runtime buffers, including multibyte UTF-8.
    text = if kind == :plain
        "Julia makes clear code possible. Héllo, 世界 🚀. "
    elseif kind == :mixed
        "Héllo, 世界 🚀. <strong>Julia & friends</strong> say \"it's ready\". "
    elseif kind == :dense
        "<&>\"'<&>\"' λ世界🚀 "
    else
        throw(ArgumentError("unknown fixture: $kind"))
    end
    return Fixture(
        1001:(1000+count),
        [iseven(i) ? "Zoë & 李" : "Renée" for i in 1:count],
        [repeat(text, 6) * string(i) for i in 1:count],
    )
end

function capacity(f::Fixture)
    return sum(length, f.users; init = 0) * 6 +
           sum(length, f.bodies; init = 0) * 6 +
           100length(f.ids)
end

function render!(out::Buffer, f::Fixture, escape!::F = escape_html!) where {F}
    reset!(out)
    @inbounds for i in eachindex(f.ids)
        append!(out, "<article id=\"message_")
        append_integer!(out, f.ids[i])
        append!(out, "\"><header>")
        escape!(out, f.users[i])
        append!(out, "</header><p>")
        escape!(out, f.bodies[i])
        append!(out, "</p></article>\n")
    end
    return out.used
end

struct NativeLibrary
    name::String
    handle::Ptr{Cvoid}
    escape::Ptr{Cvoid}
    render::Ptr{Cvoid}
end

function build_native(directory; cc = get(ENV, "CC", "cc"), rustc = "rustc")
    libraries = NativeLibrary[]
    for (name, compiler, flags, source) in
        (("C", cc, C_FLAGS, "render.c"), ("Rust", rustc, RUST_FLAGS, "render.rs"))
        Sys.which(compiler) === nothing && continue
        destination = joinpath(directory, "render_$(lowercase(name)).$(Libdl.dlext)")
        run(Cmd([compiler; flags; joinpath(@__DIR__, source); "-o"; destination]))
        handle = Libdl.dlopen(destination)
        push!(
            libraries,
            NativeLibrary(
                name,
                handle,
                Libdl.dlsym(handle, :campfire_escape),
                Libdl.dlsym(handle, :campfire_render),
            ),
        )
    end
    return libraries
end

function native_escape!(out::Buffer, input::Vector{UInt8}, library::NativeLibrary)
    length(out.data) >= 6length(input) || throw(ArgumentError("insufficient capacity"))
    out.used = ccall(
        library.escape,
        Csize_t,
        (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
        out.data,
        input,
        length(input),
    )
    return out.used
end

function native_render!(out::Buffer, f::Fixture, library::NativeLibrary)
    # The pointer arrays do not own the strings, so keep their owner live for C/Rust.
    GC.@preserve f begin
        out.used = ccall(
            library.render,
            Csize_t,
            (
                Ptr{UInt8},
                Ptr{UInt64},
                Ptr{Ptr{UInt8}},
                Ptr{Csize_t},
                Ptr{Ptr{UInt8}},
                Ptr{Csize_t},
                Csize_t,
            ),
            out.data,
            f.ids,
            f.user_pointers,
            f.user_lengths,
            f.body_pointers,
            f.body_lengths,
            length(f.ids),
        )
    end
    return out.used
end

function batch(kernel::F, out::Buffer, iterations::Int) where {F}
    checksum = UInt64(0)
    @inbounds for i in 1:iterations
        n = kernel()
        checksum += UInt64(n)
        n > 0 && (checksum += out.data[1+rem(i, n)])
    end
    return checksum
end

function measure(kernel::F, out, iterations) where {F}
    start = time_ns()
    checksum = batch(kernel, out, iterations)
    elapsed = time_ns() - start
    return elapsed / iterations, checksum
end

function measure_allocations(kernel::F, out, iterations) where {F}
    batch(kernel, out, iterations)
    return (@allocated batch(kernel, out, iterations)) / iterations
end

function kernels(f, libraries, workload)
    input = reduce(vcat, f.bodies)
    result = []
    for (name, escape!) in
        (("Julia scalar", scalar_escape!), ("Julia SIMD scan", escape_html!))
        out = Buffer(capacity(f))
        kernel = if workload == :escape
            () -> begin
                reset!(out)
                escape!(out, input)
                out.used
            end
        else
            () -> render!(out, f, escape!)
        end
        push!(result, (name, kernel, out))
    end
    for library in libraries
        out = Buffer(capacity(f))
        kernel =
            workload == :escape ? () -> native_escape!(out, input, library) :
            () -> native_render!(out, f, library)
        push!(result, (library.name, kernel, out))
    end
    return result
end

function compare_case(f, libraries, workload; iterations, samples)
    implementations = kernels(f, libraries, workload)
    first_kernel, first_output = implementations[1][2:3]
    first_kernel()
    expected = finish(first_output)
    elapsed = [Float64[] for _ in implementations]
    checksums = [UInt64[] for _ in implementations]
    for (_, kernel, out) in implementations
        kernel()
        bytes(out) == expected || error("implementations produced different output")
        batch(kernel, out, 100)
    end
    # Rotate the execution order to distribute thermal and scheduler effects.
    for sample in 1:samples
        for offset in eachindex(implementations)
            index = mod1(sample + offset, length(implementations))
            _, kernel, out = implementations[index]
            nanoseconds, checksum = measure(kernel, out, iterations)
            push!(elapsed[index], nanoseconds)
            push!(checksums[index], checksum)
        end
    end
    all(==(checksums[1]), checksums) || error("benchmark checksums differ")
    return [
        Dict(
            "implementation" => name,
            "median_ns" => median(elapsed[i]),
            "minimum_ns" => minimum(elapsed[i]),
            "samples_ns" => elapsed[i],
            "allocated_bytes" => measure_allocations(kernel, out, iterations),
            "output_bytes" => length(expected),
            "checksum" => string(checksums[i][1]),
        ) for (i, (name, kernel, out)) in enumerate(implementations)
    ]
end

function compiler_version(compiler)
    Sys.which(compiler) === nothing && return "unavailable"
    return first(split(read(`$compiler --version`, String), '\n'))
end

function cpu_affinity()
    Sys.islinux() || return "unavailable"
    for line in eachline("/proc/self/status")
        startswith(line, "Cpus_allowed_list:") && return strip(split(line, ':')[2])
    end
    return "unavailable"
end

function benchmark(; iterations = 2000, samples = 7, output = nothing)
    iterations > 0 && samples > 0 ||
        throw(ArgumentError("positive iterations/samples required"))
    cc = get(ENV, "CC", "cc")
    report = Dict{String,Any}(
        "scope" => "Preallocated HTML escaping and simplified 40-message HTML rendering; not an application benchmark",
        "julia_version" => string(VERSION),
        "cpu" => Sys.cpu_info()[1].model,
        "julia_cpu_target" => Sys.CPU_NAME,
        "julia_optimization_level" => Int(Base.JLOptions().opt_level),
        "cpu_affinity" => cpu_affinity(),
        "machine" => Sys.MACHINE,
        "julia_threads" => Threads.nthreads(),
        "gc_enabled" => true,
        "allocation_metric" => "Julia @allocated after warmup; native source contains no heap allocation",
        "c_compiler" => compiler_version(cc),
        "rust_compiler" => compiler_version("rustc"),
        "c_flags" => C_FLAGS,
        "rust_flags" => RUST_FLAGS,
        "iterations" => iterations,
        "samples" => samples,
        "cases" => Dict{String,Any}(),
    )
    # Keep GC enabled: zero-allocation claims should survive normal execution.
    GC.enable(true)
    mktempdir() do directory
        libraries = build_native(directory; cc)
        try
            for kind in (:plain, :mixed, :dense), workload in (:escape, :render)
                name = "$(workload)_$(kind)"
                results =
                    compare_case(fixture(kind), libraries, workload; iterations, samples)
                report["cases"][name] = results
                println(name)
                for result in results
                    @printf(
                        "  %-18s %10.1f ns/op %8.1f B/op\n",
                        result["implementation"],
                        result["median_ns"],
                        result["allocated_bytes"],
                    )
                end
            end
        finally
            foreach(library -> Libdl.dlclose(library.handle), libraries)
        end
    end
    println(
        "CPU: ",
        report["cpu"],
        "; affinity ",
        report["cpu_affinity"],
        "; Julia ",
        VERSION,
    )
    println(report["c_compiler"], " ", join(C_FLAGS, ' '))
    println(report["rust_compiler"], " ", join(RUST_FLAGS, ' '))
    if output !== nothing
        open(output, "w") do io
            return TOML.print(io, report; sorted = true)
        end
        println("Saved ", output)
    end
    return report
end

function main(args = ARGS)
    options = Dict{Symbol,Any}()
    i = 1
    while i <= length(args)
        flag = args[i]
        flag in ("--iterations", "--samples", "--output") || error("unknown flag: $flag")
        i < length(args) || error("missing value for $flag")
        options[Symbol(flag[3:end])] =
            flag == "--output" ? args[i+1] : parse(Int, args[i+1])
        i += 2
    end
    return benchmark(; options...)
end

end # module RenderBenchmark

if abspath(PROGRAM_FILE) == @__FILE__
    RenderBenchmark.main()
end
