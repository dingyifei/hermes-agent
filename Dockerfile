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

ENV HERMES_HOME=/opt/data
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/opt/hermes/docker/entrypoint.sh" ]
