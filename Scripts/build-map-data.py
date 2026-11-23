#!/usr/bin/env python3
"""Builds the map data Lamp ships for slides: the places, the land, lakes and
rivers, and the shaded relief.

Sources, both free and both read from local copies, never fetched here:

- OpenBible.info Bible Geocoding Data, CC BY 4.0
  (github.com/openbibleinfo/Bible-Geocoding-Data). Its `data/ancient.jsonl`
  and `data/modern.jsonl`. A coordinate copied from OpenStreetMap (ODbL) or
  from Google is never used: the place takes its next identification, or is
  left out. Where OpenBible gives an independently made `custom_lonlat` for a
  coordinate from a commercial source, that is used instead.
- Natural Earth, public domain (naturalearthdata.com). `ne_50m_*` and
  `ne_10m_*` land, lakes and rivers_lake_centerlines, and the `SR_50M` shaded
  relief. Reservoirs and canals are left out, since they are modern.

Usage:

    python3 build-map-data.py OPENBIBLE_REPO NATURAL_EARTH_DIR SR_50M_TIF PYLIB

where NATURAL_EARTH_DIR holds one folder per layer as Natural Earth unzips
them (`ne_10m_land/ne_10m_land.shp`), and PYLIB is a folder with shapely and
pyshp installed (`pip install --target PYLIB shapely pyshp`). It writes into
the core package's resource folders, beside this script's.

The output is deterministic, so a rebuild from the same sources changes
nothing.
"""

import json
import os
import struct
import subprocess
import sys

OPENBIBLE, NATURAL_EARTH, RELIEF, PYLIB = sys.argv[1:5]
sys.path.insert(0, PYLIB)

import shapefile  # noqa: E402
from shapely import clip_by_rect, unary_union  # noqa: E402
from shapely.geometry import box, shape  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.dirname(HERE)
PLACES_OUT = os.path.join(CORE, "Sources", "LampCore", "Resources", "Maps")
DRAWING_OUT = os.path.join(CORE, "Sources", "LampPresentationUI", "Resources", "Maps")

# The whole area a map can show: Europe and Russia to the Pacific, North
# Africa, the Near East, Persia and Arabia, the reach of the places prophecy
# names. Drawn at 10m, and at 50m for a view too wide to need 10m's detail.
WHOLE = (-25.0, 10.0, 180.0, 75.0)

# Coordinates in thousandths of a degree.
UNIT = 1000

# Never used: OpenStreetMap's licence (ODbL) asks for a share-alike database,
# and Google's terms forbid copying.
EXCLUDED_SOURCES = {"osm", "google_maps", "google_earth", "google_books"}

# OpenBible's place types, as a map draws them: a point with its name, an
# area's name set wide, water's in italic, and high ground with a mark.
KINDS = {
    "settlement": "point", "campsite": "point", "gate": "point", "structure": "point",
    "spring": "point", "well": "point", "altar": "point", "pool": "point", "tree": "point",
    "district in settlement": "point", "field": "point", "garden": "point", "island": "point",
    "region": "region", "natural area": "region", "people group": "region", "valley": "region",
    "river": "water", "wadi": "water", "body of water": "water",
    "mountain": "mountain", "mountain range": "mountain", "hill": "mountain",
}


def lonlat(text):
    lon, lat = (float(part) for part in text.split(","))
    return lon, lat


