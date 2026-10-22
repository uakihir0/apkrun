# AOSP builds run only in this pinned Linux x86_64 environment.
FROM --platform=linux/amd64 ubuntu:22.04@sha256:98510ac07bb4545e389be502a8918b385c018bfe4ceeb5ac7e0375c782268b04

ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT=20261020T000000Z
ARG CMDLINE_TOOLS_URL=https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip
ARG CMDLINE_TOOLS_SHA256=7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee
ARG REPO_LAUNCHER_SHA256=6ed2f6325705b6ea0af99466d6ebd04adec387a5b6a906cd77bc8c6da65123e5
ARG REPO_CLIENT_REVISION=97dc5c1bd9527c2abe2183b16a4b7ef037dc34a7

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    APKRUN_REPO_CLIENT_REVISION=97dc5c1bd9527c2abe2183b16a4b7ef037dc34a7 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PATH=/opt/android-sdk/cmdline-tools/19.0/bin:/opt/android-sdk/platform-tools:/usr/local/bin:/usr/bin:/bin

RUN set -eu; \
    test "$(dpkg --print-architecture)" = amd64; \
    printf 'deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/%s/ jammy main restricted universe multiverse\n' "$UBUNTU_SNAPSHOT" > /etc/apt/sources.list; \
    printf '%s\n' \
        "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$UBUNTU_SNAPSHOT/ jammy-updates main restricted universe multiverse" \
        "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$UBUNTU_SNAPSHOT/ jammy-backports main restricted universe multiverse" \
        "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$UBUNTU_SNAPSHOT/ jammy-security main restricted universe multiverse" \
        >> /etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/ubuntu.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install --no-install-recommends -y \
        bc \
        bison \
        build-essential \
        ca-certificates \
        curl \
        file \
        flex \
        fontconfig \
        g++ \
        git \
        git-lfs \
        gnupg \
        gperf \
        lib32ncurses-dev \
        lib32readline-dev \
        libc6-dev-i386 \
        lib32z1-dev \
        libelf-dev \
        libgl1-mesa-dev \
        liblz4-tool \
        libncurses5-dev \
        libncursesw5-dev \
        libssl-dev \
        libxml2 \
        libxml2-utils \
        libx11-dev \
        locales \
        lzop \
        openjdk-17-jdk \
        patchelf \
        pngcrush \
        python-is-python3 \
        python3 \
        python3-pip \
        python3-venv \
        rsync \
        schedtool \
        squashfs-tools \
        unzip \
        x11proto-core-dev \
        xsltproc \
        zip \
        zlib1g-dev \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 3 --silent --show-error \
        https://storage.googleapis.com/git-repo-downloads/repo \
        --output /usr/local/bin/repo \
    && echo "${REPO_LAUNCHER_SHA256}  /usr/local/bin/repo" | sha256sum --check --status \
    && chmod 0755 /usr/local/bin/repo

RUN set -eu; \
    archive="$(mktemp)"; \
    curl --fail --location --retry 3 --silent --show-error \
        "${CMDLINE_TOOLS_URL}" --output "${archive}"; \
    echo "${CMDLINE_TOOLS_SHA256}  ${archive}" | sha256sum --check --status; \
    mkdir -p "${ANDROID_HOME}/cmdline-tools/19.0"; \
    unzip -q "${archive}" -d /tmp/android-cmdline-tools; \
    mv /tmp/android-cmdline-tools/cmdline-tools/* "${ANDROID_HOME}/cmdline-tools/19.0/"; \
    rm -rf "${archive}" /tmp/android-cmdline-tools

RUN yes | sdkmanager --sdk_root="${ANDROID_HOME}" --licenses >/dev/null \
    && sdkmanager --sdk_root="${ANDROID_HOME}" --install \
        "platform-tools" \
        "platforms;android-37.0" \
        "build-tools;37.0.0" \
        "ndk;28.2.13676358" \
    && sdkmanager --sdk_root="${ANDROID_HOME}" --list_installed

RUN useradd --create-home --uid 1000 --user-group builder
USER builder
WORKDIR /work/aosp
