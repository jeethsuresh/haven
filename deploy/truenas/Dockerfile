FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip libglu1-mesa clang cmake ninja-build pkg-config \
    libgtk-3-dev libsecret-1-dev libjsoncpp-dev liblzma-dev libssl-dev libpulse-dev \
    libasound2-dev libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libgbm-dev \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/opt/flutter/bin:$PATH CI=true FLUTTER_SUPPRESS_ANALYTICS=true CMAKE_BUILD_PARALLEL_LEVEL=2
RUN git init /opt/flutter && git -C /opt/flutter remote add origin https://github.com/flutter/flutter.git \
    && git -C /opt/flutter fetch --depth 1 origin refs/tags/3.47.7:refs/tags/3.47.7 \
    && git -C /opt/flutter checkout --detach 3.47.7 \
    && test "$(git -C /opt/flutter rev-parse HEAD)" = abaf9c523780a608bd46686fd5e53740a07077f8
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get --enforce-lockfile
COPY lib/ ./lib/
COPY linux/ ./linux/
RUN flutter pub get --offline --enforce-lockfile \
    && flutter build linux --release --no-pub --target lib/nas_main.dart

FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/jeethsuresh/haven"
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates fonts-dejavu-core libgtk-3-0t64 libsecret-1-0 libjsoncpp25 \
    liblzma5 libssl3t64 libpulse0 libasound2t64 libgbm1 libgl1 libnss3 \
    libxss1 libx11-xcb1 libxdamage1 libxrandr2 libgl1-mesa-dri libegl1 libegl-mesa0 \
    util-linux xvfb xauth \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/linux/*/release/bundle/ /app/
COPY truenas-entrypoint.sh /app/entrypoint.sh
ENV XDG_CONFIG_HOME=/state/config XDG_CACHE_HOME=/state/cache XDG_DATA_HOME=/state/data \
    GTK_A11Y=none GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
USER 568:568
WORKDIR /app
ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]
