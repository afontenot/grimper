#!/usr/bin/env bash

# Made by Adam Fontenot (github.com/afontenot) 2023.
# License: CC-0. No Rights Reserved.
# No warranty, express or implied, for the use of this script.

set -euo pipefail
IFS=$'\n\t'

check_depends() {
    notfound=""
    for cmd in curl jq mono; do
        if [[ ! -x "$(command -v "$cmd")" ]]; then
            notfound="$notfound $cmd"
        fi
    done
    if [[ "$notfound" != "" ]]; then
        echo "Missing dependencies: $notfound."
        exit 1
    fi
    buildtoolsfound="false"
    for cmd in dotnet msbuild; do
        if [[ -x "$(command -v "$cmd")" ]]; then
            buildtoolsfound="true"
        fi
    done
    if [[ "$buildtoolsfound" == "false" ]]; then
        echo "Missing build tools (either dotnet or msbuild)."
        exit 1
    fi
}

setup() {
    cd "$(dirname "$0")"

    if [[ -f "root.sh" ]]; then
        source root.sh
    else
        echo -n "Provide the path to your Celeste installation: "
        read -r CELESTE_ROOT
        if [[ -d "$CELESTE_ROOT" ]]; then
            echo 'CELESTE_ROOT="'"$CELESTE_ROOT"'"' > root.sh
        else
            echo "Path $CELESTE_ROOT not found or not accessible."
            exit 1
        fi
    fi

    if [[ ! -d "$CELESTE_ROOT" ]]; then
        echo "Celeste root directory not found or not accessible."
        exit 1
    fi

    mkdir -p everest
    mkdir -p celeste
    mkdir -p overlay
    mkdir -p buffer
    mkdir -p saves/default

    # Everest tends to open basically every file in every mod
    # try to avoid running out of open file descriptors
    if (( $(ulimit -n) < 5000 )); then
        ulimit -n 5000
    fi

    # check if the directory is mounted before trying to mount it
    # if it's already mounted we have to trust the user to have done something sane
    set +e
    mountpoint -q ./celeste
    err=$?
    set -e
    if [[ $err -ne 0 ]]; then
        echo "Mounting overlay directory. This prevents Everest from modifying your files."
        echo "Any changes Everest makes will be kept in a separate folder in this directory."
        sudo mount -t overlay overlay -o lowerdir="$CELESTE_ROOT",upperdir=./overlay,workdir=./buffer ./celeste
        sudo chown -R "$USER:$USER" ./celeste # make sure we own the overlay version
    fi
}

run_celeste () {
    export EVEREST_SAVEPATH
    ./celeste/Celeste
}

update_everest() {
    echo "Downloading release information for everest..."
    version_info=$(curl -s "https://api.github.com/repos/EverestAPI/Everest/releases/latest" | jq ".tag_name,.tarball_url,.target_commitish,.published_at")
    readarray -t info_arr <<< "$version_info"
    version=$(echo "${info_arr[0]}" | sed -e 's/^"//' -e 's/"$//')
    tarball=$(echo "${info_arr[1]}" | sed -e 's/^"//' -e 's/"$//')
    sha1=$(echo "${info_arr[2]}" | sed -e 's/^"//' -e 's/"$//')
    vdate=$(echo "${info_arr[3]}" | sed -e 's/^"//' -e 's/"$//')

    old_version="0"
    if [[ -f everest.version ]]; then
        old_version=$(<everest.version)
    fi

    if [[ ! $old_version < $version ]]; then
        echo "Discovered version $version is not newer than old version $old_version."
        exit 0
    else
        wantsupdate="n"
        echo -n "Everest update is available. $old_version -> $version. Update now (y/N)? "
        read -r -n1 wantsupdate
        if [[ "$wantsupdate" != "y" ]]; then
            echo "Update declined, quitting."
            exit 0
        fi
    fi

    echo "Downloading version $version from Github. Hash is $sha1."

    cd everest
    curl -OL "$tarball"

    echo "Extracting Everest"
    tar xf "$version"
    cd EverestAPI-Everest-"${sha1:0:7}"

    echo "Building Everest"

    # set build string
    internal_vers=${version##*-}
    sed -i "s/VersionString = \"0.0.0-dev\";/VersionString = \"$internal_vers-local-${sha1:0:5}\";/" Celeste.Mod.mm/Mod/Everest/Everest.cs

    # apply a patch to disable downloading the build artifact updates
    if [[ -f everest.diff ]]; then
        patch -p1 everest.diff
    fi

    echo "Building Everest from downloaded source."
    if [[ -x "$(command -v dotnet)" ]]; then
        dotnet build --nologo --verbosity quiet "/p:Configuration=Release"
    elif [[ -x "$(command -v msbuild)" ]]; then
        msbuild Everest.sln -noLogo -verbosity:quiet -p:Configuration=Release
    fi

    cd ../..

    echo "Copying built Everest files to Celeste overlayfs."
    cp -r everest/EverestAPI-Everest-"${sha1:0:7}"/MiniInstaller/bin/Release/*/* ./celeste
    cp -r everest/EverestAPI-Everest-"${sha1:0:7}"/Celeste.Mod.mm/bin/Release/*/* ./celeste

    echo "Installing Everest..."
    cd ./celeste
    mono MiniInstaller.exe

    cd ..
    echo "$version" > everest.version
}

err_quit() {
    echo """
Usage: play.sh -s <path> -m <name> [mount|update]
Options:
 * -s | --savepath  :  directory (under ./saves) to put save files in
 * -m | --mod       :  name of a mod to exclusively load (with dependencies)

Parameters:
 * mount            :  mount the overlayfs directory, then quit
 * update           :  update the Everest installation, then quit

Running play.sh with no parameters will launch Celeste.
"""
    exit 1
}

set +e
OPTIONS=$(getopt -o 's:m:' --long 'savepath:,mod:' -n 'play.sh' -- "$@")
if [[ $? -ne 0 ]]; then
    err_quit
fi
set -e

eval set -- "$OPTIONS"
unset OPTIONS

# default options
EVEREST_SAVEPATH="$PWD/saves/default"
WANTED_MOD=""

while true; do
    case "$1" in
        "-s"|"--savepath")
            EVEREST_SAVEPATH="$PWD/saves/$2"
            shift 2
            continue
        ;;
        "-m"|"--mod")
            WANTED_MOD="2"
            shift 2
            continue
        ;;
        "--")
            shift
            break
        ;;
        *)
            echo "Internal error in getopt."
            exit 1
        ;;
    esac
done

for arg; do
    if [[ "$arg" == "mount" ]]; then
        setup
        exit 0
    elif [[ "$arg" == "update" ]]; then
        check_depends
        setup
        update_everest
        exit 0
    else
        echo "Unrecognized command $arg."
        err_quit
    fi
done

setup
run_celeste
