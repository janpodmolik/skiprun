#!/usr/bin/env python3
"""Connected physical iOS devices from `xcrun devicectl list devices --json-output -` on stdin.

Prints one "identifier<TAB>name" line per device that is physical and connected.
"""
import json
import sys


def main():
    devices = json.load(sys.stdin).get("result", {}).get("devices", [])
    for device in devices:
        hardware = device.get("hardwareProperties", {})
        connection = device.get("connectionProperties", {})
        if hardware.get("reality") != "physical" or connection.get("tunnelState") != "connected":
            continue
        name = device.get("deviceProperties", {}).get("name") or hardware.get("marketingName") or device["identifier"]
        print(f"{device['identifier']}\t{name}")


if __name__ == "__main__":
    main()
