"""Bounded, read-only XLSX XML reader; formulas are never executed."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import posixpath
import re
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile
from scripts.reusable.imports.shared_formula import translate


MAIN = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_XML_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_CELLS = 200000


@dataclass(frozen=True)
class Cell:
    raw: str
    kind: str
    formula: str | None = None


@dataclass(frozen=True)
class SheetRows:
    name: str
    rows: dict[int, dict[str, Cell]]


@dataclass(frozen=True)
class WorkbookRows:
    file_label: str
    file_hash: str
    date1904: bool
    sheets: dict[str, SheetRows]


def _xml(archive, member):
    try:
        info = archive.getinfo(member)
    except KeyError as error:
        raise ValueError("Workbook is missing a required XML part") from error
    if info.file_size > MAX_XML_BYTES:
        raise ValueError("Workbook XML exceeds the conversion limit")
    data = archive.read(info)
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Workbook XML entity declarations are not supported")
    try:
        return ET.fromstring(data)
    except ET.ParseError as error:
        raise ValueError("Workbook contains invalid XML") from error


def _text_runs(item):
    chunks = []
    for node in item:
        if node.tag == MAIN + "t":
            chunks.append(node.text or "")
        elif node.tag == MAIN + "r":
            chunks.extend(text.text or "" for text in node.findall(MAIN + "t"))
    return "".join(chunks)


def _strings(archive):
    if "xl/sharedStrings.xml" not in archive.namelist():
        return []
    # Only text runs: phonetic annotations must not change identifiers/names.
    return [_text_runs(item) for item in _xml(archive, "xl/sharedStrings.xml").findall(MAIN + "si")]


def _sheet(archive, member, name, strings):
    rows = {}
    count = 0
    sheet = _xml(archive, member)
    shared = {}
    followers = []
    for row in sheet.findall(f"{MAIN}sheetData/{MAIN}row"):
        try:
            row_number = int(row.attrib["r"])
        except (KeyError, ValueError) as error:
            raise ValueError("Workbook has an invalid row reference") from error
        if row_number < 1 or row_number > 1048576 or row_number in rows:
            raise ValueError("Workbook has an invalid or duplicate row")
        cells = {}
        for node in row.findall(MAIN + "c"):
            count += 1
            if count > MAX_CELLS:
                raise ValueError("Workbook exceeds the cell conversion limit")
            reference = node.attrib.get("r", "")
            match = re.fullmatch(r"([A-Z]{1,3})([1-9]\d*)", reference)
            if not match or int(match[2]) != row_number or reference in cells:
                raise ValueError("Workbook has an invalid or duplicate cell reference")
            kind = node.attrib.get("t", "n")
            value = node.find(MAIN + "v")
            raw = value.text or "" if value is not None else ""
            if kind == "s":
                try:
                    index = int(raw)
                    if index < 0:
                        raise ValueError()
                    raw = strings[index]
                except (ValueError, IndexError) as error:
                    raise ValueError("Workbook has an invalid shared-string reference") from error
            elif kind == "inlineStr":
                inline = node.find(MAIN + "is")
                raw = "" if inline is None else _text_runs(inline)
            formula = node.find(MAIN + "f")
            cells[reference] = Cell(raw, kind, None if formula is None else formula.text or "")
            if formula is not None and formula.attrib.get("t") == "shared":
                index = formula.attrib.get("si")
                if not index or not index.isdigit():
                    raise ValueError("Workbook has an invalid shared formula reference")
                if formula.text:
                    if index in shared:
                        raise ValueError("Workbook has a duplicate shared formula anchor")
                    shared[index] = (formula.text, reference, formula.attrib.get("ref", ""))
                else:
                    followers.append((row_number, reference, index))
        rows[row_number] = cells
    for row_number, reference, index in followers:
        if index in shared:
            formula, anchor, declared_range = shared[index]
            cell = rows[row_number][reference]
            rows[row_number][reference] = Cell(cell.raw, cell.kind, translate(formula, anchor, reference, declared_range))
    return SheetRows(name, rows)


def read_workbook(path: Path) -> WorkbookRows:
    path = Path(path)
    if path.suffix.lower() != ".xlsx" or path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("A bounded XLSX source file is required")
    # Read once: fingerprints and parsed values refer to exactly the same bytes.
    with path.open("rb") as source:
        data = source.read(MAX_ARCHIVE_BYTES + 1)
    if len(data) > MAX_ARCHIVE_BYTES:
        raise ValueError("Workbook exceeds archive conversion limits")
    from io import BytesIO
    try:
        with ZipFile(BytesIO(data)) as archive:
            entries = archive.infolist()
            if len(entries) > 4096 or sum(i.file_size for i in entries) > MAX_TOTAL_BYTES:
                raise ValueError("Workbook exceeds archive conversion limits")
            if len({i.filename for i in entries}) != len(entries):
                raise ValueError("Workbook contains duplicate archive members")
            workbook = _xml(archive, "xl/workbook.xml")
            relationships = _xml(archive, "xl/_rels/workbook.xml.rels")
            targets = {}
            for relationship in relationships:
                if relationship.attrib.get("TargetMode") == "External":
                    continue
                targets[relationship.attrib.get("Id")] = relationship.attrib.get("Target", "")
            properties = workbook.find(MAIN + "workbookPr")
            date1904 = properties is not None and properties.attrib.get("date1904") in {"1", "true"}
            strings = _strings(archive)
            sheets = {}
            for node in workbook.findall(f"{MAIN}sheets/{MAIN}sheet"):
                name = node.attrib.get("name", "")
                target = targets.get(node.attrib.get(REL + "id"))
                if not name or name in sheets or not target or "\\" in target:
                    raise ValueError("Workbook has an invalid worksheet relationship")
                member = target.lstrip("/") if target.startswith("/") else posixpath.normpath("xl/" + target)
                if not member.startswith("xl/worksheets/") or ".." in member.split("/"):
                    raise ValueError("Worksheet relationship leaves the workbook worksheet directory")
                sheets[name] = _sheet(archive, member, name, strings)
            return WorkbookRows(path.name, hashlib.sha256(data).hexdigest(), date1904, sheets)
    except BadZipFile as error:
        raise ValueError("Source is not a valid XLSX archive") from error
