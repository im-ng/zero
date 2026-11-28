# syntax=docker/dockerfile:1
# Multi-stage build for zero-starter. Pin the same Zig version as build.zig.zon.
FROM ziglang/zig:0.17.0 AS build
WORKDIR /src
COPY . .
# Build a release binary; forward the feature flags to match the host build.
RUN zig build -Dkafka=true -Dduckdb=true --release=fast

FROM debian:bookworm-slim AS runtime
# Run as a non-root user; 10001 is the conventional zero app uid.
RUN groupadd -g 10001 zero && useradd -u 10001 -g 10001 -m zero
WORKDIR /app
COPY --from=build /src/zig-out/bin/starter /app/starter
# Config is mounted at runtime; see charts/zero for the env shape.
USER 10001
EXPOSE 8080
ENTRYPOINT ["/app/starter"]
