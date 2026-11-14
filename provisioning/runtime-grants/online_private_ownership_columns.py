"""Guarded, column-only broker ownership grants; pure SQL compilation."""
from private_ownership_columns import PRIVATE_OWNERSHIP_COLUMNS
import online_columns


def additions():
    return online_columns.additions(PRIVATE_OWNERSHIP_COLUMNS)


def snapshot_sql(target):
    return online_columns.snapshot_sql(target, PRIVATE_OWNERSHIP_COLUMNS)


def guarded_sql(target, before):
    return online_columns.guarded_sql(target, before, PRIVATE_OWNERSHIP_COLUMNS)
