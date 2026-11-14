"""Explicit Employee-service requirements for authenticated broker ownership.

The source endpoint reads the durable receipt, then records initial broker
ownership. Receiver delivery status, immutable intent identity and source
authority are outside this additive contract.
"""

PRIVATE_OWNERSHIP_COLUMNS = {
    'hrms_company_employee': {
        'private_delivery_receipt': {
            'select': [
                'tenant_id', 'intent_id', 'destination_id', 'intent_hash',
                'destination_version', 'source_generation', 'broker_owned_at',
                'broker_owner_id', 'broker_receipt_sha256',
            ],
            'update': [
                'broker_owned_at', 'broker_owner_id', 'broker_receipt_sha256',
                'updated_at',
            ],
        },
    },
}
