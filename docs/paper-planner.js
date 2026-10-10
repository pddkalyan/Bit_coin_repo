/* Read-only, client-side what-if calculation. Never creates or sends transactions. */
(function(root){
 'use strict';
 function calculate(r,s={},now=Date.now()){
  const num=x=>Number(x),val={
   size:num(r?.virtual_flash_usd),gross:num(r?.gross_spread_usd),
   gas:num(r?.estimated_gas_usd),floor:num(r?.min_profit_usd),
   multiple:num(s.multiple??2),premium:num(s.premium??9),
   buffer:num(s.buffer??100),minBps:num(s.minBps??50)
  };
  const good=r?.source==='PUBLIC_RPC_READ_ONLY_SAME_BLOCK_RESERVES' &&
    r.actual_transaction==='NONE'&&r.realized_profit_inr==='NOT_MEASURED' &&
    Object.values(val).every(Number.isFinite)&&val.size>0&&val.gas>=0&&val.floor>=0 &&
    val.multiple>=1&&val.multiple<=10&&val.premium>=0&&val.premium<=200&&
    val.buffer>=0&&val.buffer<=1000&&val.minBps>=0&&val.minBps<=1000;
  if(!good)return {status:'UNAVAILABLE',reason:'Invalid data/settings. No trade approved.'};
  const age=(now-Date.parse(r.timestamp_utc))/60000;
  if(!Number.isFinite(age)||age< -2)return {status:'UNAVAILABLE',reason:'Invalid quote timestamp.'};
  const costs=val.gas*val.multiple+val.size*(val.premium+val.buffer)/10000;
  const net=val.gross-costs,minimum=Math.max(val.floor,val.size*val.minBps/10000);
  const money=x=>(x>=0?'+':'−')+'$'+Math.abs(x).toFixed(2);
  const status=age>15?'STALE':net>minimum?'PAPER PASS':'REJECTED';
  const reason=age>15?'Quote is '+Math.floor(age)+' minutes old; refresh market data.':
    money(net)+' net '+(net>minimum?'exceeds':'does not exceed')+' '+money(minimum)+' minimum after modeled costs; NOT A REAL TRADE.';
  return {status,reason,net,costs,minimum,age};
 }
 function init(){
  const el=id=>document.getElementById(id);
  let current=null;
  const get=()=>({multiple:el('whatGas').value,premium:el('whatPremium').value,buffer:el('whatBuffer').value,minBps:el('whatFloor').value});
  function render(){
   const result=current?calculate(current,get()):{status:'NO ROUTE',reason:'Select View on a quote first.'};
   el('whatResult').textContent=result.status+' — '+result.reason;
   el('whatNumbers').textContent=Number.isFinite(result.net)?'Estimated net $'+result.net.toFixed(2)+' · modeled costs $'+result.costs.toFixed(2)+' · quote '+Math.floor(result.age)+' minutes old':'Not yet calculated';
   return result;
  }
  el('whatEvaluate').addEventListener('click',render);
  el('whatReset').addEventListener('click',()=>{el('whatGas').value='2';el('whatPremium').value='9';el('whatBuffer').value='100';el('whatFloor').value='50';render();});
  el('whatCopy').addEventListener('click',()=>{
   const r=render(),details=['PAPER TEST ONLY — NO TRANSACTION',current?current.network+' '+current.buy_from+' -> '+current.sell_to:'No selected route',r.status+': '+r.reason].join('\n');
   if(navigator.clipboard?.writeText)navigator.clipboard.writeText(details).then(()=>el('whatCopy').textContent='Copied',()=>el('whatCopy').textContent='Copy failed');
  });
  root.PaperPlanner.select=r=>{current=r;render();};
  render();
 }
 root.PaperPlanner={calculate,select:()=>{}};
 if(typeof module!=='undefined'&&module.exports)module.exports={calculate};
 if(typeof document!=='undefined')document.addEventListener('DOMContentLoaded',init,{once:true});
})(typeof window!=='undefined'?window:{});
