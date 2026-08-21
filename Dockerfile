# syntax=docker/dockerfile:1

# Production image for this ERPNext fork.
#
# WHY python-slim AND NOT node-alpine
# -----------------------------------
# Frappe v17 pins Python >=3.14,<3.15. Alpine 3.24 does ship python3.14, so the
# version is not the problem - musl is. Three dependencies publish no musl
# wheels: duckdb (would compile DuckDB's C++ from source), typst (needs a Rust
# toolchain), and mysqlclient (sdist-only on every platform). On Debian slim all
# three resolve to prebuilt manylinux wheels except mysqlclient, which is one
# small C extension built in the builder stage below.
#
# Alpine would have saved roughly 130MB of base OS. The 3.79GB of frappe/bench
# is not base OS: it is two pyenv Pythons, two nvm Nodes, build-essential, LLVM,
# every -dev header, plus wkhtmltopdf AND chromium. Multi-stage removes that.
#
# ONE IMAGE, MANY ROLES
# ---------------------
# web, websocket, worker, scheduler and nginx all run from this image; the role
# is chosen by the container's command. That keeps assets and their manifests
# byte-identical across roles - the backend reads sites/assets/*.json to render
# hashed asset URLs that nginx then has to serve. See deploy/docker-compose.prod.yml.

ARG PYTHON_VERSION=3.14-slim-bookworm
ARG NODE_VERSION=24-bookworm-slim

FROM node:${NODE_VERSION} AS node


# --------------------------------------------------------------------- base
# Runtime-only layer. Shared by the builder so the two stages cannot drift.
FROM python:${PYTHON_VERSION} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
# Frappe's default PDF engine is still wkhtmltopdf (frappe/utils/pdf.py:get_pdf).
# Chromium is only used when a Print Format sets pdf_generator="chrome", so it
# is opt-in: it costs ~150MB. Build with --build-arg INSTALL_CHROMIUM=true to
# include it.
ARG INSTALL_CHROMIUM=false

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    BENCH_PATH=/home/frappe/frappe-bench

RUN useradd -ms /bin/bash frappe \
 && apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates \
      curl \
      git \
      nginx \
      gettext-base \
      mariadb-client \
      media-types \
      fontconfig \
      fonts-cantarell \
      xfonts-75dpi \
      xfonts-base \
      libjpeg62-turbo \
      libxrender1 \
      libxext6 \
      libmariadb3 \
 && ARCH="$(dpkg --print-architecture)" \
 && DEB="wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb" \
 && curl -fsSLO "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${DEB}" \
 && apt-get install --no-install-recommends -y "./${DEB}" \
 && rm "${DEB}" \
 && if [ "${INSTALL_CHROMIUM}" = "true" ]; then \
      apt-get install --no-install-recommends -y chromium-headless-shell; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# Node runtime. The realtime server (apps/frappe/socketio.js) runs on it. Only
# the binary is copied - npm and yarn belong to the builder stage. Copying into
# /usr/local/bin file-by-file matters: a blanket COPY of /usr/local from the
# node image would clobber this image's python.
COPY --from=node /usr/local/bin/node /usr/local/bin/node

# The bench CLI itself. Needed at runtime for `bench worker`, `bench schedule`
# and `bench migrate`; frappe and erpnext live in the bench's own venv, not here.
RUN pip install --no-cache-dir frappe-bench

# nginx as a non-root user.
RUN rm -f /etc/nginx/sites-enabled/default \
 && mkdir -p /etc/nginx/snippets \
 && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && touch /run/nginx.pid \
 && chown -R frappe:frappe /etc/nginx /var/log/nginx /var/lib/nginx /run/nginx.pid


# ------------------------------------------------------------------ builder
# Compilers, headers, npm and yarn. None of this reaches the final image.
FROM base AS builder

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      build-essential \
      pkg-config \
      libmariadb-dev \
      libffi-dev \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# The node image ships yarn 1.x under /opt/yarn-v<version>. Globbed rather than
# pinned so a node base bump does not silently break the build.
COPY --from=node /opt /opt
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -sf "$(ls -d /opt/yarn-v*)/bin/yarn" /usr/local/bin/yarn \
 && yarn --version

USER frappe
WORKDIR /home/frappe

ARG FRAPPE_REPO=https://github.com/frappe/frappe
# erpnext 17.0.0-dev requires frappe >=17.0.0-dev,<18.0.0 (see pyproject.toml
# [tool.bench.frappe-dependencies]), which today means the develop branch. Pin
# this to a tag or SHA before you cut a real release - `develop` is a moving
# target and will not reproduce.
ARG FRAPPE_BRANCH=develop

