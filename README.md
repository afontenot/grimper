# Grimper

An advanced set of scripts for configuring and running Everest (the Celeste modding suite) on Linux

## What this is

This is a set of scripts I wrote primarily for myself. They are focused on allowing me to run Everest on my OS in the way that I want. Some of the features this script enables are detailed below:

 * The original Celeste game files are *never* modified, at all. Instead, they are made available in read-only form to Everest, and when modified, the modified files are stored automatically. This is accomplished through an [overlay file system](https://wiki.archlinux.org/title/Overlay_filesystem).

 * All parts of the Everest suite are built from source, rather than downloading prebuilt binaries. Because the Everest built-in updater downloads these build artifacts, the source code is patched during the build to prevent the built in updater from functioning.

 * You can launch Everest with a chosen set of save files, rather than having all your save files together in one enormous list. Even if this feature is not used, save files associated with your mods are *never* stored in the same place as your previously created vanilla save files. (This means that if you want to use your save files with an Everest installation created with these scripts, you will have to copy it over manually.)

 * A Python script for downloading and updating your mods is included. This script achieves *significantly* faster downloads than Everest's built in tools. Checksum verification is performed.

 * Mods installed using these scripts take up about *half* as much space as the same mods installed using Everest. The reason for this is Everest's inefficient use of zip files for mods - the space saved through the use of zip is more than wasted by having to cache extracted versions of the audio banks and mod DLLs. As an additional benefit, mods load faster as a result of faster asset loads, since they're already unzipped.

 * The script configures the system `ulimit` to prevent Everest from crashing when loading large mod packs.

 * Levelsets included by some helper mods for testing purposes can be disabled automatically, making world switching more convenient.

## Who this is for

These scripts assume a modest amount of technical proficiency, e.g. the ability to use a terminal, hunt down potential missing dependencies, and make modifications to the scripts as necessary to suit one's own needs.

Because I wrote these scripts primarily for myself, they don't have the convenient help prompts I would normally add to my programs to aid when problems occur.

Potential users who don't really need the features I mentioned above would be best served by using a different method for installing Everest.

## How do I use it

The two scripts are **play.sh** and **updatemods.py**. Additional configuration files include **everest.diff** and **disabledlevelsets.txt**. Several others will automatically be created by the scripts.

Basic use of the scripts involves placing all these files in a directory of your choice that will serve as the base of the Everest installation. Then, you `cd` to the directory in your terminal, and run `play.sh` to install and configure Everest.

### Data files:

 * `everest.diff` contains changes to the Everest code that will automatically be applied whenever Everest is built. Currently, these changes disable automatic updating inside Everest, and also enable a feature called `WhitelistFullOverride`. This feature allows you to pass Everest a list of mods to run, and have all the others be disabled.

 * `disabledlevelsets.txt` contains the names of *mods* for which included level sets will automatically be removed when those mods are downloaded or updated. Some mods, especially helpers, contain level sets (i.e. "worlds") that can be selected and played after choosing a save file in Celeste. This option will hide them so as to declutter level set selection. One mod (BounceHelper) is included by default.

 * `root.sh` is automatically created by the scripts and stores the user-selected Celeste installation location.

 * `everest.version` stores the latest version of Everest that was installed in order to make automatically updating it easier.

### Scripts:

 * `play.sh` handles everything except downloading mods. To get started, you can simply run the script and everything should happen automatically with prompts as necessary. The script also has several options:

   * `play.sh mount` mounts the overlayfs.

   * `play.sh update` updates Everest.

   * `play.sh single` starts a menu to open Everest with a single modded map, with an isolated save directory for just this one map places in `./saves/`. As a result your mods load faster (because only the required dependencies are loaded), and you never have trouble finding the saves you use with a given map.

   * `play.sh -s <name>` will use a Saves directory located in `./saves/<name>`, instead of the default location `./saves/default`. This is convenient for having grouped collections of save files which you use for different purposes.

   * `play.sh -m <name>` will start Celeste with only the specified mod (and its dependencies) enabled.

 * `updatemods.py` is pretty self-explanatory. There are two basic commands: `download` and `update`. Currently `update` always means update-all, and `download` can be used to update an individual mod. You need to have mounted the overlay directories using `play.sh` before running this script.

## Requirements

You'll need a Linux system (for overlayfs support), a Celeste installation that Everest can use (I've only tested the Itch.io build), common Linux tools like `curl`, the .NET Core runtime (to build Everest), and the Mono runtime (to run the Everest `MiniInstaller.exe`).

The script will attempt to use the Mono build tools (rather than dotnet) as a fallback if they are available, but this hasn't been tested. Official builds of Everest are done with the dotnet tools, so that's what play.sh does too.
