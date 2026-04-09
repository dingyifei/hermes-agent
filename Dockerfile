FROM debian:13.4

# Install system dependencies in one layer, clear APT cache.
# git + ca-certificates + gnupg + curl are needed for gh's apt repo setup.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 python3-pip ripgrep ffmpeg gcc python3-dev libffi-dev \
        git ca-certificates gnupg curl && \
    rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) — add the official apt repo and install. Follows the
# GitHub-documented install steps. Used by the agent via the terminal tool
# for private-repo workflows (gh repo clone, gh pr create, etc.).
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Local fork additions for Yifei's hermes install on Yifeis-MacBook-Pro-16:
# - claude-code: official Anthropic CLI, used by the bundled `claude-code` skill.
#   TOS-compliant when invoked as `claude -p '...'` (see README-hermes.md).
# - uv: provides `uvx` for ephemeral Python MCP servers (mcp-server-time, mcp-server-fetch).
RUN npm install -g @anthropic-ai/claude-code && \
    pip install --no-cache-dir --break-system-packages uv

# Git wrapper at /usr/local/bin/git (precedes /usr/bin/git on PATH) that
# intercepts `git push` and strips force-push and destructive flags. Defends
# against accidental force-push by the agent; the real git is still at
# /usr/bin/git for explicit human use. Combine with server-side branch
# protection on critical repos for actual security.
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
# hermes so it can import hermes modules directly. It has minimal Python deps
# (only pyyaml + stdlib); the agent functionality all comes from the hermes
# install. Runs as a sibling service in docker-compose.
RUN git clone https://github.com/dingyifei/hermes-webui.git /opt/hermes-webui && \
    pip install --no-cache-dir --break-system-packages -r /opt/hermes-webui/requirements.txt

# =============================================================================
# Credential broker client scripts (batch 3)
# =============================================================================
# The hermes credential broker lives on the Mac host as a launchd agent.
# Its Unix socket is bind-mounted into the container at /run/broker/broker.sock
# (see docker-compose.yml.template). These client-side scripts forward
# requests to the broker and never touch the real token on their own.
#
# Installed as root-owned (755) into /usr/local/bin so the hermes user can
# execute but not modify. The real gh binary is moved out of the way so our
# wrapper can shadow it on PATH.

# Git credential helper — called by git when it needs HTTPS credentials.
# Does a parent-exe check via /proc/$PPID/exe (kernel-maintained, not
# spoofable via argv[0] or renaming a script). Forwards the url_host/url_path
# from git's kv input to the broker.
RUN cat > /usr/local/bin/git-credential-broker <<'GITCREDBROKER' && \
    chmod 755 /usr/local/bin/git-credential-broker
#!/bin/bash
# Git credential helper that vends credentials from the host-side broker.
# See macos-setups/Yifeis-MacBook-Pro-16/hermes-broker/git-credential-broker
# for the source of truth; this heredoc is kept in sync with that file.
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
    /usr/bin/git|/usr/local/bin/git|/usr/libexec/git-core/*)
        ;;
    *)
        echo "git-credential-broker: refusing — parent exe ($parent_exe) is not git" >&2
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

# gh CLI wrapper — shadows /usr/bin/gh on PATH. Fetches a token from the
# broker and sets GH_TOKEN for exactly one exec of the real gh (now at
# /usr/local/libexec/gh-real). The real gh must be moved out of /usr/bin
# before the wrapper is installed so PATH resolution finds ours first.
RUN mkdir -p /usr/local/libexec && \
    mv /usr/bin/gh /usr/local/libexec/gh-real && \
    cat > /usr/local/bin/gh <<'GHWRAPPER' && \
    chmod 755 /usr/local/bin/gh
#!/bin/bash
# gh CLI wrapper — fetches token from the host broker per-invocation.
# See macos-setups/Yifeis-MacBook-Pro-16/hermes-broker/gh-wrapper for source.
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

# Configure git system-wide to use the credential helper for all users.
# This survives the USER hermes switch below — system config is read by
# any user running git.
RUN git config --system credential.helper /usr/local/bin/git-credential-broker

COPY . /opt/hermes
WORKDIR /opt/hermes

# Install Python and Node dependencies in one layer, no cache
RUN pip install --no-cache-dir -e ".[all]" --break-system-packages && \
    npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    cd /opt/hermes/scripts/whatsapp-bridge && \
    npm install --prefer-offline --no-audit && \
    npm cache clean --force

WORKDIR /opt/hermes
RUN chmod +x /opt/hermes/docker/entrypoint.sh

# Run as a non-root user. claude-code refuses --dangerously-skip-permissions
# (and the equivalent --permission-mode bypassPermissions) when running as
# root, which makes claude unusable from the agent's terminal tool inside the
# container without weaker per-tool flags. A dedicated `hermes` user (uid 1000)
# fixes that and is good practice in general. /opt/hermes is chowned so the
# entrypoint can read the install tree and bundled skills/configs.
RUN useradd -m -u 1000 -s /bin/bash hermes && \
    chown -R hermes:hermes /opt/hermes /opt/hermes-webui && \
    mkdir -p /home/hermes/.cache && \
    chown -R hermes:hermes /home/hermes
USER hermes

ENV HOME=/home/hermes
ENV HERMES_HOME=/opt/data
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/opt/hermes/docker/entrypoint.sh" ]
