#!/usr/bin/env bash

# Made by Adam Fontenot (github.com/afontenot) 2023.
# License: CC-0. No Rights Reserved.
# No warranty, express or implied, for the use of this script.

set -euo pipefail
IFS=$'\n\t'

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

run_celeste () {
    if [[ $# -gt 0 ]]; then
        EVEREST_SAVEPATH="$(pwd)/saves/$1" ./celeste/Celeste
    else
        EVEREST_SAVEPATH="$(pwd)/saves/default" ./celeste/Celeste
    fi
}

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
    sudo mount -t overlay overlay -o lowerdir=$CELESTE_ROOT,upperdir=./overlay,workdir=./buffer ./celeste
    sudo chown -R $USER:$USER ./celeste # make sure we own the overlay version
fi

echo "Downloading release information for everest..."
version_info=$(curl -s "https://api.github.com/repos/EverestAPI/Everest/releases/latest" | jq ".tag_name,.tarball_url,.target_commitish,.published_at")
readarray -t info_arr <<< "$version_info"
version=$(echo ${info_arr[0]} | sed -e 's/^"//' -e 's/"$//')
tarball=$(echo ${info_arr[1]} | sed -e 's/^"//' -e 's/"$//')
sha1=$(echo ${info_arr[2]} | sed -e 's/^"//' -e 's/"$//')
vdate=$(echo ${info_arr[3]} | sed -e 's/^"//' -e 's/"$//')

if [[ -f everest.version ]]; then
    old_version=$(<everest.version)
fi

if [[ $# -eq 0 || $1 != "update" ]]; then
    if [[ -f "./celeste/Celeste.Mod.mm.dll" ]]; then
        wantsupdate="n"
        if [[ $old_version < $version ]]; then
            echo -n "Everest update is available. $old_version -> $version. Update now (y/N)? "
            read -r -n1 wantsupdate
        fi
        if [[ "$wantsupdate" != "y" ]]; then
            echo "Launching Celeste..."
            run_celeste "$@"
            exit 0
        fi
    fi
fi

if [[ ! $old_version < $version ]]; then
    echo "Discovered version $version is not newer than old version $old_version."
    exit 0
fi

echo "Downloading version $version from Github. Hash is $sha1."

cd everest
curl -OL "$tarball"

echo "Extracting Everest"
tar xf $version
cd EverestAPI-Everest-${sha1:0:7}

echo "Building Everest"

# set build string
internal_vers=${version##*-}
sed -i "s/VersionString = \"0.0.0-dev\";/VersionString = \"$internal_vers-local-${sha1:0:5}\";/" Celeste.Mod.mm/Mod/Everest/Everest.cs

# apply a patch to disable downloading the build artifact updates
if [[ -f everest.diff ]]; then
    patch -p1 everest.diff
fi

echo "Building Everest from downloaded source."
dotnet build --nologo --verbosity quiet "/p:Configuration=Release"
cd ../..

echo "Copying built Everest files to Celeste overlayfs."
cp -r everest/EverestAPI-Everest-${sha1:0:7}/MiniInstaller/bin/Release/*/* ./celeste
cp -r everest/EverestAPI-Everest-${sha1:0:7}/Celeste.Mod.mm/bin/Release/*/* ./celeste

echo "Installing Everest..."
cd ./celeste
mono MiniInstaller.exe

cd ..
echo $version > everest.version

echo -n "Installation complete. Do you want to start Celeste now (Y/n)? "
read -r -n1 shouldstart
if [[ "$shouldstart" != "n" ]]; then
    echo "Launching Celeste..."
    run_celeste "$@"
    exit 0
fi
