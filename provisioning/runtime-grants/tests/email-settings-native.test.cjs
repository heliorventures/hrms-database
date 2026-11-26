const {test}=require('node:test');
const {runOwnedEmailSettings}=require('./email-settings-fixture.cjs');
test('real Notification settings, cutoffs, audit rollback and test limits use restricted SQL', t=>runOwnedEmailSettings(t,'email_settings_owned','owned_settings_transactions'));
