using Test, HTTP, TOML

if !isdefined(@__MODULE__, :BackendBenchmark)
    include(joinpath(@__DIR__, "..", "julia", "bench", "backend.jl"))
end

@testset "SQLite handler benchmark contracts" begin
    B = BackendBenchmark
    mktempdir() do directory
        output = joinpath(directory, "handler.toml")
        report = B.main(["--iterations", "2", "--samples", "2", "--output", output])
        saved = TOML.parsefile(output)
        @test saved == report
        @test report["metadata"]["gc_enabled"]
        @test length(report["results"]) == 8
        for name in ("room", "messages", "sidebar", "search")
            routes = filter(r -> r["route"] == name, report["results"])
            @test Set(r["cache"] for r in routes) == Set(["warm", "disabled"])
            @test routes[1]["body_bytes"] == routes[2]["body_bytes"] > 0
        end
        @test all(r -> r["median_ns_per_op"] > 0, report["results"])
        @test all(r -> r["julia_allocated_bytes_per_op"] >= 0, report["results"])
        @test all(r -> length(r["samples_ns_per_op"]) == 2, report["results"])
    end
    @test_throws ArgumentError B.benchmark(; iterations = 0)
    @test_throws ArgumentError B.benchmark(; samples = 0)
    @test_throws ErrorException B.main(["--unknown"])
    @test_throws ErrorException B.main(["--samples"])
    @test_throws ErrorException B.validate(HTTP.Response(500), "room", Int[])
    @test_throws ErrorException B.validate(HTTP.Response(200, "oops"), "room", Int[])
    bad = HTTP.Response(
        200,
        ["Content-Type" => "text/html; charset=utf-8"],
        "<!DOCTYPE html><html></html>",
    )
    @test_throws ErrorException B.validate(bad, "room", [1])
    @test_throws ErrorException B.validate(bad, "sidebar", Int[])
end
