# syntax=docker/dockerfile:1
FROM golang:1.25.2-bookworm AS backend-source
WORKDIR /src/backend
COPY backend/ ./
FROM backend-source AS backend-test
RUN go test -race ./... && go vet ./...
FROM backend-source AS backend-build
RUN CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags='-s -w' -o /out/haven . \
    && mkdir -p /out/data && chmod 700 /out/data

FROM debian:bookworm-slim AS flutter-sdk
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip libglu1-mesa libglib2.0-0 libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
ARG FLUTTER_REVISION=abaf9c523780a608bd46686fd5e53740a07077f8
ARG FLUTTER_VERSION=3.47.7
RUN git init /opt/flutter && git -C /opt/flutter remote add origin https://github.com/flutter/flutter.git \
    && git -C /opt/flutter fetch --depth 1 origin "refs/tags/$FLUTTER_VERSION:refs/tags/$FLUTTER_VERSION" \
    && git -C /opt/flutter checkout --detach "$FLUTTER_VERSION" \
    && test "$(git -C /opt/flutter rev-parse HEAD)" = "$FLUTTER_REVISION"
ENV PATH=/opt/flutter/bin:$PATH CI=true
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /src/client
COPY client/pubspec.yaml client/pubspec.lock ./
RUN flutter pub get --enforce-lockfile
COPY client/ ./
FROM flutter-sdk AS frontend-test
RUN flutter analyze && flutter test
FROM flutter-sdk AS frontend-build
RUN flutter build web --release --no-pub --no-web-resources-cdn

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
LABEL org.opencontainers.image.source=https://github.com/jeethsuresh/haven
WORKDIR /app
COPY --from=backend-build /out/haven /app/haven
COPY --from=frontend-build /src/client/build/web /app/web
COPY --from=backend-build --chown=10001:10001 /out/data /data
ENV HAVEN_LISTEN=0.0.0.0:8080 HAVEN_DATA=/data HAVEN_WEB=/app/web
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/app/haven"]
