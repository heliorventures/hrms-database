DROP SCHEMA IF EXISTS loan_scope_fixture CASCADE;
DROP SCHEMA IF EXISTS kabipay_ops CASCADE;
CREATE SCHEMA kabipay_ops;
CREATE SCHEMA loan_scope_fixture;
CREATE TABLE kabipay_ops.module(id UUID PRIMARY KEY DEFAULT gen_random_uuid(),code TEXT NOT NULL UNIQUE);
CREATE TABLE kabipay_ops.tenant_database(tenant_id UUID NOT NULL,schema_name TEXT NOT NULL UNIQUE);
CREATE TABLE loan_scope_fixture.role(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id UUID NOT NULL,name TEXT NOT NULL,
 is_deleted BOOLEAN NOT NULL DEFAULT false,UNIQUE(tenant_id,name)
);
CREATE TABLE loan_scope_fixture.permission(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),resource TEXT NOT NULL,action TEXT NOT NULL,
 module_id UUID NOT NULL,UNIQUE(resource,action,module_id)
);
CREATE TABLE loan_scope_fixture.role_permission(
 role_id UUID REFERENCES loan_scope_fixture.role,permission_id UUID REFERENCES loan_scope_fixture.permission,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),PRIMARY KEY(role_id,permission_id)
);
CREATE TABLE loan_scope_fixture.permission_scope(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id UUID NOT NULL,
 role_id UUID REFERENCES loan_scope_fixture.role,resource TEXT NOT NULL,action TEXT NOT NULL,
 scope_type VARCHAR(20) NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),UNIQUE(role_id,resource,action)
);
INSERT INTO kabipay_ops.module(code) VALUES('LOANS'),('EMPLOYEE'),('PAYROLL');
INSERT INTO kabipay_ops.tenant_database VALUES('00000000-0000-0000-0000-000000000001','loan_scope_fixture');
INSERT INTO loan_scope_fixture.role(tenant_id,name,is_deleted) VALUES
 ('00000000-0000-0000-0000-000000000001','ADMIN',false),
 ('00000000-0000-0000-0000-000000000001','HR',false),
 ('00000000-0000-0000-0000-000000000001','MANAGER',false),
 ('00000000-0000-0000-0000-000000000001','EMPLOYEE',false),
 ('00000000-0000-0000-0000-000000000001','CUSTOM',false),
 ('00000000-0000-0000-0000-000000000001','hr',true),
 ('00000000-0000-0000-0000-000000000002','HR',false);
INSERT INTO loan_scope_fixture.permission(resource,action,module_id)
 SELECT 'loan',a.action,m.id FROM kabipay_ops.module m
 CROSS JOIN (VALUES('read'),('submit'),('approve'),('disburse'),('repay'),('manage'),('policy'),('correct'),('exit-review'),('export')) a(action)
 WHERE m.code='LOANS';
INSERT INTO loan_scope_fixture.permission(resource,action,module_id)
 SELECT 'payroll','manage',id FROM kabipay_ops.module WHERE code='PAYROLL';
