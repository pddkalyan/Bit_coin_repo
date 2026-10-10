/* Read-only explanations: NEVER authorizes transactions. */
(function(root){
 'use strict';
 const money=n=>Number.isFinite(n)?`${n<0?'−':'+'}$${Math.abs(n).toFixed(2)}`:'N/A';
 function explain(r){
  if(!r||r.actual_transaction!=='NONE'||r.realized_profit_inr!=='NOT_MEASURED')return 'NO DECISION — this is not a valid paper-only observation.';
  if(r.verdict==='SKIP_NO_LIQUIDITY')return 'REJECTED — both trading pools did not have usable liquidity.';
  const gross=Number(r.gross_spread_usd),net=Number(r.estimated_net_usd),min=Number(r.min_profit_usd),flash=Number(r.estimated_flash_fee_usd),gas=Number(r.estimated_gas_usd),buffer=Number(r.extra_risk_buffer_usd);
  if(![gross,net,min,flash,gas,buffer].every(Number.isFinite)||min<0)return 'NO DECISION — some prices or fee estimates are invalid.';
  const costs=flash+gas+buffer;
  if(r.verdict==='HYPOTHETICAL_CANDIDATE_NOT_EXECUTED')return net>min?`PAPER PASS — ${money(net)} estimated net > ${money(min)} minimum; execution untested.`:'NO DECISION — reported candidate fails the profit check.';
  if(r.verdict!=='SKIP_NOT_PROFITABLE_ENOUGH')return 'NO DECISION — unrecognized paper verdict.';
  if(gross<0)return `REJECTED — swaps lose $${Math.abs(gross).toFixed(2)} even before $${costs.toFixed(2)} fees/buffer.`;
  if(net<=0)return `REJECTED — +$${gross.toFixed(2)} spread is smaller than $${costs.toFixed(2)} costs; net ${money(net)}.`;
  if(net<=min)return `REJECTED — ${money(net)} net is below required +$${min.toFixed(2)} after costs.`;
  return 'NO DECISION — inconsistent profitability estimate.';
 }
 const api=Object.freeze({explain});if(root)root.PaperDecision=api;if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof window!=='undefined'?window:undefined);
