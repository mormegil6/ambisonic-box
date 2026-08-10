# ambisonic-box telemetry: collector + alerter + private dashboard server.
# Multi-arch (amd64 + arm64). Needs only the docker *CLI* (talks to the mounted
# socket) plus curl; no docker engine, no extra python deps (stdlib only).
FROM python:3.14-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli \
 && apt-get purge -y gnupg && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY collect.py /app/collect.py
COPY web/ /app/web/

EXPOSE 8090
CMD ["python3", "-u", "/app/collect.py"]
