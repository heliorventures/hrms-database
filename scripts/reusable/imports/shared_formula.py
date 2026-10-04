"""Translate bounded numeric shared formulas without evaluating Excel code."""
import re


CELL = re.compile(r"(?<![A-Z0-9_])(?P<colabs>\$?)(?P<col>[A-Z]{1,3})(?P<rowabs>\$?)(?P<row>[1-9]\d*)(?![A-Z0-9_])")


def column_number(column):
    result = 0
    for char in column:
        result = result * 26 + ord(char) - 64
    return result


def column_name(number):
    result = ""
    while number:
        number, digit = divmod(number - 1, 26)
        result = chr(65 + digit) + result
    return result


def translate(formula, anchor, destination, declared_range):
    if len(formula) > 2048 or not re.fullmatch(r"[A-Za-z0-9$+*/%().,:=\s-]+", formula):
        return ""
    origin, target = CELL.fullmatch(anchor), CELL.fullmatch(destination)
    bounds = declared_range.split(":") if declared_range else []
    if len(bounds) == 1:
        bounds *= 2
    if len(bounds) != 2:
        return ""
    first, last = (CELL.fullmatch(value) for value in bounds)
    if any(value is None for value in (origin, target, first, last)):
        return ""
    col, row = column_number(target["col"]), int(target["row"])
    if not (column_number(first["col"]) <= col <= column_number(last["col"]) and
            int(first["row"]) <= row <= int(last["row"])):
        return ""
    col_delta, row_delta = col - column_number(origin["col"]), row - int(origin["row"])

    def shift(match):
        translated_col = column_number(match["col"]) + (0 if match["colabs"] else col_delta)
        translated_row = int(match["row"]) + (0 if match["rowabs"] else row_delta)
        if not (1 <= translated_col <= 16384 and 1 <= translated_row <= 1048576):
            raise ValueError("translated reference outside worksheet")
        return f'{match["colabs"]}{column_name(translated_col)}{match["rowabs"]}{translated_row}'

    try:
        return CELL.sub(shift, formula.upper())
    except ValueError:
        return ""
