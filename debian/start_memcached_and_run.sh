#!/bin/sh
# start_memcached_and_run.sh - start a memcached instance, inspired fromruby-mysql2
# It is in turn inspired by
# debian/test_mysql.sh from libdbi-drivers source package.

set -e

MEMCACHED_USER=nobody

# Start memcached
/usr/bin/memcached -u ${MEMCACHED_USER} &
PID=$!

"$@"

cleanup() {
	# Stop memcached
	kill -9 $PID
}
trap cleanup EXIT INT TERM ALRM
