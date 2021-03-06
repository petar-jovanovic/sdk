#!/bin/bash

# Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE.md file.

# Build steps
#  - Run immic.
#  - Run servicec.
#  - Build dartino library generators for target platforms (here ia32 and arm).
#  - In the servicec java output directory build libdartino using ndk-build.
#  - Copy/link output files from immic and servicec to the jni and java directories.
#  - Generate a snapshot of your Dart program and add it to you resources dir.

PROJ=github
ANDROID_PROJ=GithubSample

set -ue

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DARTINO_DIR="$(cd "$DIR/../../.." && pwd)"

# TODO(zerny): Support other modes than Release in tools/android_build/jni/Android.mk
TARGET_MODE=Release
TARGET_DIR="$(cd "$DIR/.." && pwd)"
TARGET_GEN_DIR="$TARGET_DIR/generated"
TARGET_PKG_FILE="$TARGET_DIR/.packages"

IMMI_GEN_DIR="$TARGET_GEN_DIR/immi"
SERVICE_GEN_DIR="$TARGET_GEN_DIR/service"

JAVA_DIR=$DIR/$ANDROID_PROJ/app/src/main/java/dartino
JNI_LIBS_DIR=$DIR/$ANDROID_PROJ/app/src/main/jniLibs

DART="$DARTINO_DIR/out/ReleaseIA32/dart"
IMMIC="$DART $DARTINO_DIR/tools/immic/bin/immic.dart"
DARTINO="$DARTINO_DIR/out/ReleaseIA32/dartino"
SERVICEC="$DARTINO x-servicec"

set -x

(cd $DARTINO_DIR; ninja -C out/ReleaseIA32)

# Generate dart service file and other immi files with the compiler.
if [[ $# -eq 0 ]] || [[ "$1" == "immi" ]]; then
    rm -rf "$IMMI_GEN_DIR"
    mkdir -p "$IMMI_GEN_DIR"
    $IMMIC --packages "$TARGET_PKG_FILE" --out "$IMMI_GEN_DIR" "$TARGET_DIR/lib/$PROJ.immi"

    rm -rf "$SERVICE_GEN_DIR"
    mkdir -p "$SERVICE_GEN_DIR"
    $SERVICEC file "$IMMI_GEN_DIR/idl/immi_service.idl" out "$SERVICE_GEN_DIR"

    # TODO(zerny): Change the servicec output directory structure to allow easy
    # referencing from Android Studio.
    mkdir -p $JAVA_DIR
    cp -R $SERVICE_GEN_DIR/java/dartino/*.java $JAVA_DIR/
fi

# Build the native interpreter src for arm and x86.
if [[ $# -eq 0 ]] || [[ "$1" == "dartino" ]]; then
    cd $DARTINO_DIR
    ninja
    ninja -C out/${TARGET_MODE}XARMAndroid dartino_vm_library_generator
    ninja -C out/${TARGET_MODE}IA32Android dartino_vm_library_generator
    mkdir -p out/${TARGET_MODE}XARMAndroid/obj/src/vm/dartino_vm.gen
    mkdir -p out/${TARGET_MODE}IA32Android/obj/src/vm/dartino_vm.gen
    out/${TARGET_MODE}XARMAndroid/dartino_vm_library_generator > \
        out/${TARGET_MODE}XARMAndroid/obj/src/vm/dartino_vm.gen/generated.S
    out/${TARGET_MODE}IA32Android/dartino_vm_library_generator > \
        out/${TARGET_MODE}IA32Android/obj/src/vm/dartino_vm.gen/generated.S

    cd $SERVICE_GEN_DIR/java
    CPUCOUNT=1
    if [[ $(uname) = 'Darwin' ]]; then
        CPUCOUNT=$(sysctl -n hw.logicalcpu_max)
    else
        CPUCOUNT=$(lscpu -p | grep -vc '^#')
    fi
    NDK_MODULE_PATH=. ndk-build -j$CPUCOUNT

    mkdir -p $JNI_LIBS_DIR
    cp -R libs/* $JNI_LIBS_DIR/
fi

if [[ $# -eq 0 ]] || [[ "$1" == "snapshot" ]]; then
    # Kill the persistent process
    cd $DARTINO_DIR

    SNAPSHOT="$DIR/$ANDROID_PROJ/app/src/main/res/raw/${PROJ}_snapshot"
    mkdir -p `dirname "$SNAPSHOT"`
    $DART -c --packages=.packages \
          -Dsnapshot="$SNAPSHOT" \
          -Dpackages="$TARGET_PKG_FILE" \
          tests/dartino_compiler/run.dart "$TARGET_DIR/bin/$PROJ.dart"
fi

set +x

if [[ $# -eq 1 ]]; then
    echo
    echo "Only ran task $1."
    echo "Possible tasks: immi, dartino, and snapshot"
    echo "If Dartino or any IMMI files changed re-run compile.sh without arguments."
fi
