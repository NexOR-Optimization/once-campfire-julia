module Rendering

import Base: append!

export Buffer, reset!, append!, escape_html!, append_integer!, bytes, finish

"""Reusable output storage. Give each concurrent request its own buffer."""
mutable struct Buffer
    data::Vector{UInt8}
    used::Int

    function Buffer(capacity::Integer = 4096)
        capacity >= 0 || throw(ArgumentError("capacity must be nonnegative"))
        return new(Vector{UInt8}(undef, capacity), 0)
    end
end

"""Reuse allocated storage, discarding the previous output."""
@inline function reset!(buffer::Buffer)
    buffer.used = 0
    return buffer
end

"""Borrow the used bytes. Consume them before resetting or growing the buffer."""
@inline bytes(buffer::Buffer) = @view buffer.data[1:buffer.used]

"""Copy the output when it must outlive the next buffer reuse."""
finish(buffer::Buffer) = copy(bytes(buffer))

@noinline function grow!(buffer::Buffer, required::Int)
    capacity = length(buffer.data)
    doubled = capacity <= typemax(Int) ÷ 2 ? 2capacity : required
    resize!(buffer.data, max(required, doubled))
    return nothing
end

@inline function reserve!(buffer::Buffer, additional::Int)
    required = Base.Checked.checked_add(buffer.used, additional)
    if required > length(buffer.data)
        grow!(buffer, required)
    end
    return required
end

@inline function check_source(buffer::Buffer, source::AbstractVector{UInt8})
    Base.require_one_based_indexing(source)
    if Base.mightalias(buffer.data, source)
        throw(ArgumentError("input must not alias the output buffer"))
    end
    return nothing
end

@inline append!(buffer::Buffer, source::String) = append!(buffer, codeunits(source))

"""Append UTF-8 bytes; growing storage is the only allocating path."""
@inline function append!(buffer::Buffer, source::AbstractVector{UInt8})
    check_source(buffer, source)
    required = reserve!(buffer, length(source))
    copyto!(buffer.data, buffer.used + 1, source, 1, length(source))
    buffer.used = required
    return buffer
end

@inline function escape_extra(byte::UInt8)
    return byte == UInt8('&') ? 4 :
           byte == UInt8('<') || byte == UInt8('>') ? 3 :
           byte == UInt8('"') ? 5 : byte == UInt8('\'') ? 4 : 0
end

@inline function needs_escape(byte::UInt8)
    # Each ASCII pair differs in one bit: &/apostrophe and </>.
    # Three branchless comparisons keep the reduction vectorizable.
    return ((byte & 0xfe) == UInt8('&')) | ((byte & 0xfd) == UInt8('<')) |
           (byte == UInt8('"'))
end

# Keep the reduction separate so LLVM can vectorize it before the writer.
@noinline function contains_special(source::AbstractVector{UInt8})
    found = false
    @inbounds @simd for i in eachindex(source)
        found |= needs_escape(source[i])
    end
    return found
end

const AMP = Tuple(codeunits("&amp;"))
const LT = Tuple(codeunits("&lt;"))
const GT = Tuple(codeunits("&gt;"))
const QUOT = Tuple(codeunits("&quot;"))
const APOS = Tuple(codeunits("&#39;"))

# Tuple lengths let the compiler inline each entity as a few fixed-size stores.
@inline function write_entity!(
    data::Vector{UInt8},
    output::Int,
    entity::NTuple{N,UInt8},
) where {N}
    @inbounds for byte in entity
        output += 1
        data[output] = byte
    end
    return output
end

@inline escape_html!(buffer::Buffer, source::String) =
    escape_html!(buffer, codeunits(source))

@noinline function reserve_escaped!(buffer::Buffer, source::AbstractVector{UInt8})
    extra = 0
    @inbounds @simd for i in eachindex(source)
        extra += escape_extra(source[i])
    end
    reserve!(buffer, length(source) + extra)
    return nothing
end

"""Escape HTML metacharacters without decoding or changing other UTF-8 bytes."""
function escape_html!(buffer::Buffer, source::AbstractVector{UInt8})
    check_source(buffer, source)
    # At most six output bytes per input byte; this bounds all size arithmetic.
    length(source) <= typemax(Int) ÷ 6 || throw(OverflowError("input is too large"))
    if !contains_special(source)
        return append!(buffer, source)
    end

    # Only count the exact expansion when the existing capacity could be tight.
    if 6length(source) > length(buffer.data) - buffer.used
        reserve_escaped!(buffer, source)
    end
    output = buffer.used
    data = buffer.data
    @inbounds for byte in source
        if byte == UInt8('&')
            output = write_entity!(data, output, AMP)
        elseif byte == UInt8('<')
            output = write_entity!(data, output, LT)
        elseif byte == UInt8('>')
            output = write_entity!(data, output, GT)
        elseif byte == UInt8('"')
            output = write_entity!(data, output, QUOT)
        elseif byte == UInt8('\'')
            output = write_entity!(data, output, APOS)
        else
            output += 1
            data[output] = byte
        end
    end
    buffer.used = output
    return buffer
end

"""Append a fixed-width integer in decimal, including the minimum signed value."""
function append_integer!(buffer::Buffer, value::Base.BitInteger)
    negative = value < 0
    # Unsigned arithmetic handles abs(typemin(T)) without signed overflow.
    magnitude = negative ? -unsigned(value) : unsigned(value)
    digits = 1
    remaining = magnitude
    while remaining >= 10
        remaining ÷= 10
        digits += 1
    end
    required = reserve!(buffer, digits + negative)
    @inbounds if negative
        buffer.data[buffer.used+1] = UInt8('-')
    end
    output = required
    @inbounds for _ in 1:digits
        buffer.data[output] = UInt8('0') + UInt8(rem(magnitude, 10))
        magnitude ÷= 10
        output -= 1
    end
    buffer.used = required
    return buffer
end

end
