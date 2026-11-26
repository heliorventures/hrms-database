const {test}=require('node:test');
const {runOwnedEmailSettings}=require('./email-settings-fixture.cjs');
test('key rotation previews without writes, verifies both keys and resumes per company without changing settings', t=>runOwnedEmailSettings(t,'email_key_rotation_owned','owned_rotation_preview_apply_resume_and_missing_key'));
