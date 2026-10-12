using Test

if !isdefined(@__MODULE__, :Rendering)
    include(joinpath(@__DIR__, "..", "julia", "src", "Rendering.jl"))
end
using .Rendering

function render_allocations(buffer, plain, escaped, value)
    reset!(buffer)
    append!(buffer, plain)
    escape_html!(buffer, escaped)
    append_integer!(buffer, value)
    return buffer.used
end

function check_render_allocations(plain, escaped, value)
    buffer = Buffer(4096)
    render_allocations(buffer, plain, escaped, value)
    return @allocated render_allocations(buffer, plain, escaped, value)
end

@testset "Julia rendering" begin
    @test_throws ArgumentError Buffer(-1)
    buffer = Buffer(0)
    @test isempty(bytes(buffer))
    @test append!(buffer, "") === buffer
    @test isempty(finish(buffer))

    @test append!(buffer, "λ café 日本語 🐈") === buffer
    @test String(finish(buffer)) == "λ café 日本語 🐈"
    @test append!(buffer, UInt8[0x20, 0x61]) === buffer
    @test String(finish(buffer)) == "λ café 日本語 🐈 a"
    capacity = length(buffer.data)
    retained = finish(buffer)
    @test reset!(buffer) === buffer
    @test buffer.used == 0
    @test length(buffer.data) == capacity
    @test String(retained) == "λ café 日本語 🐈 a"

    @testset "HTML escaping" begin
        cases = (
            "" => "",
            "plain λ café 日本語 🐈" => "plain λ café 日本語 🐈",
            "&<>\"'" => "&amp;&lt;&gt;&quot;&#39;",
            "<b title=\"Tom & Jerry's\">λ</b>" => "&lt;b title=&quot;Tom &amp; Jerry&#39;s&quot;&gt;λ&lt;/b&gt;",
            "a&" => "a&amp;",
            "&a" => "&amp;a",
            "&&" => "&amp;&amp;",
        )
        for (input, expected) in cases
            reset!(buffer)
            append!(buffer, "prefix:")
            @test escape_html!(buffer, input) === buffer
            @test String(finish(buffer)) == "prefix:" * expected
            reset!(buffer)
            escape_html!(buffer, collect(codeunits(input)))
            @test String(finish(buffer)) == expected
        end
        # All other byte values, including UTF-8 continuation bytes, survive.
        input = collect(UInt8(0):UInt8(255))
        expected = replace(
            String(copy(input)),
            "&" => "&amp;",
            "<" => "&lt;",
            ">" => "&gt;",
            "\"" => "&quot;",
            "'" => "&#39;",
        )
        reset!(buffer)
        escape_html!(buffer, input)
        @test finish(buffer) == collect(codeunits(expected))
    end

    @testset "Decimal integers" begin
        for T in (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
            for value in (typemin(T), zero(T), one(T), typemax(T))
                reset!(buffer)
                append!(buffer, "id=")
                @test append_integer!(buffer, value) === buffer
                @test String(finish(buffer)) == "id=" * string(value)
            end
        end
        for value in (-100, -10, -1, 9, 10, 99, 100, 999_999_999)
            reset!(buffer)
            append_integer!(buffer, value)
            @test String(finish(buffer)) == string(value)
        end
    end

    @testset "Ownership and bounds" begin
        reset!(buffer)
        append!(buffer, "abc")
        @test_throws ArgumentError append!(buffer, buffer.data)
        @test_throws ArgumentError append!(buffer, bytes(buffer))
        @test_throws ArgumentError escape_html!(buffer, bytes(buffer))
        @test String(finish(buffer)) == "abc"
        @test_throws OverflowError Rendering.reserve!(buffer, typemax(Int))
        @test String(finish(buffer)) == "abc"
        @test bytes(buffer) == UInt8[0x61, 0x62, 0x63]
    end

    @testset "Preallocated hot paths" begin
        plain = "Room: λ café 日本語 🐈 "
        escaped = "<b title=\"Tom & Jerry's\">hello</b>"
        @test check_render_allocations(plain, escaped, typemin(Int)) == 0
        @test check_render_allocations(plain, plain, typemin(Int128)) == 0
        @test check_render_allocations(
            collect(codeunits(plain)),
            collect(codeunits(escaped)),
            typemax(UInt128),
        ) == 0
        @test check_render_allocations(codeunits(plain), codeunits(escaped), 0) == 0
    end
end
