"""Exact occurrence reads for the maintenance caller; pure guarded compilation."""
from presentation_columns import PRESENTATION_COMPANY_COLUMNS
import online_columns

REQUIREMENTS = {'hrms_company_maintenance': {'automated_notification_occurrence': {
    'select': list(PRESENTATION_COMPANY_COLUMNS['hrms_company_maintenance']
                   ['automated_notification_occurrence']['select'])}}}


def snapshot_sql(target):
    return online_columns.snapshot_sql(target, REQUIREMENTS)


def guarded_sql(target, before):
    return online_columns.guarded_sql(target, before, REQUIREMENTS)
