FROM rust:latest AS build
WORKDIR /app
COPY . /app
RUN cargo build --release --bin gateway_native

RUN ls -lah /app/target/release && file /app/target/release/*

FROM debian:bookworm-slim
COPY --from=build /app/target/release/gateway_native /usr/local/bin/gateway_native
EXPOSE 8080
ENV LISTEN=0.0.0.0:8080
ENV UPSTREAM_URL=http://host.docker.internal:18080
CMD ["gateway_native"]
