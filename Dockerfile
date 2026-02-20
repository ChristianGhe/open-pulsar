FROM node:20-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash jq git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

WORKDIR /workspace

COPY agent-loop.sh /usr/local/bin/agent-loop
RUN chmod +x /usr/local/bin/agent-loop

ENTRYPOINT ["agent-loop"]
