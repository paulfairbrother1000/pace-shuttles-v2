import test from 'node:test';
import assert from 'node:assert/strict';
import {checkoutReturnState,shouldRestorePreparedCheckout} from '../lib/checkout-return-state.ts';

test('prepared checkout state survives a terms round trip',()=>{
 const state=checkoutReturnState({order_id:'order-1',route_name:"St John's → Nikki Beach",total_cents:10000},{terms_id:'terms-1',country_name:'Antigua and Barbuda',terms_version:'2025-10-24',accepted:false});
 assert.equal(state.order.order_id,'order-1');
 assert.equal(state.terms.terms_id,'terms-1');
 assert.equal(shouldRestorePreparedCheckout(state,'order-1'),true);
});

test('prepared checkout is not restored for a different order',()=>{
 const state=checkoutReturnState({order_id:'order-1'},{terms_id:'terms-1'});
 assert.equal(shouldRestorePreparedCheckout(state,'order-2'),false);
});
