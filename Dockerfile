FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash jq git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://claude.ai/install.sh | bash

ENV PATH="/root/.local/bin:${PATH}"
ENV DISABLE_AUTOUPDATER=1

WORKDIR /workspace

COPY agent-loop.sh /usr/local/bin/agent-loop
RUN chmod +x /usr/local/bin/agent-loop

ENTRYPOINT ["agent-loop"]
