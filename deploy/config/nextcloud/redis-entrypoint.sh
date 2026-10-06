#!/bin/sh
set -eu
exec redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"
