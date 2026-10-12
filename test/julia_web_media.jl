using Test, SQLite

if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end

@testset "Concurrent media generation and deletion" begin
    W = Campfire.Web
    mktempdir() do directory
        app = W.WebApp(joinpath(directory, "campfire.sqlite3"); secret = repeat("m", 64))
        try
            destination = joinpath(directory, "atomic.webp")
            started, resume = Channel{Nothing}(1), Channel{Nothing}(1)
            rendering = Threads.@spawn W.render_variant(destination) do temporary
                write(temporary, "partial")
                put!(started, nothing)
                take!(resume)
                return write(temporary, "complete")
            end
            take!(started)
            try
                @test !isfile(destination)
            finally
                put!(resume, nothing)
            end
            @test fetch(rendering) == destination
            @test read(destination, String) == "complete"
            @test_throws ErrorException W.render_variant(destination) do temporary
                write(temporary, "failed replacement")
                error("encoder failed")
            end
            @test read(destination, String) == "complete"
            @test !any(startswith(".variant-"), readdir(directory))

            upload = W.UploadedFile(
                "moon.jpg",
                "image/jpeg",
                read(joinpath(@__DIR__, "fixtures/files/moon.jpg")),
            )
            blob = W.attach_upload!(app, "User", 1, "avatar", upload)
            source = W.blob_path(app, blob.key)
            # All callers share the storage lock, including separate DB readers.
            readers = [
                (storage_root = app.storage_root, storage_lock = app.storage_lock) for
                _ = 1:8
            ]
            previews =
                [Threads.@spawn W.attachment_preview(reader, blob) for reader in readers]
            paths = fetch.(previews)
            @test all(==(source * "-thumbnail.webp"), paths)
            thumbnail = read(first(paths))
            @test W.bitmap_file(first(paths))
            @test all(path -> read(path) == thumbnail, paths)
            @test !any(startswith(".variant-"), readdir(dirname(source)))

            avatar, avatar_type = W.avatar_variant(app, blob)
            @test avatar_type == "image/webp"
            @test !isempty(avatar)
            logo, logo_type = W.avatar_variant(app, blob; logo = true)
            @test logo_type == "image/png"
            @test !isempty(logo)
            @test W.read_blob(app, blob) == upload.data

            # A still-referenced blob cannot be removed by a stale cleanup job.
            W.purge_storage!(app, [blob.key])
            @test isfile(source)
            keys = W.detach_attachments!(app, "User", 1; name = "avatar")
            @test keys == [blob.key]
            deleting = nothing
            lock(app.storage_lock) do
                started = Channel{Nothing}(1)
                deleting = Threads.@spawn begin
                    put!(started, nothing)
                    W.purge_storage!(app, keys)
                end
                take!(started)
                @test !istaskdone(deleting)
                @test isfile(source)
                @test isfile(first(paths))
            end
            wait(deleting)
            @test !isfile(source)
            @test !isfile(first(paths))
            @test !isfile(source * "-avatar.webp")
            @test !isfile(source * "-logo.png")
            @test W.attachment_preview(app, blob) === nothing

            # The process initializes libxml before any parallel HTML parsing.
            parsed = [
                Threads.@spawn W.sanitize_rich_text("<p>Reader $i &amp; Julia</p>") for
                i = 1:8
            ]
            @test fetch.(parsed) ==
                  [("<p>Reader $i &amp; Julia</p>", "Reader $i & Julia") for i = 1:8]
        finally
            close(app)
        end
    end
end
