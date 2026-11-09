#!/usr/bin/env bash
# compose-file.sh — sourced: the compose file names `docker compose` looks for, in Docker's own order, so every
# script reads the file Docker runs. shim/docker keeps its own copy because it must load no other file.

COMPOSE_FILE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)

compose_file() { # <project-root> — prints the name of the first one present there; returns 1 when none is
  local name
  for name in "${COMPOSE_FILE_NAMES[@]}"; do
    if [ -f "$1/$name" ]; then echo "$name"; return 0; fi
  done
  return 1
}