def places():
    modern = {}
    with open(os.path.join(OPENBIBLE, "data", "modern.jsonl"), encoding="utf-8") as file:
        for line in file:
            record = json.loads(line)
            modern[record["id"]] = record

    def usable(modern_id):
        record = modern.get(modern_id)
        if record is None:
            return None
        if record.get("custom_lonlat"):
            return lonlat(record["custom_lonlat"])
        source = (record.get("coordinates_source") or {}).get("type")
        if source in EXCLUDED_SOURCES or not record.get("lonlat"):
            return None
        return lonlat(record["lonlat"])

    rows = []
    left_out = 0
    with open(os.path.join(OPENBIBLE, "data", "ancient.jsonl"), encoding="utf-8") as file:
        for line in file:
            place = json.loads(line)
            kinds = [KINDS[t] for t in place.get("types", []) if t in KINDS]
            if not kinds or not place.get("verses"):
                continue
            # The likeliest site first, by OpenBible's own score: the
            # identification's share of scholarly confidence times how
            # surely it resolves to this spot.
            ranked = sorted(
                place.get("modern_associations", {}).items(),
                key=lambda item: (-item[1]["score"], item[0]),
            )
            chosen = None
            for modern_id, association in ranked:
                point = usable(modern_id)
                if point is not None:
                    chosen = (point, association["score"])
                    break
            if chosen is None:
                left_out += 1
                continue
            (lon, lat), score = chosen
            name = place["friendly_id"]
            # Other names the English Bibles use for it, as written there,
            # leaving out the people named for it ("Galileans").
            others = sorted(
                other for other in place.get("translation_name_counts", {})
                if other != name and not other.lower().endswith(("ites", "ians", "eans", "ans"))
            )
            first = min(place["verses"], key=lambda verse: verse["sort"])
            rows.append([
                place["id"], name, others,
                round(lon, 4), round(lat, 4),
                # OpenBible's scores can run a little past 0 and 1000;
                # held to them, so a share is never under nothing or over
                # all of it.
                min(max(int(score), 0), 1000), kinds[0], first["readable"],
            ])
    rows.sort(key=lambda row: (row[1].lower(), row[0]))
    return rows, left_out


def write_places():
    rows, left_out = places()
    os.makedirs(PLACES_OUT, exist_ok=True)
    document = {
        "source": "OpenBible.info Bible Geocoding Data, CC BY 4.0",
        "fields": ["id", "name", "otherNames", "longitude", "latitude", "confidence", "kind", "firstVerse"],
        "places": rows,
    }
    path = os.path.join(PLACES_OUT, "places.json")
    with open(path, "w", encoding="utf-8") as file:
        json.dump(document, file, ensure_ascii=False, separators=(",", ":"))
        file.write("\n")
    print(f"places: {len(rows)} written, {left_out} left out with no usable location; {os.path.getsize(path):,} bytes")


def read_layer(scale, layer, bounds, drop):
    base = f"ne_{scale}_{layer}"
    reader = shapefile.Reader(os.path.join(NATURAL_EARTH, base, base + ".shp"), encoding="utf-8")
    fields = [field[0] for field in reader.fields[1:]]
    area = box(*bounds)
    geometries = []
    for item in reader.iterShapeRecords():
        if item.shape.shapeType == 0:
            continue
        record = dict(zip(fields, item.record))
        if str(record.get("featurecla", "")).strip().lower() in drop:
            continue
        geometry = shape(item.shape.__geo_interface__)
        if geometry.geom_type.endswith("Polygon") and not geometry.is_valid:
            geometry = geometry.buffer(0)
        if geometry.is_empty or not geometry.intersects(area):
            continue
        clipped = clip_by_rect(geometry, *bounds)
        if not clipped.is_empty:
            geometries.append(clipped)
    return geometries


def parts(geometry):
    kind = geometry.geom_type
    if kind == "Polygon":
        return [list(geometry.exterior.coords)] + [list(ring.coords) for ring in geometry.interiors]
    if kind == "LineString":
        return [list(geometry.coords)]
    if kind.startswith("Multi") or kind == "GeometryCollection":
        return [part for piece in geometry.geoms for part in parts(piece)]
    return []


def zigzag(value):
    return (value << 1) ^ (value >> 63)


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def encode(rings):
    """Rings as `LampMapShapes` reads them: a count of rings, then for each
    a count of points and each point as the change from the last, in
    thousandths of a degree, zigzag varints."""
    out = bytearray(varint(len(rings)))
    for ring in rings:
        out += varint(len(ring))
        last = (0, 0)
        for lon, lat in ring:
            out += varint(zigzag(lon - last[0])) + varint(zigzag(lat - last[1]))
            last = (lon, lat)
    return bytes(out)


def quantised(ring, closed):
    points = []
    for lon, lat in ring:
        point = (round(lon * UNIT), round(lat * UNIT))
        if not points or points[-1] != point:
            points.append(point)
    if closed and len(points) > 1 and points[0] == points[-1]:
        points.pop()
    return points if len(points) >= (3 if closed else 2) else None


