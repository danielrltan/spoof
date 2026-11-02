"""Talks to iPhones for Spoof on Macs without Xcode.

Spoof starts this once and sends one JSON object per line on stdin; each gets one JSON object
back on stdout, carrying the same "id". Location goes through the phone's own CoreDevice location
service, the one devicectl uses, so a fake outlives the connection, including a route in progress.
"""

import asyncio
import json
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.core_device.location_service import LocationService
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3 import usbmux

FEATURE = "com.apple.coredevice.feature.simulatelocation"
ACTION = "com.apple.coredevice.action."
MOUNT_SECONDS = 25  # a locked phone never answers, so don't wait for it


class Locked(Exception):
    pass


class Phone:
    """One phone's tunnel, kept open so repeated commands stay quick."""

    def __init__(self, udid):
        self.udid = udid
        self.tunnel = None
        self.rsd = None
        self.mounted = False

    async def open(self):
        if self.rsd is None:
            self.tunnel = UserspaceRsdTunnel(serial=self.udid)
            self.rsd = await self.tunnel.aopen()
        if not self.mounted:
            try:
                await asyncio.wait_for(auto_mount(self.rsd), MOUNT_SECONDS)
            except asyncio.TimeoutError:
                raise Locked from None
            self.mounted = True
        return self.rsd

    async def close(self):
        tunnel, self.tunnel, self.rsd = self.tunnel, None, None
        if tunnel is not None:
            try:
                await tunnel.aclose()
            except Exception:
                pass

    async def invoke(self, action, payload):
        for attempt in (1, 2):
            try:
                async with LocationService(await self.open()) as service:
                    return await service.invoke(FEATURE, payload, action_identifier=ACTION + action)
            except Locked:
                raise
            except Exception:
                await self.close()
                if attempt == 2:
                    raise


phones = {}
names = {}


def phone(udid):
    return phones.setdefault(udid, Phone(udid))


async def describe(device):
    """One entry of the phone list. Only asks the phone again while something's wrong."""
    udid = device.serial
    known = names.get(udid)
    entry = {"udid": udid, "name": (known or {}).get("name", "iPhone"), "wired": device.is_usb, "issue": None}
    if known and known.get("issue") is None:
        return entry
    try:
        lockdown = await asyncio.wait_for(create_using_usbmux(serial=udid, autopair=False), 6)
    except Exception:
        return entry
    try:
        entry["name"] = await lockdown.get_value(key="DeviceName") or entry["name"]
    except Exception:
        pass
    if not lockdown.paired:
        entry["issue"] = "trust"
        try:
            await asyncio.wait_for(lockdown.pair(), 3)  # shows the Trust prompt
        except Exception:
            pass
    elif not await lockdown.get_developer_mode_status():
        entry["issue"] = "developerMode"
        try:
            await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
        except Exception:
            pass
    names[udid] = {"name": entry["name"], "issue": entry["issue"]}
    return entry


async def scan():
    seen = {}
    for device in await usbmux.list_devices():
        if device.serial not in seen or device.is_usb:
            seen[device.serial] = device
    return [await describe(d) for d in seen.values()]


async def handle(request):
    op = request["op"]
    if op == "scan":
        return {"phones": await scan()}
    target = phone(request["udid"])
    if op == "set":
        await target.invoke("setsimulatedlocation", {"latitude": float(request["lat"]), "longitude": float(request["lon"])})
    elif op == "route":
        await target.invoke("startlocationsimulation", {
            "waypoints": [{"latitude": float(a), "longitude": float(b)} for a, b in request["points"]],
            "speed": float(request["speed"]),
            "pacing": {"interval": {"_0": 1.0}},
        })
    elif op == "clear":
        await target.invoke("clearsimulatedlocation", {})
    else:
        raise ValueError(f"unknown op {op}")
    return {}


async def main():
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    while line := await reader.readline():
        request = json.loads(line)
        reply = {"id": request.get("id"), "ok": True}
        try:
            reply.update(await handle(request))
        except Locked:
            reply.update(ok=False, error="Unlock your iPhone, then try again.")
        except Exception as error:
            reply.update(ok=False, error=str(error) or type(error).__name__)
        print(json.dumps(reply), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
