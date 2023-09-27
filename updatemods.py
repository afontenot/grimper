#!/usr/bin/env python3
import argparse
import re
from functools import partial
from pathlib import Path
from shutil import rmtree
from time import time
from urllib.parse import urlparse
from zipfile import ZipFile

import requests
from packaging import version
from xxhash import xxh64
from yaml import load as _loadyaml


# configure a safe yaml loader dynamically
try:
    from yaml import CSafeLoader as YamlLoader
except ImportError:
    from yaml import SafeLoader as YamlLoader

loadyaml = partial(_loadyaml, Loader=YamlLoader)


# constants
BUF_SIZE = 64 * 1024
UPDATE_LOCATION_URL = "https://everestapi.github.io/modupdater.txt"
MIRROR_URL = "https://celestemodupdater.0x0a.de/banana-mirror/%d.zip"


class RequestDownloader:
    def __init__(self, callback=None):
        self._session = requests.Session()
        self._last_printer_update = time()
        if callback is None:
            self._callback = self.default_printer
        else:
            self._callback = callback

    def default_printer(self, dl_name, byte_count, total_bytes):
        title = ""
        if dl_name:
            title = f"[{dl_name}] "
        percentage = ""
        if total_bytes:
            percentage = f" ({round(100*byte_count/total_bytes)}%)"
        if total_bytes < 1e3:
            print(f"\r{title}{byte_count}{percentage}", end="")
        elif total_bytes < 1e6:
            print(f"\r{title}{byte_count//1e3} KB{percentage}", end="")
        else:
            print(f"\r{title}{byte_count//1e6} MB{percentage}", end="")

    def download(self, url, dl_name=None, output_filepath=None, total_bytes=None):
        backup_output_filepath = None
        if output_filepath is None:
            path_parts = url.split("://", 1)[1].split("/")
            if len(path_parts) > 1:
                backup_output_filepath = path_parts[-1]
        byte_count = 0
        with self._session.get(url, stream=True) as req:
            req.raise_for_status()
            if output_filepath is None:
                cd_header = req.headers.get("Content-Disposition")
                if cd_header is not None:
                    if "filename" in cd_header:
                        fname = re.findall(
                            r"filename\*?=([^;]+)", cd_header, flags=re.IGNORECASE
                        )
                        output_filepath = fname[0].strip().strip('"')
                if not output_filepath:
                    if backup_output_filepath is None:
                        raise ValueError(f"No valid filepath provided for {url}.")
                    output_filepath = backup_output_filepath
            if total_bytes is None:
                cl_header = req.headers.get("Content-Length")
                if cl_header is not None:
                    total_bytes = int(cl_header)
            with open(output_filepath, "wb", buffering=0) as of:
                with memoryview(bytearray(BUF_SIZE)) as mv:
                    while True:
                        num_bytes = req.raw.readinto(mv)
                        if not num_bytes:
                            self._callback(dl_name, byte_count, total_bytes)
                            print("")
                            break
                        elif num_bytes < BUF_SIZE:
                            with mv[:num_bytes] as smv:
                                of.write(smv)
                        else:
                            of.write(mv)
                        byte_count += num_bytes
                        self._callback(dl_name, byte_count, total_bytes)


def get_id_from_url(url):
    lastseg = urlparse(url).path.split("/")[-1]
    if lastseg.isdigit():
        return int(lastseg)
    return None


def get_mod_yaml(loc):
    yamlpath = loc / "everest.yaml"
    if not yamlpath.exists():
        yamlpath = loc / "everest.yml"
        if not yamlpath.exists():
            return None
    with yamlpath.open() as f:
        yaml = loadyaml(f)
        # we can only handle one mod per folder
        assert len(yaml) == 1
        yaml = yaml[0]

    return yaml


def xxhsum(f):
    buf = bytearray(2**18)
    view = memoryview(buf)
    hash = xxh64()
    while True:
        size = f.readinto(buf)
        if size == 0:
            break
        hash.update(view[:size])

    return hash.hexdigest()


