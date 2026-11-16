# Image for github CI pipeline
# Bump zig versions when needed and publish
# docker build -f Dockerfiles/alpine.Dockerfile -t docker.io/imng/zero-kcov:0.3.6 .
# docker push imng/zero-kcov:0.3.6
FROM alpine:latest AS builder

LABEL maintainer="im-ng"
LABEL description="Multi-version Zig CI container with kcov coverage support"

WORKDIR /root

# Install base dependencies for kcov build
RUN apk add --no-cache \
    git \
    bash \
    wget \
    ca-certificates \
    cmake \
    make \
    gcc \
    g++ \
    musl-dev \
    build-base cmake ninja python3 \
    binutils-dev curl-dev elfutils-dev

# Create working directories
RUN mkdir -p /opt/zig-0.15.1 /opt/zig-0.15.2 /opt/zig-0.16.0 /opt/kcov /opt/libduckdb
RUN mkdir -p /opt/zig-0.17.0

# Install Zig 0.15.1
# RUN wget -q https://ziglang.org/download/0.15.1/zig-x86_64-linux-0.15.1.tar.xz \
#     && tar -xJf zig-x86_64-linux-0.15.1.tar.xz -C /opt/zig-0.15.1 --strip-components=1 \
#     && rm zig-x86_64-linux-0.15.1.tar.xz

# Install Zig 0.15.2
# RUN wget -q https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
#     && tar -xJf zig-x86_64-linux-0.15.2.tar.xz -C /opt/zig-0.15.2 --strip-components=1 \
#     && rm zig-x86_64-linux-0.15.2.tar.xz

# Install Zig 0.16.0
# RUN wget -q https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
#     && tar -xJf zig-x86_64-linux-0.16.0.tar.xz -C /opt/zig-0.16.0 --strip-components=1 \
#     && rm zig-x86_64-linux-0.16.0.tar.xz

# Install Zig 0.17.0
RUN wget -q https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz \
    && tar -xJf zig-x86_64-linux-0.17.0.tar.xz -C /opt/zig-0.17.0 --strip-components=1 \
    && rm zig-x86_64-linux-0.17.0.tar.xz

# Install kcov from source
RUN wget -q https://github.com/SimonKagstrom/kcov/archive/refs/heads/master.tar.gz \
    && tar -xzf master.tar.gz \
    && cd kcov-master \
    && pwd \
    && mkdir build \
    && cd build \
    && cmake .. -DCMAKE_INSTALL_PREFIX=/opt/kcov \
    && make -j$(nproc) \
    && make install \
    && cd / && rm -rf kcov-master master.tar.gz

RUN wget -q https://install.duckdb.org/v1.5.5/libduckdb-linux-amd64.zip \
    && unzip libduckdb-linux-amd64.zip -d /opt/libduckdb \
    && cd / && rm -rf libduckdb-linux-amd64.zip

FROM alpine:latest 
LABEL maintainer="im-ng"
LABEL description="Multi-version Zig CI container with kcov coverage support"
LABEL version="0.3.6"

# Update dependencies for zig, zero, kcov
RUN apk add --no-cache \
    git \
    bash \
    jq \
    openssh \
    libssh libssh2 libssh2-dev \
    musl-dev libc6-compat \
    ca-certificates \
    librdkafka librdkafka-dev \
    binutils-dev curl-dev elfutils-dev curl \
    nodejs npm

# Create working directories
# RUN mkdir -p /usr/local/zig-0.15.2 /app
# RUN mkdir -p /usr/local/zig-0.16.0 /app /app/libs
RUN mkdir -p /usr/local/zig-0.17.0 /app /app/libs

COPY --from=builder /opt/kcov* /usr/
COPY --from=builder /opt/zig-0.17.0 /usr/local/zig-0.17.0/
# RUN ls -alt /usr/local/zig-0.15.2/
# RUN ls -alth

# COPY ALPINE SPECIFIC DUCKDB LIBRARY FOR ZERO COMPILATION
COPY /libs/duckdb-alpine.h /usr/local/lib/duckdb.h
COPY /libs/libduckdb-alpine.so /usr/local/lib/libduckdb.so
COPY /libs/libduckdb-alpine.so /usr/local/lib/libduckdb.so.1.5

# Set environment variables for Zig versions
# ENV ZIG151=/opt/zig/zig-0.15.1
# ENV ZIG152=/opt/zig/zig-0.15.2
# ENV ZIG160=/opt/zig/zig-0.16.0
ENV ZIG=/usr/local/zig-0.17.0

# RUN ln -s /usr/local/zig-0.16.0/zig /usr/local/bin/zig
RUN ln -s /usr/local/zig-0.17.0/zig /usr/local/bin/zig
# RUN chmod -R 777 /usr/local/zig-0.15.2
# ENV PATH="${ZIG151}:${ZIG152}:${ZIG160}:${PATH}"
# ENV PATH="${ZIG}:${PATH}"

# SBOM tooling (see .github/workflows/sbom.yml + scripts/gen-sbom.sh).
# cdxgen parses build.zig.zon for source deps; cyclonedx-cli merges the
# source and binary CycloneDX fragments; syft scans the compiled binary.
# CycloneDX CLI has no npm package — install the musl release binary directly.

# cdxgen (npm)
RUN npm install -g @cyclonedx/cdxgen

# syft (official install script -> /usr/local/bin)
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
    | sh -s -- -b /usr/local/bin \
    && syft version

# cyclonedx-cli (musl release asset, correct for Alpine). The asset may be a
# raw binary or a gzip tarball depending on release, so detect and handle both.
RUN curl -sSfL -o /tmp/cyclonedx-cli \
        https://github.com/CycloneDX/cyclonedx-cli/releases/download/v0.33.1/cyclonedx-linux-musl-x64 \
    && if [ "$(head -c2 /tmp/cyclonedx-cli | od -An -tx1 | tr -d ' ')" = "1f8b" ]; then \
           tar -xzf /tmp/cyclonedx-cli -C /usr/local/bin; \
       else \
           install /tmp/cyclonedx-cli /usr/local/bin/cyclonedx-cli; \
       fi \
    && chmod +x /usr/local/bin/cyclonedx-cli \
    && cyclonedx-cli --version

WORKDIR /app
RUN ls -alth /usr/local/lib/
RUN tree -a

CMD ["/bin/bash"]
