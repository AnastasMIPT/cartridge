#!/bin/bash

mkdir -p ./dev
TARANTOOL_ALIAS=srv-1 TARANTOOL_WORKDIR=dev/3301 TARANTOOL_ADVERTISE_URI=localhost:3301 TARANTOOL_HTTP_PORT=8081 ./test/integration/instance.lua & echo $! >> ./dev/pids
TARANTOOL_ALIAS=srv-2 TARANTOOL_WORKDIR=dev/3302 TARANTOOL_ADVERTISE_URI=localhost:3302 TARANTOOL_HTTP_PORT=8082 ./test/integration/instance.lua & echo $! >> ./dev/pids
TARANTOOL_ALIAS=srv-3 TARANTOOL_WORKDIR=dev/3303 TARANTOOL_ADVERTISE_URI=localhost:3303 TARANTOOL_HTTP_PORT=8083 ./test/integration/instance.lua & echo $! >> ./dev/pids
TARANTOOL_ALIAS=srv-4 TARANTOOL_WORKDIR=dev/3304 TARANTOOL_ADVERTISE_URI=localhost:3304 TARANTOOL_HTTP_PORT=8084 ./test/integration/instance.lua & echo $! >> ./dev/pids
TARANTOOL_ALIAS=srv-5 TARANTOOL_WORKDIR=dev/3305 TARANTOOL_ADVERTISE_URI=localhost:3305 TARANTOOL_HTTP_PORT=8085 ./test/integration/instance.lua & echo $! >> ./dev/pids
sleep 1.5
echo "All instances started!"
