FROM gitea.pi/ng/alpine:3.24 
LABEL maintainer="im-ng"
LABEL description="Base image to run zero framework apps"
LABEL version="1.0.0"

# COPY ALPINE SPECIFIC DUCKDB LIBRARY FOR ZERO COMPILATION
COPY ../../libs/duckdb-alpine.h /usr/local/lib/duckdb.h
COPY ../../libs/libduckdb-alpine.so /usr/local/lib/libduckdb.so
COPY ../../libs/libduckdb-alpine.so /usr/local/lib/libduckdb.so.1.5

WORKDIR /app

RUN apk add --no-cache \
    curl wget \
    openssh \
    libssh libssh2 libssh2-dev \
    ca-certificates tzdata \
    librdkafka librdkafka-dev

RUN mkdir -p /app/data  && chmod 777 /app/data
RUN mkdir -p /app/static  && chmod 777 /app/static

COPY /data /app/data
COPY /static /app/static
COPY /zig-out/bin/basic /app/basic

RUN ls -alth /usr/local/lib/

EXPOSE 8080
CMD ["./basic"]