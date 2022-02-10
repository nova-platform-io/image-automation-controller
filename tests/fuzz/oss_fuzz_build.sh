#!/usr/bin/env bash

# Copyright 2022 The Flux authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euxo pipefail

LIBGIT2_TAG="${LIBGIT2_TAG:-libgit2-1.1.1-7}"
GOPATH="${GOPATH:-/root/go}"
GO_SRC="${GOPATH}/src"
PROJECT_PATH="github.com/fluxcd/image-automation-controller"

cd "${GO_SRC}"

pushd "${PROJECT_PATH}"

export TARGET_DIR="$(/bin/pwd)/build/libgit2/${LIBGIT2_TAG}"

# For most cases, libgit2 will already be present.
# The exception being at the oss-fuzz integration.
if [ ! -d "${TARGET_DIR}" ]; then
    curl -o output.tar.gz -LO "https://github.com/fluxcd/golang-with-libgit2/releases/download/${LIBGIT2_TAG}/linux-$(uname -m)-libs.tar.gz"

    DIR=libgit2-linux
    NEW_DIR="$(/bin/pwd)/build/libgit2/${LIBGIT2_TAG}"
    INSTALLED_DIR="/home/runner/work/golang-with-libgit2/golang-with-libgit2/build/${DIR}"

    mkdir -p ./build/libgit2

    tar -xf output.tar.gz
    rm output.tar.gz
    mv "${DIR}" "${LIBGIT2_TAG}"
    mv "${LIBGIT2_TAG}/" "./build/libgit2"

    # Update the prefix paths included in the .pc files.
    # This will make it easier to update to the location in which they will be used.
    find "${NEW_DIR}" -type f -name "*.pc" | xargs -I {} sed -i "s;${INSTALLED_DIR};${NEW_DIR};g" {}
fi

apt-get update && apt-get install -y pkg-config

export TARGET_DIR="$(/bin/pwd)/build/libgit2/${LIBGIT2_TAG}"
export CGO_ENABLED=1
export LIBRARY_PATH="${TARGET_DIR}/lib:${TARGET_DIR}/lib64"
export PKG_CONFIG_PATH="${TARGET_DIR}/lib/pkgconfig:${TARGET_DIR}/lib64/pkgconfig"
export CGO_CFLAGS="-I${TARGET_DIR}/include -I${TARGET_DIR}/include/openssl"
export CGO_LDFLAGS="$(pkg-config --libs --static --cflags libssh2 openssl libgit2)"

go mod tidy -compat=1.17

popd

pushd "${PROJECT_PATH}/tests/fuzz"

# Version of the source-controller from which to get the GitRepository CRD.
# Change this if you bump the source-controller/api version in go.mod.
SOURCE_VER=v0.21.1

# Version of the image-reflector-controller from which to get the ImagePolicy CRD.
# Change this if you bump the image-reflector-controller/api version in go.mod.
REFLECTOR_VER=v0.16.0

# Setup files to be embedded into controllers_fuzzer.go's testFiles variable.
mkdir -p testdata/crds
cp ../../config/crd/bases/*.yaml testdata/crds/

if [ -d "../../controllers/testdata/crds" ]; then
    cp ../../controllers/testdata/crds/*.yaml testdata/crds
# Fetch the CRDs if not present since we need them when running fuzz tests on CI.
else
    curl -s --fail https://raw.githubusercontent.com/fluxcd/source-controller/${SOURCE_VER}/config/crd/bases/source.toolkit.fluxcd.io_gitrepositories.yaml -o testdata/crds/gitrepositories.yaml

    curl -s --fail https://raw.githubusercontent.com/fluxcd/image-reflector-controller/${REFLECTOR_VER}/config/crd/bases/image.toolkit.fluxcd.io_imagepolicies.yaml -o testdata/crds/imagepolicies.yaml
fi

go mod tidy -compat=1.17

# ref: https://github.com/google/oss-fuzz/blob/master/infra/base-images/base-builder/compile_go_fuzzer
go-fuzz -tags gofuzz -func=FuzzImageUpdateReconciler -o fuzz_image_update_reconciler.a .
clang -o /out/fuzz_image_update_reconciler \
    fuzz_image_update_reconciler.a \
    "${TARGET_DIR}/lib/libgit2.a" \
    "${TARGET_DIR}/lib/libssh2.a" \
    "${TARGET_DIR}/lib/libz.a" \
    "${TARGET_DIR}/lib64/libssl.a" \
    "${TARGET_DIR}/lib64/libcrypto.a" \
    -fsanitize=fuzzer

go-fuzz -tags gofuzz -func=FuzzUpdateWithSetters -o fuzz_update_with_setters.a .
clang -o /out/fuzz_update_with_setters \
    fuzz_update_with_setters.a \
    "${TARGET_DIR}/lib/libgit2.a" \
    "${TARGET_DIR}/lib/libssh2.a" \
    "${TARGET_DIR}/lib/libz.a" \
    "${TARGET_DIR}/lib64/libssl.a" \
    "${TARGET_DIR}/lib64/libcrypto.a" \
    -fsanitize=fuzzer

popd
