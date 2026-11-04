#!/bin/sh
# Starts ByteStash as the unprivileged "node" user.
#
# When the container is started as root (the default), hand the data volume to
# "node" first: volumes created by older images, which ran the app as root, are
# owned by root. Then drop privileges with su-exec. When the container is
# already started as another user (docker run --user, Kubernetes runAsUser,
# ci/docker-compose.ci.yaml), run the command as that user unchanged.
set -e

DATA_DIR=/data/snippets

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DATA_DIR"
  if [ "$(stat -c %u "$DATA_DIR")" != "$(id -u node)" ]; then
    chown -R node:node "$DATA_DIR" || echo "bytestash: could not chown $DATA_DIR; it must be writable by uid $(id -u node)" >&2
  fi
  exec su-exec node "$@"
fi

exec "$@"
