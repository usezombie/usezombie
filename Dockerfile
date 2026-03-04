# UseZombie — Zig binary build + runtime
# Multi-stage: build with Zig toolchain, deploy static binary only

FROM alpine:3.21 AS build
WORKDIR /build
RUN apk add --no-cache curl xz git
RUN curl -L https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz | tar xJ
ENV PATH="/build/zig-linux-x86_64-0.15.2:${PATH}"
COPY build.zig build.zig.zon ./
COPY src ./src
COPY config ./config
RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.21
RUN apk add --no-cache git bubblewrap
WORKDIR /app
COPY --from=build /build/zig-out/bin/zombied /usr/local/bin/zombied
COPY config ./config
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:3000/healthz || exit 1
CMD ["zombied", "serve"]
