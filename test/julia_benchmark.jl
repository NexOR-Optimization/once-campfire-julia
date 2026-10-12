using Test
using Libdl

if !isdefined(@__MODULE__, :RenderBenchmark)
    include(joinpath(@__DIR__, "..", "julia", "bench", "render.jl"))
end

@testset "Identical Julia/C/Rust benchmark outputs" begin
    B = RenderBenchmark
    R = B.Rendering
    # Check against an independent reference, not merely the other implementations.
    reference(s) = replace(
        s,
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
    )
    mktempdir() do directory
        libraries = B.build_native(directory)
        try
            for source in
                ("", "ascii", "Héllo λ世界🚀", "<&>\"'", repeat("<&>\"'λ世界🚀 ", 19))
                input = collect(codeunits(source))
                expected = collect(codeunits(reference(source)))
                out = R.Buffer(max(1, 6length(input)))
                B.scalar_escape!(out, input)
                @test R.bytes(out) == expected
                for library in libraries
                    fill!(out.data, 0xa5)
                    B.native_escape!(out, input, library)
                    @test R.bytes(out) == expected
                    @test all(==(0xa5), @view out.data[(out.used+1):end])
                end
            end
            for f in (
                B.fixture(:mixed; count = 0),
                B.Fixture([0, typemax(UInt64)], ["", "A<&'\""], ["λ世界🚀", "<&>\"'"]),
            )
                out = R.Buffer(B.capacity(f))
                B.render!(out, f)
                expected = R.finish(out)
                for library in libraries
                    fill!(out.data, 0xa5)
                    B.native_render!(out, f, library)
                    @test R.bytes(out) == expected
                    @test all(==(0xa5), @view out.data[(out.used+1):end])
                end
            end
            for kind in (:plain, :mixed, :dense)
                f = B.fixture(kind)
                expected = join(
                    "<article id=\"message_$(f.ids[i])\"><header>$(reference(String(copy(f.users[i]))))</header><p>$(reference(String(copy(f.bodies[i]))))</p></article>\n"
                    for i in eachindex(f.ids)
                )
                out = R.Buffer(B.capacity(f))
                for escape! in (B.scalar_escape!, R.escape_html!)
                    B.render!(out, f, escape!)
                    @test String(R.finish(out)) == expected
                end
                for library in libraries
                    B.native_render!(out, f, library)
                    @test String(R.finish(out)) == expected
                end
                for workload in (:escape, :render)
                    results =
                        B.compare_case(f, libraries, workload; iterations = 4, samples = 3)
                    @test length(results) == 2 + length(libraries)
                    @test all(r -> r["allocated_bytes"] == 0, results)
                    @test all(r -> length(r["samples_ns"]) == 3, results)
                end
            end
            @test_throws ArgumentError B.fixture(:unknown)
            @test_throws DimensionMismatch B.Fixture([1], String[], String[])
            @test_throws ArgumentError B.benchmark(; iterations = 0)
            @test_throws ErrorException B.main(["--unknown"])
            @test_throws ErrorException B.main(["--samples"])
        finally
            foreach(library -> Libdl.dlclose(library.handle), libraries)
        end
    end
end
