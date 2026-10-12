# syntax=docker/dockerfile:1
# Build from the repository root: docker build -f julia/Dockerfile -t campfire-julia .
ARG JULIA_VERSION=1.13.1
FROM julia:${JULIA_VERSION}-bookworm

WORKDIR /app
ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_NUM_THREADS=auto \
    STORAGE_PATH=/data/storage \
    DATABASE_PATH=/data/production.sqlite3 \
    PORT=3000 \
    CAMPFIRE_HOST=0.0.0.0

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y \
      ca-certificates curl ffmpeg libcrypt1 libqrencode4 libssl3 libxml2 libvips-tools \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 campfire \
    && useradd --system --uid 1000 --gid campfire --create-home campfire \
    && mkdir -p /data/storage /opt/julia-depot \
    && chown -R campfire:campfire /data /opt/julia-depot

COPY julia/Project.toml julia/Manifest.toml /app/julia/
RUN julia --startup-file=no --project=/app/julia -e 'using Pkg; Pkg.instantiate(; allow_autoprecomp=false)'

COPY julia/ /app/julia/
COPY app/javascript/ /app/app/javascript/
COPY app/assets/ /app/app/assets/
COPY app/views/pwa/ /app/app/views/pwa/
COPY vendor/javascript/ /app/vendor/javascript/
RUN chmod +x /app/julia/bin/campfire \
    && julia --startup-file=no --project=/app/julia -e 'using Campfire' \
    && chown -R campfire:campfire /opt/julia-depot

USER campfire
VOLUME ["/data"]
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:3000/up || exit 1
ENTRYPOINT ["/app/julia/bin/campfire"]
