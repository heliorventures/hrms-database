"""Offline XSD validation against the installed Liquibase core schema."""
from pathlib import Path
from zipfile import ZipFile
from lxml import etree
import sys
root=Path(__file__).resolve().parents[2]
jar=Path(sys.argv[1]) if len(sys.argv)>1 else root/'node_modules/liquibase/dist/liquibase/internal/lib/liquibase-core.jar'
with ZipFile(jar) as archive:
    class JarResolver(etree.Resolver):
        def resolve(self,url,public_id,context):
            suffix=url.removeprefix('http://').removeprefix('https://')
            if suffix in archive.namelist(): return self.resolve_string(archive.read(suffix),context)
            raise ValueError('XSD dependency is not available offline: '+url)
    parser=etree.XMLParser(no_network=True)
    parser.resolvers.add(JarResolver())
    schema=etree.XMLSchema(etree.fromstring(archive.read('www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.27.xsd'),parser,base_url='http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.27.xsd'))
    for file in [root/'changelog/migrations/0103_employee_loans/employee_loans.xml',*sorted((root/'changelog/migrations/0104_loan_module_catalog').glob('*.xml')),root/'changelog/migrations/0105_payslip_loan_evidence/payslip_loan_evidence.xml']:
        schema.assertValid(etree.fromstring(file.read_bytes(),etree.XMLParser(no_network=True,resolve_entities=False)))
        print(file.name+' XSD valid')
