# A production image: build with the full toolchain, run on a small base.
#
#   docker build -t app .
#   docker run -p 8080:8080 -e ALULA_DATASOURCE_PRIMARY_URL=... app
#
# A project with migrations gets the `migrate` tool in the same image:
#
#   docker run --entrypoint ./migrate -e ALULA_DATABASE_URL=... app apply
#
# ALULA_ENV is prod, so alula-prod.yaml applies on top of alula.yaml.

# ── build ────────────────────────────────────────────────────────────────────
FROM swift:6.3.3-noble AS build
WORKDIR /build

# Dependencies first, so editing a source file does not re-resolve them.
COPY Package.swift Package.resolved* ./
RUN swift package resolve

COPY . .
RUN swift build -c release --static-swift-stdlib \
 && mkdir -p /staging \
 && bin="$(swift build -c release --show-bin-path)" \
 && for product in App migrate; do \
      if [ -f "$bin/$product" ]; then cp "$bin/$product" /staging/; fi; \
    done \
 && find -L "$(swift build -c release --show-bin-path)" -maxdepth 1 -name '*.resources' \
      -exec cp -R {} /staging/ \; \
 && cp alula*.yaml /staging/

# ── run ──────────────────────────────────────────────────────────────────────
FROM ubuntu:noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata libcurl4 libxml2 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home /app --shell /usr/sbin/nologin alula
WORKDIR /app
COPY --from=build --chown=alula:alula /staging /app
USER alula

ENV ALULA_ENV=prod
# Listen beyond the container's own loopback.
ENV ALULA_SERVER_HOST=0.0.0.0
EXPOSE 8080

# SIGTERM reaches the app directly (no shell), so it drains and shuts down in
# order: lifecycle.drain-seconds and shutdown-timeout-seconds apply.
ENTRYPOINT ["./App"]
