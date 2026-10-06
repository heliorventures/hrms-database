"""Explicit, workbook-bound location assignments; never infer an office from other fields."""
from datetime import date
import json
import re


def validate_locations(locations):
    if not isinstance(locations, dict):
        raise ValueError("Location assignments must be a source-reference object")
    for key, value in locations.items():
        if not isinstance(key, str) or not re.fullmatch(r".+:[1-9]\d*", key):
            raise ValueError("Location mappings require sheet:row source references")
        if not isinstance(value, dict) or set(value) != {"name", "effective_from"}:
            raise ValueError("Each location requires a name and an explicit effective_from date")
        name, effective = value["name"], value["effective_from"]
        if (not isinstance(name, str) or not name.strip() or len(" ".join(name.split())) > 200
                or any(ord(character) < 32 or ord(character) == 127 for character in name)):
            raise ValueError("Location names must contain 1 to 200 printable characters")
        if not isinstance(effective, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", effective):
            raise ValueError("Location effective dates must be explicit ISO dates")
        date.fromisoformat(effective)


def load_location_map(path, workbook, tenant_code):
    if path is None:
        return {}
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Location mapping exceeds the supported size")

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Location mapping contains duplicate JSON keys")
            result[key] = value
        return result

    with path.open(encoding="utf-8-sig") as source:
        mapping = json.load(source, object_pairs_hook=unique_object)
    if not isinstance(mapping, dict) or set(mapping) != {"source_hash", "tenant_code", "locations"}:
        raise ValueError("Location mapping requires source_hash, tenant_code and locations")
    if mapping["source_hash"] != workbook.file_hash or mapping["tenant_code"] != tenant_code.strip():
        raise ValueError("Location mapping does not match the selected workbook and tenant")
    validate_locations(mapping["locations"])
    return mapping["locations"]


def mapped_location(row, locations, used):
    key = f"{row.sheet.name}:{row.row}"
    value = locations.get(key)
    if value is None:
        row.issue("LOCATION_NOT_SUPPLIED", "DEFER_SECTION", "location", "location",
                  "No reviewed location mapping was supplied; preserve the existing assignment.")
        return None
    used.add(key)
    return {"name": " ".join(value["name"].split()), "effective_from": value["effective_from"]}
