#!/usr/bin/env bash

# This script executes the Wasm Rego test cases. The script uses Docker to run
# the test generation program and then again to run the test cases inside of a
# Node JS container. The script caches the test generation program build
# results in the $PWD/.go directory so that it can be re-used across runs. The
# volumes from the test generation container are shared with the Node JS
# container to avoid copying the generated test cases more than necessary.

set -ex

GOVERSION=${GOVERSION:?"You must set the GOVERSION environment variable."}
DOCKER_UID=${DOCKER_UID:-$(id -u)}
DOCKER_GID=${DOCKER_GID:-$(id -g)}
ASSETS=${ASSETS:-"$PWD/test/wasm/assets"}
VERBOSE=${VERBOSE:-"0"}
TESTGEN_CONTAINER_NAME="opa-wasm-testgen-container"
TESTRUN_CONTAINER_NAME="opa-wasm-testrun-container"
ARCH=$(arch)
NODE_IMAGE="node:14"
if [ $ARCH = "s390x" ]; then
    NODE_IMAGE="node:14-bullseye"
fi

function main {
    trap interrupt SIGINT SIGTERM
    mkdir -p $PWD/.go/cache/go-build
    mkdir -p $PWD/.go/bin
    generate_testcases
    run_testcases
}

function interrupt {
    echo "caught interrupt: exiting"
    purge_testgen_container
    purge_testrun_container
    exit 1
}

function purge_testgen_container {
    docker kill $TESTGEN_CONTAINER_NAME >/dev/null 2>&1 || true
    docker rm $TESTGEN_CONTAINER_NAME >/dev/null 2>&1 || true
}

function purge_testrun_container {
    docker kill $TESTRUN_CONTAINER_NAME >/dev/null 2>&1 || true
    docker rm $TESTRUN_CONTAINER_NAME >/dev/null 2>&1 || true
}

function generate_testcases {
    purge_testgen_container
    docker run \
        --name $TESTGEN_CONTAINER_NAME \
        -u $DOCKER_UID:$DOCKER_GID \
        -v $PWD/.go/bin:/go/bin:Z \
        -v $PWD:/src:z \
        -v $ASSETS:/assets:Z \
        -e GOCACHE=/src/.go/cache \
        -w /src \
        golang:$GOVERSION \
        sh -c 'git config --global --add safe.directory /src && make wasm-rego-testgen-install \
                && wasm-rego-testgen \
                --input-dir=/assets \
                --runner=/src/test/wasm/assets/test.js \
                --output=/src/.go/cache/testcases.tar.gz'
}

function run_testcases {
    # NOTE(tsandall): background the container because the interrupt trap does
    # not run otherwise.
    purge_testrun_container
    docker run \
        --rm \
        --name $TESTRUN_CONTAINER_NAME \
        --volumes-from $TESTGEN_CONTAINER_NAME:z \
        -e VERBOSE=$VERBOSE \
        -w /scratch \
        $NODE_IMAGE \
        sh -c 'tar xzf \
            /src/.go/cache/testcases.tar.gz \
            && node test.js opa.wasm' &
    wait $!
}

main