def write_shapes():
    os.makedirs(DRAWING_OUT, exist_ok=True)
    for scale, bounds in (("50m", WHOLE), ("10m", WHOLE)):
        for layer, closed, drop in (
            ("land", True, set()),
            ("lakes", True, {"reservoir"}),
            ("rivers_lake_centerlines", False, {"canal"}),
        ):
            geometries = read_layer(scale, layer, bounds, drop)
            if closed:
                # One shape, so the pieces Natural Earth cuts land into
                # leave no seams where they meet.
                geometries = [unary_union(geometries)]
            rings = [
                points for geometry in geometries for ring in parts(geometry)
                if (points := quantised(ring, closed))
            ]
            name = "rivers" if layer.startswith("rivers") else layer
            path = os.path.join(DRAWING_OUT, f"{name}-{scale}.bin")
            with open(path, "wb") as file:
                file.write(encode(rings))
            print(f"{name}-{scale}: {len(rings)} parts, {sum(map(len, rings)):,} points, {os.path.getsize(path):,} bytes")


def write_relief():
    """The whole area's shaded relief, cut from SR_50M (30 pixels a degree,
    from 180°W and 90°N), as a grey JPEG."""
    pixels = 30
    x = round((WHOLE[0] + 180) * pixels)
    y = round((90 - WHOLE[3]) * pixels)
    width = round((WHOLE[2] - WHOLE[0]) * pixels)
    height = round((WHOLE[3] - WHOLE[1]) * pixels)
    path = os.path.join(DRAWING_OUT, "relief.jpg")
    subprocess.run(
        ["sips", "--cropOffset", str(y), str(x), "-c", str(height), str(width),
         "-s", "format", "jpeg", "-s", "formatOptions", "70", RELIEF, "--out", path],
        check=True, stdout=subprocess.DEVNULL,
    )
    print(f"relief: {width}x{height}, {os.path.getsize(path):,} bytes")


def write_bounds():
    document = {
        "unit": UNIT,
        "bounds": WHOLE,
        "relief": {"bounds": WHOLE, "pixelsPerDegree": 30},
        "credit": "Natural Earth (public domain)",
    }
    with open(os.path.join(DRAWING_OUT, "maps.json"), "w", encoding="utf-8") as file:
        json.dump(document, file, separators=(",", ":"))
        file.write("\n")


def natural_earth_version(layer):
    path = os.path.join(NATURAL_EARTH, layer, layer + ".VERSION.txt")
    with open(path, encoding="utf-8") as file:
        return file.read().strip()


def write_notice():
    """The sources, their versions, what was changed, and the licence, for
    the apps' third-party notices to carry."""
    commit = subprocess.run(
        ["git", "-C", OPENBIBLE, "log", "-1", "--format=%H"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    with open(os.path.join(OPENBIBLE, "license.txt"), encoding="utf-8") as file:
        licence = file.read().strip()
    versions = ", ".join(
        f"{layer} {natural_earth_version(layer)}"
        for layer in ("ne_10m_land", "ne_10m_lakes", "ne_10m_rivers_lake_centerlines",
                      "ne_50m_land", "ne_50m_lakes", "ne_50m_rivers_lake_centerlines")
    )
    relief_version_path = os.path.splitext(RELIEF)[0] + ".VERSION.txt"
    with open(relief_version_path, encoding="utf-8") as file:
        relief_version = file.read().strip()
    text = f"""Bible maps: places and land

PLACES
OpenBible.info Bible Geocoding Data
https://github.com/openbibleinfo/Bible-Geocoding-Data, commit {commit}
Licensed under the Creative Commons Attribution 4.0 International licence, below.
Credit: OpenBible.info.

Changes made by Lamp Bible: for each place named in the Bible, only its name,
other names, likeliest location, the confidence in that location, its kind, and
the first verse naming it are kept, in places.json. A location whose coordinates
OpenBible.info took from OpenStreetMap or from Google is not used; the place takes
its next identification, or is left out. Where OpenBible.info gives an
independently made coordinate for one from a commercial source, that is used.

LAND, WATER AND RELIEF
Natural Earth, https://www.naturalearthdata.com
Public domain: "No permission is needed to use Natural Earth. Crediting the
authors is unnecessary." Made with Natural Earth.
Layers: {versions}; SR_50M shaded relief {relief_version}.
Changes made by Lamp Bible: cut to 25°W–180°E, 10°N–75°N; reservoirs and canals
left out; coordinates rounded to a thousandth of a degree.

{licence}
"""
    with open(os.path.join(PLACES_OUT, "NOTICE.txt"), "w", encoding="utf-8") as file:
        file.write(text)
    print("notice written")


write_places()
write_shapes()
write_relief()
write_bounds()
write_notice()