# --skip-assets: nothing to build yet, erpnext is not in place. Building here
# would also fail, since bench treats every directory under apps/ as an app.
RUN bench init \
      --frappe-path="${FRAPPE_REPO}" \
      --frappe-branch="${FRAPPE_BRANCH}" \
      --skip-redis-config-generation \
      --no-procfile \
      --no-backups \
      --skip-assets \
      /home/frappe/frappe-bench

# The app itself, from the build context rather than a git clone, so the image
# reflects the working tree you built it from.
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

WORKDIR /home/frappe/frappe-bench

# Install into the bench venv and register the app. Editable (-e) because
# Frappe resolves app paths through the module's __file__ and expects the
# source tree under apps/ to be the live one.
RUN ./env/bin/pip install --no-cache-dir -e apps/erpnext \
 && printf 'frappe\nerpnext\n' > sites/apps.txt \
 && echo '{}' > sites/common_site_config.json

# `bench build` does NOT run yarn install - that normally happens inside
# `bench get-app`, which this Dockerfile bypasses. Skipping this step fails with
# "Could not resolve onscan.js", and bench still exits 0 on that failure.
RUN bench setup requirements --node

# Do NOT add --hard-link here. frappe/build.py places the node_modules link at
# sites/assets/<app>/node_modules; because sites/assets/<app> is normally a
# symlink into apps/<app>/<app>/public, that link lands inside the app, which is
# where desk.bundle.scss's `@import "frappe/public/node_modules/..."` resolves
# it. --hard-link makes sites/assets/<app> a real directory, the link lands
# there instead, and the build dies on "Could not resolve highlight.js".
# The symlinks it writes are absolute, so the `mv` below is safe regardless.
RUN bench build --production

# Strip what only the build needed. frappe's node_modules stays: socketio.js
# imports socket.io and @redis/client from it at runtime, and frappe's
# package.json has no dependencies/devDependencies split to prune along.
# Strip what only the build needed. Two things deliberately stay:
#   - apps/frappe/node_modules: socketio.js imports socket.io and @redis/client
#     from it at runtime, and frappe's package.json has no dependencies /
#     devDependencies split to prune along.
#   - apps/erpnext/node_modules: only ~100KB, and assets/erpnext/node_modules
#     symlinks into it - deleting it would leave a dangling link under /assets.
# banking/node_modules is the 323MB one, and it is build-only (a Vite SPA).
#
# The final `mv`: sites/ becomes a volume at runtime and would hide anything
# stored beneath it, so the built assets move up one level. entrypoint.sh links
# them back in as sites/assets. The symlinks inside are absolute paths into
# apps/, which is untouched, so they survive the move.
#
# Only two node_modules entries are provably dead weight. Most of what looks
# build-only is not, and each of these was checked rather than assumed:
#   - ace-builds (55MB) STAYS: code.js sets ace's basePath to
#     /assets/frappe/node_modules/ace-builds/src-noconflict/, so it is fetched
#     over HTTP whenever a user opens any Code field.
#   - sass + sass-embedded STAY: generate_bootstrap_theme.js runs at runtime
#     (Website Theme) and requires ./esbuild/sass_compiler, which needs them.
RUN rm -rf apps/erpnext/banking/node_modules \
 && rm -rf apps/frappe/node_modules/typescript \
 && rm -rf apps/frappe/node_modules/sass-embedded-linux-musl-* \
 && find apps -mindepth 2 -maxdepth 3 -name .git -prune -exec rm -rf {} + \
 && find apps -type d -name __pycache__ -prune -exec rm -rf {} + \
 && mv sites/assets assets


# ------------------------------------------------------------------ runtime
FROM base AS erpnext

USER frappe
WORKDIR /home/frappe/frappe-bench

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

COPY --chown=frappe:frappe deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=frappe:frappe deploy/create-site.sh /usr/local/bin/create-site.sh
COPY --chown=frappe:frappe deploy/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh
COPY --chown=frappe:frappe deploy/nginx.conf.template /templates/nginx.conf.template

USER root
RUN chmod 755 /usr/local/bin/entrypoint.sh \
               /usr/local/bin/create-site.sh \
               /usr/local/bin/nginx-entrypoint.sh
USER frappe

# Both are volumes in production: sites holds site config, uploaded files and
# the (linked) assets; logs is written by every role.
VOLUME ["/home/frappe/frappe-bench/sites", "/home/frappe/frappe-bench/logs"]

EXPOSE 8000 9000 7080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["gunicorn"]
