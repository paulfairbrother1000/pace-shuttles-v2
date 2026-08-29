import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

test('public partner page submits to V2 and retains the V1 application fields',()=>{
  const page=readFileSync('components/partner-application-form.tsx','utf8');
  const data=readFileSync('lib/data.ts','utf8');
  assert.match(data,/v2_public_submit_partner_application/);
  for(const field of ['application_type','org_name','org_address','telephone','mobile','email','website','social_instagram','social_youtube','social_x','social_facebook','contact_name','contact_role','years_operation','pickup_suggestions','destination_suggestions','description']) assert.match(page,new RegExp(field));
  assert.doesNotMatch(page,/pace-shuttles-v1|bopvaaexicvdueidyvjd/);
});
