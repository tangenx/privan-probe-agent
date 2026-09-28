# Probe agent image, built for linux/amd64 and linux/arm64:
#   scripts/publish.sh (manual) or .github/workflows/image.yml (CI)
FROM --platform=$BUILDPLATFORM dart:3.13.1 AS build
ARG TARGETARCH

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY lib/ lib/
COPY bin/ bin/
RUN case "$TARGETARCH" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported arch $TARGETARCH" && exit 1 ;; \
    esac \
    && dart pub get --offline \
    && dart build cli -t bin/probe_agent.dart -o out \
       --target-os linux --target-arch "$arch"

FROM debian:bookworm-slim
ARG TARGETARCH
ARG XRAY_VERSION=26.3.27

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      iputils-ping \
      unzip \
    && case "$TARGETARCH" in \
      amd64) asset=64 ;; \
      arm64) asset=arm64-v8a ;; \
      *) echo "unsupported arch $TARGETARCH" && exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${asset}.zip" \
    && unzip /tmp/xray.zip xray -d /tmp/xray \
    && install -m 0755 /tmp/xray/xray /usr/local/bin/xray \
    && rm -rf /tmp/xray /tmp/xray.zip \
    && apt-get purge -y curl unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged ICMP works via docker's default net.ipv4.ping_group_range.
RUN useradd --system --home-dir /var/lib/probe-agent probe \
    && mkdir -p /var/lib/probe-agent \
    && chown probe /var/lib/probe-agent

COPY --from=build /app/out/bundle/ /app/

USER probe
ENV PROBE_AGENT_LOG_DIR=/var/lib/probe-agent/xray
CMD ["/app/bin/probe_agent"]
