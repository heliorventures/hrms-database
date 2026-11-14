"""Guarded additive business ACL correction; pure SQL, no execution or credentials.

The full policy validator also requires these exact rights for future plans.
This compiler changes only the reviewed role/relation/operation/column pairs;
all other catalog, membership, ownership, RLS and ACL invariants are retained.
"""
from business_columns import BUSINESS_COMPANY_COLUMNS
import online_columns


def additions():
    return online_columns.additions(BUSINESS_COMPANY_COLUMNS)


def snapshot_sql(target):
    return online_columns.snapshot_sql(target, BUSINESS_COMPANY_COLUMNS)


def guarded_sql(target, before):
    return online_columns.guarded_sql(target, before, BUSINESS_COMPANY_COLUMNS)
