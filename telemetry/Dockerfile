# ambisonic-box telemetry: collector + alerter + private dashboard server.
# Multi-arch (amd64 + arm64). Needs only the docker *CLI* (talks to the mounted
# socket) plus curl; no docker engine, no extra python deps (stdlib only).
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli \
 && apt-get purge -y gnupg && apt-get autoremove -y \
 # Take whatever security updates the base image has not picked up yet. The
 # base is rebuilt on its own schedule, so a Debian fix can be published and
 # installable days before it appears in python:*-slim: on 2026-08-21 three
 # util-linux mount(8) CVEs were fixed in 2.41.5-0+deb13u1 while the base
 # still shipped 2.41-5, and `security` went red on a docs-only commit for it.
 # Upgrading here closes that window instead of waiting on the base or waiving
 # the finding. It costs build reproducibility, which is the honest trade: a
 # rebuild picks up whatever is current rather than pinning to a known set.
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Shipped so a RUNNING stack can say what it is. Without this the only answer
# to "which version am I on?" is a git checkout the user may not have - and the
# bug report form asks for exactly that.
COPY VERSION /app/VERSION
COPY collect.py /app/collect.py
COPY web/ /app/web/

EXPOSE 8090
CMD ["python3", "-u", "/app/collect.py"]
