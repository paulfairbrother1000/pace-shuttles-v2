import {describe,expect,it} from 'vitest';
import {buildPartnerApplicationPayload,validatePartnerApplication} from './partner-application';

describe('partner application',()=>{
  it('requires only the initial-phase essentials for an operator',()=>{
    expect(validatePartnerApplication({application_type:'operator'} as any)).toEqual([
      'Organisation name is required','Country is required','Transport type is required'
    ]);
  });
  it('keeps email optional and accepts an other country',()=>{
    const form:any={application_type:'destination',org_name:'Harbour Club',other_country_text:'Montserrat',destination_type_id:'3'};
    expect(validatePartnerApplication(form)).toEqual([]);
    expect(buildPartnerApplicationPayload(form)).toMatchObject({application_type:'destination',org_name:'Harbour Club',country_id:null,other_country_text:'Montserrat',destination_type_id:'3'});
  });
  it('normalises operator place ids and numbers',()=>{
    const form:any={application_type:'operator',org_name:'Island Boats',country_id:'c1',transport_type_id:'t1',place_ids:['p1','p1','p2'],fleet_size:'4',years_operation:'12'};
    expect(buildPartnerApplicationPayload(form)).toMatchObject({place_ids:['p1','p2'],fleet_size:4,years_operation:12,destination_type_id:null});
  });
});
