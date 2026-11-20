# Quality gate and builds for Where's My Money (see .claude/specs/SPEC-devops.md).
#   docker build --target toolchain --build-arg UID=(id -u) --build-arg GID=(id -g) -t wmmt-toolchain .
#   docker build --target ci .
# The Android SDK and NDK for Linux are x86_64 only, so this image is amd64 only.

# ---------------------------------------------------------------------------
# toolchain: pinned Flutter + Android SDK + JDK 21, run as a non-root user.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8 AS toolchain

# Each ARG sits right before the step that uses it, so changing one only rebuilds from there.
ENV DEBIAN_FRONTEND=noninteractive \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    ANDROID_HOME=/opt/android-sdk \
    FLUTTER_HOME=/opt/flutter
ENV PATH=$FLUTTER_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openjdk-21-jdk-headless unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# The base image ships a `ubuntu` user with UID 1000; replace it so UID/GID can match the host
# (files written to bind mounts stay owned by the developer or the CI runner).
ARG UID=1000
ARG GID=1000
RUN userdel --remove ubuntu \
 && groupadd --non-unique --gid "$GID" dev \
 && useradd --non-unique --uid "$UID" --gid "$GID" --create-home --shell /bin/bash dev \
 && mkdir -p "$ANDROID_HOME" "$FLUTTER_HOME" /app \
 && chown dev:dev "$ANDROID_HOME" "$FLUTTER_HOME" /app

USER dev

# From developer.android.com/studio#command-line-tools-only.
ARG ANDROID_CMDLINE_TOOLS_ZIP=commandlinetools-linux-15859902_latest.zip
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
# Flutter 3.47.6 defaults: compileSdk/targetSdk 36, NDK 28.2.13676358.
ARG ANDROID_PACKAGES="platform-tools platforms;android-36 build-tools;36.0.0 ndk;28.2.13676358"
RUN curl -fsSLo /tmp/cmdline-tools.zip "https://dl.google.com/android/repository/$ANDROID_CMDLINE_TOOLS_ZIP" \
 && echo "$ANDROID_CMDLINE_TOOLS_SHA256  /tmp/cmdline-tools.zip" | sha256sum -c - \
 && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools \
 && mkdir -p "$ANDROID_HOME/cmdline-tools" \
 && mv /tmp/cmdline-tools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" \
 && rm -rf /tmp/cmdline-tools /tmp/cmdline-tools.zip \
 && (yes | sdkmanager --licenses > /dev/null) \
 && sdkmanager --install $ANDROID_PACKAGES > /dev/null

# Must match `environment: flutter` in pubspec.yaml (tool/check_pins.sh).
ARG FLUTTER_VERSION=3.47.6
# A moved tag would change the commit, so the build fails instead of using other code.
ARG FLUTTER_COMMIT=5fc346839b5d0eef006ed8404392afb4dfae428d
RUN git clone --quiet --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME" \
 && test "$(git -C "$FLUTTER_HOME" rev-parse HEAD)" = "$FLUTTER_COMMIT" \
 && git -C "$FLUTTER_HOME" switch --quiet --create stable \
 && flutter config --no-analytics --no-cli-animations > /dev/null \
 && dart --disable-analytics > /dev/null \
 && flutter precache --web --android \
 && flutter --version

WORKDIR /app

# ---------------------------------------------------------------------------
# ci: the quality gate, the same steps locally and in CI.
# ---------------------------------------------------------------------------
FROM toolchain AS ci
ARG UID=1000
ARG GID=1000

COPY --chown=dev:dev pubspec.yaml pubspec.lock ./
RUN flutter pub get --enforce-lockfile

COPY --chown=dev:dev . .
RUN dart format --output=none --set-exit-if-changed .
RUN flutter analyze --fatal-infos
RUN flutter test --coverage --exclude-tags integration
RUN sh tool/check_coverage.sh 80
RUN flutter build web
RUN --mount=type=cache,target=/home/dev/.gradle,uid=$UID,gid=$GID \
    flutter build apk --debug
