FROM alpine:latest as builder

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
RUN mkdir -p /opt/zig-0.15.1 /opt/zig-0.15.2 /opt/zig-0.16.0 /opt/kcov

# Install Zig 0.15.1
# RUN wget -q https://ziglang.org/download/0.15.1/zig-x86_64-linux-0.15.1.tar.xz \
#     && tar -xJf zig-x86_64-linux-0.15.1.tar.xz -C /opt/zig-0.15.1 --strip-components=1 \
#     && rm zig-x86_64-linux-0.15.1.tar.xz

# Install Zig 0.15.2
RUN wget -q https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    && tar -xJf zig-x86_64-linux-0.15.2.tar.xz -C /opt/zig-0.15.2 --strip-components=1 \
    && rm zig-x86_64-linux-0.15.2.tar.xz

# Install Zig 0.16.0
# RUN wget -q https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
#     && tar -xJf zig-x86_64-linux-0.16.0.tar.xz -C /opt/zig-0.16.0 --strip-components=1 \
#     && rm zig-x86_64-linux-0.16.0.tar.xz

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

FROM alpine:latest 
LABEL maintainer="im-ng"
LABEL description="Multi-version Zig CI container with kcov coverage support"
LABEL version="0.1"

# Update dependencies for zig, zero, kcov
RUN apk add --no-cache \
    git \
    bash \
    jq \
    ca-certificates \
    librdkafka librdkafka-dev \
    binutils-dev curl-dev elfutils-dev

# Create working directories
RUN mkdir -p /usr/local/zig-0.15.2 /app

COPY --from=builder /opt/kcov* /usr/
COPY --from=builder /opt/zig-0.15.2 /usr/local/zig-0.15.2/
# RUN ls -alt /usr/local/zig-0.15.2/
# RUN ls -alth

# Set environment variables for Zig versions
# ENV ZIG151=/opt/zig/zig-0.15.1
# ENV ZIG152=/opt/zig/zig-0.15.2
# ENV ZIG160=/opt/zig/zig-0.16.0
ENV ZIG=/usr/local/zig-0.15.2

RUN ln -s /usr/local/zig-0.15.2/zig /usr/local/bin/zig
# RUN chmod -R 777 /usr/local/zig-0.15.2
# ENV PATH="${ZIG151}:${ZIG152}:${ZIG160}:${PATH}"
# ENV PATH="${ZIG}:${PATH}"

WORKDIR /app

CMD ["/bin/bash"]
