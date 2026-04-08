FROM debian:13.4

# Install system dependencies in one layer, clear APT cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 python3-pip ripgrep ffmpeg gcc python3-dev libffi-dev && \
    rm -rf /var/lib/apt/lists/*

# Local fork additions for Yifei's hermes install on Yifeis-MacBook-Pro-16:
# - claude-code: official Anthropic CLI, used by the bundled `claude-code` skill.
#   TOS-compliant when invoked as `claude -p '...'` (see README-hermes.md).
# - uv: provides `uvx` for ephemeral Python MCP servers (mcp-server-time, mcp-server-fetch).
RUN npm install -g @anthropic-ai/claude-code && \
    pip install --no-cache-dir --break-system-packages uv

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
    chown -R hermes:hermes /opt/hermes && \
    mkdir -p /home/hermes/.cache && \
    chown -R hermes:hermes /home/hermes
USER hermes

ENV HOME=/home/hermes
ENV HERMES_HOME=/opt/data
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/opt/hermes/docker/entrypoint.sh" ]
