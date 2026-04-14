FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache
# tini reaps orphaned zombie processes (MCP stdio subprocesses, git, bun, etc.)
# that would otherwise accumulate when hermes runs as PID 1. See #15012.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps \
        git openssh-client docker-cli ca-certificates gnupg curl tini && \
    rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) — add the official apt repo and install.
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# claude-code CLI (official Anthropic CLI, used by the bundled claude-code skill).
RUN npm install -g @anthropic-ai/claude-code

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
#
# ui-tui/packages/hermes-ink/ is copied IN FULL (not just its manifests)
# because it is referenced as a `file:` workspace dependency from
# ui-tui/package.json.  Copying the tree up front lets npm resolve the
# workspace to real content instead of stopping at a bare package.json.
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

# `npm_config_install_links=false` forces npm to install `file:` deps as
# symlinks (the npm 10+ default) even on Debian's older bundled npm 9.x,
# which defaults to `install-links=true` and installs file deps as *copies*.
# The host-side package-lock.json is generated with a newer npm that uses
# symlinks, so an install-as-copy produces a hidden node_modules/.package-lock.json
# that permanently disagrees with the root lock on the @hermes/ink entry.
# That disagreement trips the TUI launcher's `_tui_need_npm_install()`
# check on every startup and triggers a runtime `npm install` that then
# fails with EACCES (node_modules/ is root-owned from build time).
ENV npm_config_install_links=false

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

# ---------- Layer-cached Python dependency install ----------
# Copy only pyproject.toml + uv.lock so the Python dep resolve + wheel
# download + native-extension compile layer is cached unless those inputs
# change.  Before this split the Python install sat after `COPY . .`, so
# every source-only commit re-did ~4-5 min of dep work on cold builds.
#
# README.md is referenced by pyproject.toml's `readme =` field, but it's
# excluded from the build context by .dockerignore's `*.md`.  uv's build
# frontend stats the readme path during dep resolution, so we `touch` an
# empty placeholder — the real README is restored by `COPY . .` below.
#
# `uv sync --frozen --no-install-project --extra all` installs only the
# deps reachable through the composite `[all]` extra (handpicked set
# intended for the production image).  We do NOT use `--all-extras`:
# that would pull in `[rl]` (atroposlib + tinker + torch + wandb from
# git), `[yc-bench]` (another git dep), and `[termux-all]` (Android
# redundancy), none of which belong in the published container.
#
# The editable link is created after the source copy below.
COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
COPY --chown=hermes:hermes . .

# Git wrapper at /usr/local/bin/git (precedes /usr/bin/git on PATH) that
# intercepts `git push` and strips force-push and destructive flags.
RUN cat > /usr/local/bin/git <<'GITWRAPPER' && \
    chmod +x /usr/local/bin/git
#!/bin/bash
# Git wrapper — strips force-push and destructive flags from `git push`.
# All other subcommands pass through unchanged.
REAL_GIT=/usr/bin/git
if [ "${1:-}" != "push" ]; then
    exec "$REAL_GIT" "$@"
fi
shift
args=()
dropped=()
for arg in "$@"; do
    case "$arg" in
        --force|-f|--force-with-lease|--force-with-lease=*|--force-if-includes|--mirror|--delete|-d|--prune)
            dropped+=("$arg") ;;
        +*)
            dropped+=("$arg") ;;
        *:+*)
            dropped+=("$arg") ;;
        *)
            args+=("$arg") ;;
    esac
