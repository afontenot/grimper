#!/usr/bin/env bash

# Made by Adam Fontenot (github.com/afontenot) 2023.
# License: CC-0. No Rights Reserved.
# No warranty, express or implied, for the use of this script.

set -euo pipefail
IFS=$'\n\t'

check_depends() {
    local notfound=""
    for cmd in curl jq mono; do
        if [[ ! -x "$(command -v "$cmd")" ]]; then
            notfound="$notfound $cmd"
        fi
    done
    if [[ "$notfound" != "" ]]; then
        echo "Missing dependencies: $notfound."
        exit 1
    fi
    local buildtoolsfound="false"
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

    if [[ -L root ]]; then
        CELESTE_ROOT="$(readlink -f root)"
    else
        echo -n "Provide the path to your Celeste installation: "
        read -r CELESTE_ROOT
        if [[ -d "$CELESTE_ROOT" ]]; then
            ln -s "$CELESTE_ROOT" root
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
    mkdir -p mods

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

# recursive function - links mod and all dependencies from mods/ to celeste/Mods/
link_mod() {
    if [[ -e "celeste/Mods/$1" ]]; then
        return
    fi
    if [[ -d "mods/$1" ]]; then
        ln -s "../../mods/$1" "celeste/Mods/$1"
        if [[ -e "mods/$1/everest.yaml" ]]; then
            grep -oP '(?<= - Name: )[^\r\n]+' "mods/$1/everest.yaml" | while read -r modname; do
                link_mod "$modname"
            done
        fi
    fi
}

run_celeste() {
    # clean up old links
    for dir in celeste/Mods/*; do
        if [[ -L "$dir" ]]; then
            rm -r "$dir"
        elif [[ -e "$dir/everest.yaml" || -e "$dir/everest.yml" ]]; then
            # migrate
            mv "$dir" mods/
        fi
    done
    # symlink needed mods from mods dir
    if [[ "$WANTED_MOD" != "" ]]; then
        if [[ -d "mods/$WANTED_MOD" ]]; then
            link_mod "$WANTED_MOD"
        else
            echo "Requested mod $WANTED_MOD is not available."
            exit 1
        fi
    else
        for dir in mods/*; do
            if [[ -d "$dir" ]]; then
                link_mod "$(basename "$dir")"
            fi
        done
    fi
    export EVEREST_SAVEPATH
    ./celeste/Celeste
}

addlinksave() {
    if [[ ! -d "saves/$1" ]]; then
        echo "Adding new save directory for $1"
        mkdir -p "saves/$1/Saves"
        ln -s "$PWD/saves/default/Saves/settings.celeste" "saves/$1/Saves/"
        ln -s "$PWD/saves/default/Saves/modsettings-Everest.celeste" "saves/$1/Saves/"
    fi
}

single() {
    if [[ "$WANTED_MOD" == "" ]]; then
        mapmods=()
        map_i=1
        for mod in $(find mods -maxdepth 2 -type d -name Maps | cut -d '/' -f2 | sort); do
            mapmods+=("$mod")
            # trying to parse even a single line of yaml with Unix tools is a mess:
            #   * first line of file can start with BOM
            #   * the first manifest key is not guaranteed to be `Name`
            #   * we can't match through the end of line because `\r` will be included by GNU grep
            modname=$(grep -oP -m1 '(?<=(?<! - )Name: )[^\r\n]+' "mods/$mod/everest.yaml")
            echo "[$map_i] $modname"
            map_i=$((map_i+1))
        done
        echo -n "Enter index of mod to load: "
        read -r wantedmod_i
        WANTED_MOD="${mapmods[$wantedmod_i-1]}"
    fi

    addlinksave "$WANTED_MOD"
    EVEREST_SAVEPATH="$PWD/saves/$WANTED_MOD/"
}

update_everest() {
    echo "Downloading release information for everest..."
    local version_info=$(curl -s "https://api.github.com/repos/EverestAPI/Everest/releases/latest" | jq ".tag_name,.tarball_url,.target_commitish,.published_at")
    readarray -t info_arr <<< "$version_info"
    local version=$(echo "${info_arr[0]}" | sed -e 's/^"//' -e 's/"$//')
    local tarball=$(echo "${info_arr[1]}" | sed -e 's/^"//' -e 's/"$//')
    local sha1=$(echo "${info_arr[2]}" | sed -e 's/^"//' -e 's/"$//')
    local vdate=$(echo "${info_arr[3]}" | sed -e 's/^"//' -e 's/"$//')

    local old_version="0"
    if [[ -f everest.version ]]; then
        old_version=$(<everest.version)
    fi

    if [[ ! $old_version < $version ]]; then
        echo "Discovered version $version is not newer than old version $old_version."
        exit 0
    else
        local wantsupdate="n"
        echo -n "Everest update is available. $old_version -> $version. Update now (y/N)? "
        read -r wantsupdate
        if [[ "$wantsupdate" != "y" ]]; then
            echo "Update declined, quitting."
            exit 0
        fi
    fi

    echo "Cloning version $version from Github. Commit is $sha1."

    cd everest
    mkdir "everest-$version-$sha1" && cd "everest-$version-$sha1"
    git init -b dev
    git remote add origin "https://github.com/EverestAPI/Everest.git"
    git fetch --depth=1 origin "$sha1"
    git -c advice.detachedHead=false checkout FETCH_HEAD
    git -c advice.detachedHead=false submodule update --init --recursive --depth=1

    echo "Building Everest"

    # set build string
    local internal_vers=${version##*-}
    sed -i "s/VersionString = \"0.0.0-dev\";/VersionString = \"$internal_vers-local-${sha1:0:5}\";/" Celeste.Mod.mm/Mod/Everest/Everest.cs

    # apply a patch to disable downloading the build artifact updates
    if [[ -f ../../everest.diff ]]; then
        patch -p1 < ../../everest.diff
    else
	echo "No Everest patch found, continuing"
    fi

    echo "Building Everest from downloaded source."
    if [[ -x "$(command -v dotnet)" ]]; then
        dotnet publish --nologo --verbosity quiet "/p:Configuration=Release"
    elif [[ -x "$(command -v msbuild)" ]]; then
        msbuild Everest.sln -noLogo -verbosity:quiet -p:Configuration=Release
    fi

    cd ../..

    echo "Removing unnecessary app hosts"
    find everest/everest-"$version"-"$sha1"/MiniInstaller/bin/Release -iname '*osx*' -delete
    find everest/everest-"$version"-"$sha1"/MiniInstaller/bin/Release -iname '*win*' -delete
    find everest/everest-"$version"-"$sha1"/Celeste.Mod.mm/bin/Release -iname '*osx*' -prune -exec rm -r {} +
    find everest/everest-"$version"-"$sha1"/Celeste.Mod.mm/bin/Release -iname '*win*' -prune -exec rm -r {} +
    find everest/everest-"$version"-"$sha1"/Celeste.Mod.mm/bin/Release -iname '*macos*' -delete

    echo "Copying built Everest files to Celeste overlayfs."
    cp -r everest/everest-"$version"-"$sha1"/MiniInstaller/bin/Release/*/publish/* ./celeste
    cp -r everest/everest-"$version"-"$sha1"/Celeste.Mod.mm/bin/Release/*/publish/* ./celeste

    echo "Installing Everest..."
    cd ./celeste

    # FIXME? Everest bundles a runtime now instead of building a CIL image we can run with mono :-(
    # Would love to find a way to disable this behavior
    ./MiniInstaller-linux

    cd ..

    # Tragically, builds are now too large to reasonably keep around by default
    echo "Removing Everest build directory"
    rm -rf everest/everest-"$version"-"$sha1"

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
 * single           :  play a single mod in an isolated save folder
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
            WANTED_MOD="$2"
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
    elif [[ "$arg" == "single" ]]; then
        single
    else
        echo "Unrecognized command $arg."
        err_quit
    fi
done

setup

if [[ ! -f "./celeste/Celeste.Mod.mm.dll" ]]; then
    update_everest
    echo "Run this script again to play Celeste!"
else
    run_celeste
fi
