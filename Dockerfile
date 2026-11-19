# VanguardVPS — Ubuntu 24.04 SSH + 9router
# Dev: TheFoolByte

FROM ubuntu:24.04

RUN userdel -r ubuntu 2>/dev/null || true

RUN sed -i 's/^Components: .*/Components: main restricted universe/' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

RUN apt-get update \
    && apt-get install -y \
        ca-certificates gnupg apt-transport-https software-properties-common \
        openssh-server \
        curl wget \
        iproute2 iputils-ping net-tools dnsutils traceroute whois telnet nmap \
        vim nano micro \
        htop btop ncdu neofetch \
        tmux screen less tree bat ripgrep fd-find jq zsh \
        unzip zip tar gzip bzip2 xz-utils p7zip-full \
        git build-essential cmake pkg-config autoconf automake libtool gcc g++ \
        python3 python3-pip python3-venv python3-dev \
        rsync sqlite3 \
        locales ncurses-term language-pack-en language-pack-id \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && mkdir -p /run/sshd \
    && chmod 755 /run/sshd \
    && ssh-keygen -A \
    && echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config \
    && echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

RUN locale-gen en_US.UTF-8 id_ID.UTF-8

COPY vanguard-welcome.sh /etc/profile.d/vanguard-welcome.sh

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV TERM=xterm-256color

# npm cache lives on the big overlay disk (/tmp), NOT on the 500MB /root
# volume — the 9Router CLI re-installs its SQLite runtime deps at every
# container start, and the npm cache alone was ~82MB on the volume.
ENV NPM_CONFIG_CACHE=/tmp/npm-cache

# Node.js 22 LTS (pinned; includes corepack) + npm usable as root
# 9Router is NOT installed from the official npm package anymore.
# It is built from Jun's modified fork (TheFoolByte/9router, branch
# neo-brutalism — Second Brain, Live or Not, neo-brutalism UI) and installed
# globally from its cli/ package, so the `9router` command keeps working.
# Verified fork head: 31c8567 (neo-brutalism, Live or Not gate). The fork
# source is removed after install to keep the image small; the global CLI is self-contained.
# cli/ gets its own install first: its build script (buildMitm.js) needs
# esbuild, which is a devDependency of the cli package, not of the app.
# Install from a tarball, not from the directory: `npm install -g ./cli`
# only symlinks the global package to the fork source, and the fork source
# is deleted below, which leaves a dangling link and breaks the favicon
# patch (and the `9router` command). A tarball install copies the files.
# Pin the exact fork commit this image builds. The git clone lives inside a
# Docker layer: without the commit in the command, a rebuild reuses the
# cached layer and silently ships the previous fork code (this bit us on
# 2026-11-19: a redeploy reported SUCCESS with a byte-identical image).
# Bump this on every fork push.
ARG NINE_ROUTER_COMMIT=31c8567459670831c1eee860b0ad5f1d21a0a538
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && ln -sf /usr/bin/pip3 /usr/local/bin/pip \
    && npm config set fund false \
    && npm config set audit false \
    && npm config set update-notifier false \
    && npm install -g npm@latest \
    && npm config set ignore-scripts false \
    && corepack enable \
    && git clone --depth 1 --branch neo-brutalism https://github.com/TheFoolByte/9router.git /opt/9router-fork \
    && cd /opt/9router-fork \
    && git fetch --depth 1 origin "$NINE_ROUTER_COMMIT" \
    && git checkout "$NINE_ROUTER_COMMIT" \
    && npm install \
    && npm --prefix cli install \
    && NEXT_TELEMETRY_DISABLED=1 npm --prefix cli run build \
    && TARBALL=$(npm pack ./cli | tail -n 1) \
    && npm install -g --allow-scripts=9router "./$TARBALL" \
    && cd / \
    && rm -rf /opt/9router-fork

COPY static/favicon.svg static/favicon.ico static/patch-favicon.py /usr/local/share/vanguard/
RUN sed -i 's/\r$//' /usr/local/share/vanguard/patch-favicon.py \
    && python3 /usr/local/share/vanguard/patch-favicon.py

COPY ssh-user-config.sh /usr/local/bin/ssh-user-config.sh
COPY usage /usr/local/bin/usage
COPY src-sync.sh /usr/local/bin/src-sync
COPY vanguard-clean.sh /usr/local/bin/vanguard-clean
COPY config.json /etc/vanguard/config.json
RUN sed -i 's/\r$//' /usr/local/bin/ssh-user-config.sh /usr/local/bin/usage /usr/local/bin/src-sync /usr/local/bin/vanguard-clean /etc/profile.d/vanguard-welcome.sh /etc/vanguard/config.json \
    && chmod +x /usr/local/bin/ssh-user-config.sh /usr/local/bin/usage /usr/local/bin/src-sync /usr/local/bin/vanguard-clean /etc/profile.d/vanguard-welcome.sh \
    && mkdir -p /root/src

EXPOSE 22 20128

CMD ["/usr/local/bin/ssh-user-config.sh"]