done
if [ ${#dropped[@]} -gt 0 ]; then
    echo "git-wrapper: stripped forbidden push flags: ${dropped[*]}" >&2
    echo "git-wrapper: if this is intentional, use /usr/bin/git push ... explicitly" >&2
fi
exec "$REAL_GIT" push "${args[@]}"
GITWRAPPER

# hermes-webui (from Yifei's fork), installed into the same Python env as
# hermes so it can import hermes modules directly.
RUN git clone --branch v0.50.23 https://github.com/dingyifei/hermes-webui.git /opt/hermes-webui

# Credential broker client scripts — git-credential-broker + gh wrapper.
# The host-side broker daemon listens on TCP 127.0.0.1:9876; these client
# scripts connect via host.docker.internal:9876 from inside the container.
RUN cat > /usr/local/bin/git-credential-broker <<'GITCREDBROKER' && \
    chmod 755 /usr/local/bin/git-credential-broker
#!/bin/bash
# Git credential helper that vends credentials from the host-side broker.
set -u
op="${1:-}"
if [ "$op" != "get" ]; then
    exit 0
fi
parent_exe=""
if [ -e "/proc/$PPID/exe" ]; then
    parent_exe=$(readlink "/proc/$PPID/exe" 2>/dev/null || echo "")
fi
case "$parent_exe" in
    /usr/bin/dash|/bin/dash|/usr/bin/sh|/bin/sh|/usr/bin/bash|/bin/bash)
        grandparent_pid=$(awk '/^PPid:/{print $2}' "/proc/$PPID/status" 2>/dev/null || echo "")
        if [ -n "$grandparent_pid" ] && [ -e "/proc/$grandparent_pid/exe" ]; then
            parent_exe=$(readlink "/proc/$grandparent_pid/exe" 2>/dev/null || echo "")
        fi
        ;;
esac
case "$parent_exe" in
    /usr/bin/git|/usr/local/bin/git|/usr/libexec/git-core/*|/usr/lib/git-core/*)
        ;;
    *)
        echo "git-credential-broker: refusing — process tree does not contain git ($parent_exe)" >&2
        exit 0
        ;;
esac
protocol=""
host=""
url_path=""
while IFS= read -r line; do
    [ -z "$line" ] && break
    case "$line" in
        protocol=*) protocol="${line#protocol=}" ;;
        host=*)     host="${line#host=}" ;;
        path=*)     url_path="${line#path=}" ;;
    esac
done
if [ "$host" != "github.com" ]; then
    echo "git-credential-broker: refusing — host ($host) is not github.com" >&2
    exit 0
fi
parent_comm=""
if [ -e "/proc/$PPID/comm" ]; then
    parent_comm=$(cat "/proc/$PPID/comm" 2>/dev/null || echo "")
fi
response=$(python3 - "$host" "$url_path" "$PPID" "$parent_exe" "$parent_comm" <<'PYEND'
import json, socket, sys
host, url_path, ppid, parent_exe, parent_comm = sys.argv[1:6]
req = {
    "version": 1, "service": "github",
    "url_host": host, "url_path": url_path,
    "caller_pid": int(ppid),
    "caller_parent_exe": parent_exe,
    "caller_parent_comm": parent_comm,
}
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    s.connect(("host.docker.internal", 9876))
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while b"\n" not in buf and len(buf) < 64 * 1024:
        chunk = s.recv(4096)
        if not chunk: break
        buf += chunk
    print(buf.decode("utf-8").strip())
except Exception as e:
    print(json.dumps({"error": f"broker unreachable: {e}", "token": None}))
PYEND
)
error=$(echo "$response" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('error') or '')" 2>/dev/null)
username=$(echo "$response" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('username') or '')" 2>/dev/null)
token=$(echo "$response" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('token') or '')" 2>/dev/null)
if [ -n "$error" ] || [ -z "$token" ]; then
    echo "git-credential-broker: broker denied or errored: ${error:-no token returned}" >&2
    exit 0
fi
printf 'username=%s\n' "$username"
printf 'password=%s\n' "$token"
GITCREDBROKER

# gh CLI wrapper — shadows /usr/bin/gh. Fetches a token from the broker
# and sets GH_TOKEN for exactly one exec of the real gh.
RUN mkdir -p /usr/local/libexec && \
    mv /usr/bin/gh /usr/local/libexec/gh-real && \
    cat > /usr/local/bin/gh <<'GHWRAPPER' && \
    chmod 755 /usr/local/bin/gh
#!/bin/bash
# gh CLI wrapper — fetches token from the host broker per-invocation.
set -u
REAL_GH="/usr/local/libexec/gh-real"
if [ ! -x "$REAL_GH" ]; then
    echo "gh-wrapper: real gh binary missing at $REAL_GH" >&2
    exit 127
fi
response=$(python3 - <<'PYEND'
import json, socket, os
req = {
    "version": 1, "service": "github-gh",
    "url_host": "github.com", "url_path": None,
    "caller_pid": os.getppid(),
    "caller_parent_exe": os.readlink(f"/proc/{os.getppid()}/exe") if os.path.exists(f"/proc/{os.getppid()}/exe") else "",
    "caller_parent_comm": open(f"/proc/{os.getppid()}/comm").read().strip() if os.path.exists(f"/proc/{os.getppid()}/comm") else "",
}
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    s.connect(("host.docker.internal", 9876))
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while b"\n" not in buf and len(buf) < 64 * 1024:
        chunk = s.recv(4096)
        if not chunk: break
        buf += chunk
    print(buf.decode("utf-8").strip())
except Exception as e:
    print(json.dumps({"error": f"broker unreachable: {e}", "token": None}))
PYEND
)
error=$(echo "$response" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('error') or '')" 2>/dev/null)
token=$(echo "$response" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('token') or '')" 2>/dev/null)
if [ -n "$token" ]; then
    export GH_TOKEN="$token"
elif [ -n "$error" ]; then
    echo "gh-wrapper: broker did not vend: $error" >&2
fi
exec "$REAL_GH" "$@"
GHWRAPPER

# Configure git system-wide to use the credential helper.
RUN git config --system credential.helper /usr/local/bin/git-credential-broker && \
    git config --system credential.useHttpPath true

# Build browser dashboard and terminal UI assets.
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build

# ---------- Permissions ----------
# Make install dir world-readable so any HERMES_UID can read it at runtime.
# The venv needs to be traversable too.
# node_modules trees additionally need to be writable by the hermes user
# so the runtime `npm install` triggered by _tui_need_npm_install() in
# hermes_cli/main.py succeeds (see #18800). /opt/hermes/web is build-time
# only (HERMES_WEB_DIST points at hermes_cli/web_dist) and is intentionally
# not chowned here.
# The .venv MUST be hermes-writable so lazy_deps.py can install platform
# packages (discord.py, telegram, slack, etc.) at first gateway boot.
# Without this, `uv pip install` fails with EACCES and all messaging
# adapters silently fail to load.  See tools/lazy_deps.py.
# /opt/hermes-webui lives outside /opt/hermes; it is read-only at runtime.
USER root
RUN chmod -R a+rX /opt/hermes /opt/hermes-webui && \
    chown -R hermes:hermes /opt/hermes/.venv /opt/hermes/ui-tui /opt/hermes/node_modules
# Start as root so the entrypoint can usermod/groupmod + gosu.
# If HERMES_UID is unset, the entrypoint drops to the default hermes user (10000).

# ---------- Link hermes-agent itself (editable) + webui requirements ----------
# Deps are already installed in the cached layer above; `--no-deps` makes
# this a fast (~1s) egg-link creation with no resolution or downloads.
# The webui requirements install adds discord.py / etc. that webui needs.
RUN uv pip install --no-cache-dir --no-deps -e "." && \
    uv pip install --no-cache-dir -r /opt/hermes-webui/requirements.txt

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:${PATH}"
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]
