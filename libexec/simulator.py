#!/usr/bin/env python3
"""Pick a simulator from `xcrun simctl list devices -j` on stdin; prints "udid<TAB>name".

  simulator.py booted            the first booted device
  simulator.py find <name|udid>  an available device by exact name or udid
  simulator.py default <sdk>     the first available iPhone of the runtime matching
                                 the given SDK version (e.g. 26.5), else of the newest
"""
import json
import re
import sys


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)", identifier)
    return tuple(int(part) for part in match.groups()) if match else (0, 0)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "booted"
    devices = json.load(sys.stdin).get("devices", {})
    runtimes = sorted(devices, key=runtime_version, reverse=True)
    if mode == "booted":
        for runtime in runtimes:
            for device in devices[runtime]:
                if device.get("state") == "Booted":
                    return device["udid"], device["name"]
        return None
    if mode == "find":
        wanted = sys.argv[2]
        for runtime in runtimes:
            for device in devices[runtime]:
                if device.get("isAvailable", True) and wanted in (device["name"], device["udid"]):
                    return device["udid"], device["name"]
        return None
    if mode == "default":
        sdk = tuple(int(part) for part in sys.argv[2].split(".")[:2]) if len(sys.argv) > 2 and sys.argv[2] else None
        ordered = [r for r in runtimes if runtime_version(r) == sdk] + [r for r in runtimes if runtime_version(r) != sdk]
        for runtime in ordered:
            for device in devices[runtime]:
                if device.get("isAvailable", True) and device["name"].startswith("iPhone"):
                    return device["udid"], device["name"]
        return None
    sys.exit(f"unknown mode {mode}")


if __name__ == "__main__":
    result = main()
    if result:
        print(f"{result[0]}\t{result[1]}")