class ModUpdater:
    def __init__(self):
        self.dlr = RequestDownloader()
        self.__cached_update_by_modname = dict()
        self.__cached_update_by_gbid = dict()
        try:
            with open("disabledlevelsets.txt") as f:
                self.__disabled_levelsets = set([line.strip() for line in f])
        except FileNotFoundError:
            self.__disabled_levelsets = set()

    def _download_update(self):
        print("Getting update URL from server...")
        with requests.get(UPDATE_LOCATION_URL) as req:
            req.raise_for_status()
            update_url = req.text.strip()
        print("Got update URL, fetching update data...")
        with requests.get(update_url, stream=True) as req:
            req.raise_for_status()
            resp = req.text
        print("Got update data, parsing yaml...")
        self.__cached_update_by_modname = loadyaml(resp)
        for modname, data in self.__cached_update_by_modname.items():
            data["Name"] = modname
            if gbid := data.get("GameBananaId"):
                if gbid not in self.__cached_update_by_gbid:
                    self.__cached_update_by_gbid[gbid] = data

    def update_data_for_mod(self, modname):
        if not self.__cached_update_by_modname:
            self._download_update()
        return self.__cached_update_by_modname.get(modname)

    def update_data_for_gbid(self, gbid):
        if not self.__cached_update_by_gbid:
            self._download_update()
        return self.__cached_update_by_gbid.get(gbid)

    def update_mod(self, modname, save_path, moddata):
        urls = [
            moddata["MirrorURL"],
            moddata["URL"],
        ]

        # FIXME: rare cases (Collab-2018-10) have multiple hashes; why?
        xxhash = moddata.get("xxHash")
        if xxhash:
            assert len(xxhash) == 1
            xxhash = xxhash[0]

        size = moddata.get("Size")

        filepath = save_path.joinpath(f"{modname}.zip")
        for url in urls:
            try:
                self.dlr.download(url, modname, filepath, size)
                break
            except requests.HTTPError:
                continue
            print(f"Could not download file {modname} from {urls}!")
            return False

        if not filepath.exists():
            print(f"Could not find downloaded file {filepath}")
            return False

        if xxhash:
            with open(filepath, "rb") as f:
                if not xxhsum(f) == xxhash:
                    print(f"Downloaded file did not match hash for {filepath}!")
                    return False
        else:
            print(f"Warning: no hash available for {filepath}!")

        dirpath = save_path.joinpath(f"{modname}")
        if not dirpath.is_dir():
            print(f"Note: {modname} has no existing version.")
        else:
            # print(f"Removing previous version of {modname}...")
            rmtree(dirpath)

        dirpath.mkdir()
        with ZipFile(filepath) as zf:
            zf.extractall(dirpath)

        # users can selectively disable levelsets included in some helpers
        if modname in self.__disabled_levelsets:
            print(f"Disabling levelsets for {modname}...")
            mappath = dirpath.joinpath("Maps")
            targetpath = dirpath.joinpath("_Maps")
            if mappath.is_dir():
                if not targetpath.is_dir():
                    mappath.rename(targetpath)
                else:
                    print(
                        f"Warning: {mappath} would be moved but target directory exists!"
                    )

        filepath.unlink()
        return True

    def update(self, location):
        print("Parsing existing mods")
        mods = {}
        for loc in filter(lambda x: x.is_dir(), Path(location).glob("*")):
            yaml = get_mod_yaml(loc)
            if not yaml:
                continue
            mods[yaml["Name"]] = {
                "path": loc,
                "dependencies": yaml["Dependencies"],
                "version": yaml["Version"],
            }
        wanted = set(mods.keys())
        wanted |= set(
            [dep["Name"] for mod in mods.values() for dep in mod["dependencies"]]
        )
        have = {"Everest", "Celeste"}
        wanted -= have

        print("Updating mods...")
        while wanted:
            modname = wanted.pop()
            moddata = self.update_data_for_mod(modname)
            have.add(modname)
            needs_download = False

            if modname not in mods:
                needs_download = True
            elif moddata:
                current_version = version.parse(mods[modname]["version"])
                server_version = version.parse(moddata["Version"])
                if server_version > current_version:
                    needs_download = True

            if needs_download:
                if not moddata:
                    print(f"Could not find update data for {modname}!")
                    break
                result = self.update_mod(modname, location, moddata)
                if not result:
                    break
                yaml = get_mod_yaml(location / modname)
                if not yaml:
                    print(f"Could not find manifest for downloaded mod {modname}!")
                    break
                for depmod in yaml["Dependencies"]:
                    depmodname = depmod["Name"]
                    if depmodname not in have and depmodname not in wanted:
                        print(f"{modname} has new dependency {depmodname}")
                        wanted.add(depmodname)

    def download(self, location, identifier):
        moddata = None
        if identifier.isdigit():
            moddata = self.update_data_for_gbid(int(identifier))
        elif identifier.startswith("https://gamebanana.com"):
            mod_id = get_id_from_url(identifier)
            if mod_id:
                moddata = self.update_data_for_gbid(mod_id)
                # try to download file directly when it's not on the mirrors yet
                if not moddata and "dl/" in identifier:
                    print("File not in database, attempting direct download.")
                    moddata = {
                        "Name": "fake_mod_download",
                        "MirrorURL": MIRROR_URL % mod_id,
                        "URL": identifier,
                    }
                    result = self.update_mod("fake_mod_download", location, moddata)
                    mod_location = location / "fake_mod_download"
                    if result and mod_location.is_dir():
                        yaml = get_mod_yaml(mod_location)
                        real_modname = yaml["Name"]
                        mod_location.replace(location / real_modname)
                        print("Mod installed. Run an update to pull in any dependencies.")
                    return
        else:
            moddata = self.update_data_for_mod(identifier)

        if moddata:
            modname = moddata["Name"]
            if self.update_mod(modname, location, moddata):
                print("Mod installed. Run an update to pull in any dependencies.")

        else:
            print(f"Could not identify mod {identifier}!")


def main():
    parser = argparse.ArgumentParser(
        prog="Everest Mod Updater",
        description="Download, update, and extract mods for Everest",
    )
    parser.add_argument(
        "-l",
        help="specify the location of your mods",
        default="celeste/Mods",
        metavar="celeste/Mods",
        type=Path,
    )
    subparsers = parser.add_subparsers(
        title="Mode", help="Set the program mode to use.", required=True, dest="command"
    )

    download_parser = subparsers.add_parser("download", help="download a new mod")
    download_parser.add_argument(
        "identifier", help="Mod name, or GamaBanana URL / identifier"
    )

    subparsers.add_parser("update", help="update mods")

    args = parser.parse_args()

    # argument validation
    if not args.l.is_dir():
        print(f"{args.l} could not be found or opened.")
        return

    app = ModUpdater()
    if args.command == "update":
        app.update(args.l)
    elif args.command == "download":
        app.download(args.l, args.identifier)


if __name__ == "__main__":
    main()
