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
