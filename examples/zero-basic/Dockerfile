FROM gitea.pi/ng/debian:trixie-slim
LABEL maintainer="im-ng"
LABEL description="Base image to run zero framework apps"
LABEL version="1.0.0"

# COPY ALPINE SPECIFIC DUCKDB LIBRARY FOR ZERO COMPILATION
COPY /libs/duckdb.h /usr/local/lib/duckdb.h
COPY /libs/libduckdb.so /usr/local/lib/libduckdb.so
# COPY ../../libs/libduckdb-alpine.so /usr/local/lib/libduckdb.so.1.5

WORKDIR /app

RUN apt update
RUN apt install librdkafka-dev curl -y

RUN mkdir -p /app/data  && chmod 777 /app/data
RUN mkdir -p /app/static  && chmod 777 /app/static

COPY /data /app/data
COPY /static /app/static
COPY /zig-out/bin/basic /app/basic

RUN mkdir /app/configs
RUN touch /app/configs/.env

RUN ls -alth /app/
RUN ls -alth /usr/local/lib/
RUN pwd 

EXPOSE 8080
CMD ["./basic"]