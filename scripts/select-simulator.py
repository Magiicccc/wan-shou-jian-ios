import json
import re
import sys


def choose_simulator(payload):
    candidates = []
    for runtime, devices in payload.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        if version[0] < 17:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append((version, device["name"], device["udid"]))
    return max(candidates)[2] if candidates else ""


if __name__ == "__main__":
    print(choose_simulator(json.load(sys.stdin)))
