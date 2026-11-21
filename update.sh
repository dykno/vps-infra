#!/bin/sh
# Pull newer images and restart onto them, but only if nginx accepts the config.
set -eu
cd "$(dirname "$0")"

docker compose pull --quiet
docker compose run --rm --no-deps nginx nginx -t
docker compose up -d
docker image prune -f
