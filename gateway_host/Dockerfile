FROM rust:latest AS build
WORKDIR /app
COPY . /app
RUN cargo build -p gateway_host --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/gateway_host /usr/local/bin/gateway_host
EXPOSE 8080
ENV LISTEN=0.0.0.0:8080
ENV UPSTREAM_URL=http://host.docker.internal:18080
ENV WASM_MODULE_PATH=/app/gateway_logic.wasm
CMD ["gateway_host"]
