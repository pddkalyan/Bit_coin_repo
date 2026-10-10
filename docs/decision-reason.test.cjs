'use strict';
const assert = require('node:assert/strict');
const {explain} = require('./decision-reason.js');
const base = {
  actual_transaction: 'NONE', realized_profit_inr: 'NOT_MEASURED',
  verdict: 'SKIP_NOT_PROFITABLE_ENOUGH', gross_spread_usd: '-52.3272',
  estimated_net_usd: '-56.2423', min_profit_usd: '5.0000'
};
const test = (name, overrides, expected) => {
  const observed = explain({...base, ...overrides});
  assert.equal(observed, expected, name);
  console.log('PASS', name);
};
test('negative gross spread', {}, 'Rejected: route loses $52.33 before costs');
test('gas and fees erase positive gross', {gross_spread_usd:'1.10', estimated_net_usd:'-0.30'}, 'Rejected: fees and risk buffer erase spread (−$0.30 net)');
test('positive but below minimum', {gross_spread_usd:'9',estimated_net_usd:'3.60'}, 'Rejected: +$3.60 net ≤ +$5.00 minimum');
test('positive paper candidate', {verdict:'HYPOTHETICAL_CANDIDATE_NOT_EXECUTED',gross_spread_usd:'20',estimated_net_usd:'8.40'}, 'Paper candidate: +$8.40 net > +$5.00 minimum; not traded');
test('no liquidity', {verdict:'SKIP_NO_LIQUIDITY'}, 'Rejected: insufficient liquidity for this route');
test('reject malformed numeric', {estimated_net_usd:'NaN'}, 'Unavailable: incomplete or invalid price/fee estimate');
test('reject contradictory paper candidate', {verdict:'HYPOTHETICAL_CANDIDATE_NOT_EXECUTED', estimated_net_usd:'-1'}, 'Unavailable: candidate conflicts with profit threshold');
test('reject real transaction', {actual_transaction:'0xbeef'}, 'Unavailable: not a verified paper-only observation');
test('reject spoofed realized profit', {realized_profit_inr:'500'}, 'Unavailable: not a verified paper-only observation');
