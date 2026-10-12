"""Free iPhone GPS spoofer: teleport, unlimited routes, any speed.

Talks to the phone through pymobiledevice3's tunneld (iOS 17+) and Apple's
developer LocationSimulation service. Serves a map UI on http://127.0.0.1:8765.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import math
import random
import time
import urllib.parse
import subprocess
from pathlib import Path
from typing import List, Optional, Tuple

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.tunneld.api import get_tunneld_devices

HOST, PORT = "127.0.0.1", 8765
TICK_SECONDS = 1.0
# Faster speeds update more often so each step stays small (up to 10 updates/sec)
MIN_TICK_SECONDS = 0.1
MAX_STEP_M = 10.0
EARTH_RADIUS_M = 6371008.8
ROUTERS = {
    "foot": "https://routing.openstreetmap.de/routed-foot/route/v1/driving/",
    "bike": "https://routing.openstreetmap.de/routed-bike/route/v1/driving/",
    "car": "https://routing.openstreetmap.de/routed-car/route/v1/driving/",
}

LatLon = Tuple[float, float]


def haversine(a: LatLon, b: LatLon) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


def jitter(p: LatLon, meters: float) -> LatLon:
    if meters <= 0:
        return p
    dlat = random.uniform(-meters, meters) / 111320
    dlon = random.uniform(-meters, meters) / (111320 * max(math.cos(math.radians(p[0])), 1e-6))
    return p[0] + dlat, p[1] + dlon


class Device:
    """One long-lived LocationSimulation channel, reconnected on failure."""

    def __init__(self) -> None:
        self._stack: Optional[contextlib.AsyncExitStack] = None
        self._loc: Optional[LocationSimulation] = None
        self._lock = asyncio.Lock()
        self.name: Optional[str] = None
        self.error: Optional[str] = None

    @property
    def connected(self) -> bool:
        return self._loc is not None

    async def connect(self) -> None:
        async with self._lock:
            await self._close()
            try:
                rsds = await get_tunneld_devices()
            except Exception as e:  # noqa: BLE001
                self.error = f"tunneld not reachable - run start.sh (it starts tunneld with sudo). ({e})"
                raise HTTPException(503, self.error)
            if not rsds:
                self.error = "No iPhone found. Plug it in / unlock it, trust this Mac, enable Developer Mode."
                raise HTTPException(404, self.error)
            rsd, extras = rsds[0], rsds[1:]
            for other in extras:
                with contextlib.suppress(Exception):
                    await other.close()
            stack = contextlib.AsyncExitStack()
            try:
                dvt = await stack.enter_async_context(DvtProvider(rsd))
                self._loc = await stack.enter_async_context(LocationSimulation(dvt))
            except Exception as e:  # noqa: BLE001
                await stack.aclose()
                with contextlib.suppress(Exception):
                    await rsd.close()
                self.error = f"Could not open location service (is the Developer Disk Image mounted?): {e!r}"
                raise HTTPException(500, self.error)
            stack.push_async_callback(rsd.close)
            self._stack = stack
            self.name = f"{getattr(rsd, 'product_type', 'iPhone')} ({getattr(rsd, 'udid', '?')})"
            self.error = None

    async def _close(self) -> None:
        self._loc = None
        if self._stack is not None:
            with contextlib.suppress(Exception):
                await self._stack.aclose()
            self._stack = None

    async def set(self, p: LatLon) -> None:
        for attempt in range(2):
            if not self.connected:
                await self.connect()
            try:
                async with self._lock:
                    await self._loc.set(p[0], p[1])  # type: ignore[union-attr]
                return
            except Exception as e:  # noqa: BLE001
                self.error = f"set failed: {e!r}"
                async with self._lock:
                    await self._close()
                if attempt:
                    raise HTTPException(500, self.error)

    async def clear(self) -> None:
        if self.connected:
            async with self._lock:
                with contextlib.suppress(Exception):
                    await self._loc.clear()  # type: ignore[union-attr]
                await self._close()


class Mover:
    """Walks a polyline at a live-adjustable speed, pushing positions to the phone."""

    def __init__(self, device: Device) -> None:
        self.device = device
        self.position: Optional[LatLon] = None
        self.route: List[LatLon] = []
        self._cum: List[float] = []
        self.travelled = 0.0
        self.speed_mps = 5 / 3.6
        self.jitter_m = 0.0
        self.loop = False
        self.paused = False
        self._task: Optional[asyncio.Task] = None
        self.stick: Tuple[float, float] = (0.0, 0.0)  # (east, north), each -1..1
        self._stick_task: Optional[asyncio.Task] = None
        self.error: Optional[str] = None

    @property
    def moving(self) -> bool:
        return self._task is not None and not self._task.done()

    @property
    def joystick(self) -> bool:
        return self._stick_task is not None and not self._stick_task.done()

    def _tick(self, speed_mps: float) -> float:
        if speed_mps <= 0:
            return TICK_SECONDS
        return min(TICK_SECONDS, max(MIN_TICK_SECONDS, MAX_STEP_M / speed_mps))

    async def set_stick(self, east: float, north: float) -> None:
        mag = math.hypot(east, north)
        if mag > 1:
            east, north = east / mag, north / mag
        self.stick = (east, north)
        if (east or north) and not self.joystick:
            if self.position is None:
                raise HTTPException(400, "Teleport somewhere first, then use the joystick")
            if self.moving:
                await self.stop()
            self.error = None
            self._stick_task = asyncio.create_task(self._run_stick())

    async def _run_stick(self) -> None:
        last = time.monotonic()
        try:
            while True:
                east, north = self.stick
                await asyncio.sleep(self._tick(self.speed_mps * math.hypot(east, north)) if (east or north) else 0.1)
                now = time.monotonic()
                dt, last = now - last, now
                east, north = self.stick
                if not (east or north) or self.position is None:
                    continue
                step = self.speed_mps * dt
                lat, lon = self.position
                lat += north * step / 111320
                lon += east * step / (111320 * max(math.cos(math.radians(lat)), 1e-6))
                lat = max(-89.9, min(89.9, lat))
                lon = (lon + 180) % 360 - 180
                await self.device.set(jitter((lat, lon), self.jitter_m))
                self.position = (lat, lon)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            self.error = getattr(e, "detail", None) or repr(e)

    @property
    def total(self) -> float:
        return self._cum[-1] if self._cum else 0.0

    def point_at(self, d: float) -> LatLon:
        r, cum = self.route, self._cum
        if d <= 0:
            return r[0]
        if d >= cum[-1]:
            return r[-1]
        lo, hi = 0, len(cum) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if cum[mid] <= d:
                lo = mid
            else:
                hi = mid
        seg = cum[hi] - cum[lo]
        t = (d - cum[lo]) / seg if seg else 0.0
        a, b = r[lo], r[hi]
        return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t

    async def teleport(self, p: LatLon) -> None:
        await self.stop()
        await self.device.set(p)
        self.position = p

    async def start(self, route: List[LatLon]) -> None:
        await self.stop()
        pts = [route[0]]
        for p in route[1:]:
            if p != pts[-1]:
                pts.append(p)
        if len(pts) < 2:
            raise HTTPException(400, "Route needs at least 2 different points")
        self.route = pts
        self._cum = [0.0]
        for a, b in zip(pts, pts[1:]):
            self._cum.append(self._cum[-1] + haversine(a, b))
        self.travelled = 0.0
        self.paused = False
        self.error = None
        await self.device.set(pts[0])
        self.position = pts[0]
        self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        last = time.monotonic()
        try:
            while True:
                await asyncio.sleep(self._tick(self.speed_mps))
                now = time.monotonic()
                dt, last = now - last, now
                if self.paused:
                    continue
                self.travelled += self.speed_mps * dt
                if self.travelled >= self.total:
                    if self.loop:
                        self.travelled %= self.total
                    else:
                        self.travelled = self.total
                p = self.point_at(self.travelled)
                await self.device.set(jitter(p, self.jitter_m))
                self.position = p
                if self.travelled >= self.total and not self.loop:
                    return
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            self.error = getattr(e, "detail", None) or repr(e)

    async def stop(self) -> None:
        for task in (self._task, self._stick_task):
            if task is not None:
                task.cancel()
                with contextlib.suppress(BaseException):
                    await task
        self._task = self._stick_task = None
        self.stick = (0.0, 0.0)
        self.paused = False


device = Device()
mover = Mover(device)
app = FastAPI()
STATIC = Path(__file__).with_name("index.html")


class Point(BaseModel):
    lat: float
    lon: float


class RouteReq(BaseModel):
    points: List[List[float]]
    speed_kmh: Optional[float] = None
    loop: bool = False
    jitter_m: float = 0.0


class RoadReq(BaseModel):
    points: List[List[float]]
    profile: str = "foot"


class Stick(BaseModel):
    east: float
    north: float


class Settings(BaseModel):
    speed_kmh: Optional[float] = None
    loop: Optional[bool] = None
    jitter_m: Optional[float] = None
    paused: Optional[bool] = None


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC)


@app.get("/api/status")
async def status() -> dict:
    remaining = max(mover.total - mover.travelled, 0.0) if mover.moving else 0.0
    return {
        "connected": device.connected,
        "device": device.name,
        "error": mover.error or device.error,
        "position": mover.position,
        "moving": mover.moving,
        "paused": mover.paused,
        "joystick": mover.joystick,
        "speed_kmh": round(mover.speed_mps * 3.6, 3),
        "loop": mover.loop,
        "jitter_m": mover.jitter_m,
        "travelled_m": mover.travelled if mover.moving else 0.0,
        "total_m": mover.total if mover.moving else 0.0,
        "eta_s": remaining / mover.speed_mps if mover.speed_mps > 0 else None,
    }


@app.post("/api/connect")
async def connect() -> dict:
    await device.connect()
    return await status()


@app.post("/api/teleport")
async def teleport(p: Point) -> dict:
    await mover.teleport((p.lat, p.lon))
    return await status()


@app.post("/api/route")
async def route(req: RouteReq) -> dict:
    if req.speed_kmh is not None:
        mover.speed_mps = max(req.speed_kmh, 0.0) / 3.6
    mover.loop, mover.jitter_m = req.loop, max(req.jitter_m, 0.0)
    await mover.start([(p[0], p[1]) for p in req.points])
    return await status()


@app.post("/api/settings")
async def settings(s: Settings) -> dict:
    if s.speed_kmh is not None:
        mover.speed_mps = max(s.speed_kmh, 0.0) / 3.6
    if s.loop is not None:
        mover.loop = s.loop
    if s.jitter_m is not None:
        mover.jitter_m = max(s.jitter_m, 0.0)
    if s.paused is not None:
        mover.paused = s.paused
    return await status()


@app.post("/api/joystick")
async def joystick(s: Stick) -> dict:
    await mover.set_stick(s.east, s.north)
    return await status()


@app.post("/api/stop")
async def stop() -> dict:
    await mover.stop()
    return await status()


@app.post("/api/clear")
async def clear() -> dict:
    await mover.stop()
    await device.clear()
    mover.position = None
    return await status()


def _fetch_road(points: List[List[float]], profile: str) -> List[List[float]]:
    base = ROUTERS.get(profile, ROUTERS["foot"])
    coords = ";".join(f"{lon:.6f},{lat:.6f}" for lat, lon in points)
    url = base + urllib.parse.quote(coords, safe=",;.-") + "?overview=full&geometries=geojson"
    # curl, not urllib: macOS system Python's LibreSSL fails the TLS handshake with this server
    out = subprocess.run(
        ["curl", "-sS", "-m", "20", "-A", "free-spoofer/1.0 (personal use)", url],
        capture_output=True, text=True, check=True,
    ).stdout
    data = json.loads(out)
    if data.get("code") != "Ok" or not data.get("routes"):
        raise ValueError(data.get("message") or data.get("code") or "no route")
    return [[lat, lon] for lon, lat in data["routes"][0]["geometry"]["coordinates"]]


@app.post("/api/road")
async def road(req: RoadReq) -> dict:
    if len(req.points) < 2:
        return {"points": req.points}
    try:
        pts = await asyncio.to_thread(_fetch_road, req.points, req.profile)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"Road routing failed: {e}")
    return {"points": pts}


if __name__ == "__main__":
    print(f"Open http://{HOST}:{PORT}")
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
