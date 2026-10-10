
'use strict';
(() => {
const DATA_URL='https://raw.githubusercontent.com/pddkalyan/Bit_coin_repo/paper-data/docs/dashboard-data.json';
const $=id=>document.getElementById(id);
const state={rows:[],summary:null,chart:'all',wallet:null,loading:false,selectedRow:null};
const asNumber=v=>{const n=Number(v);return Number.isFinite(n)?n:null};
const escapeHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const explainDecision = row => window.PaperDecision?.explain(row) || 'Unavailable: decision logic not loaded';
const int=v=>typeof v==='number'?v.toLocaleString('en-IN'):'—';
const fmt=(v,d=2)=>typeof v==='number'&&Number.isFinite(v)?v.toLocaleString('en-IN',{minimumFractionDigits:d,maximumFractionDigits:d}):'—';
function validateData(payload){
 if(!payload||payload.schema_version!==1||payload.mode!=='READ_ONLY_NOT_EXECUTED'||!Array.isArray(payload.observations)||!payload.summary)throw Error('Unexpected or unsafe report schema');
 if(payload.observations.length>2500)throw Error('Too many observations');
 for(const r of payload.observations){if(!['polygon','bsc'].includes(r.network)||r.source!=='PUBLIC_RPC_READ_ONLY_SAME_BLOCK_RESERVES'||r.actual_transaction!=='NONE'||r.realized_profit_inr!=='NOT_MEASURED'||!['HYPOTHETICAL_CANDIDATE_NOT_EXECUTED','SKIP_NOT_PROFITABLE_ENOUGH','SKIP_NO_LIQUIDITY'].includes(r.verdict))throw Error('Invalid non-paper observation');}
 if(payload.summary.real_trades_executed!==0||payload.summary.realized_pnl_inr!=='NOT_MEASURED')throw Error('Not a paper-only report');
 return payload;
}
function listRows(){let v=state.rows.slice();if($('netFilter').value!=='all')v=v.filter(r=>r.network===$('netFilter').value);if($('verdictFilter').value!=='all')v=v.filter(r=>r.verdict===$('verdictFilter').value);v.sort((a,b)=>String(b.timestamp_utc).localeCompare(String(a.timestamp_utc)));return v;}
function shortTime(s){const d=new Date(s);return Number.isNaN(d.getTime())?'—':d.toLocaleString('en-GB',{timeZone:'UTC',day:'2-digit',month:'short',hour:'2-digit',minute:'2-digit',hour12:false});}
function unitPrice(v){const n=asNumber(v);if(n===null||n<=0)return 'Not sampled';return '$'+n.toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:n<1?6:3});}
function approxInr(v){const n=asNumber(v);return n>0?'≈₹'+(n*90).toLocaleString('en-IN',{minimumFractionDigits:2,maximumFractionDigits:2}):'INR not available';}
function renderPrices(){
 const cards=[];
 for(const c of ['polygon','bsc']){
  const rows=state.rows.filter(r=>r.network===c&&asNumber(r.unit_buy_usd)>0&&asNumber(r.unit_sell_usd)>0).sort((a,b)=>String(b.timestamp_utc).localeCompare(String(a.timestamp_utc)));
  const r=rows[0];
  if(!r){cards.push(`<div class="pricecard"><div class="price-title">${c==='polygon'?'Polygon · 1 WPOL':'BNB Chain · 1 WBNB'}</div><p class="price-meta">One-unit prices were not recorded in older samples. They will appear after the next successful cloud observation.</p></div>`);continue;}
  const timestamp=Date.parse(r.timestamp_utc),age=Number.isFinite(timestamp)?Math.max(0,(Date.now()-timestamp)/60000):null,ageLabel=age===null?'Unknown age':age<60?`${Math.floor(age)} min old`:`${(age/60).toFixed(1)} hours old`;
  cards.push(`<div class="pricecard"><div class="price-title"><span>${c==='polygon'?'Polygon':'BNB Chain'} · 1 ${c==='polygon'?'WPOL':'WBNB'}</span><span class="muted tiny">${escapeHtml(ageLabel)}</span></div><div class="price-figures"><div><span>Buy 1 on ${escapeHtml(r.buy_from)}</span><strong>${unitPrice(r.unit_buy_usd)}</strong><small>${approxInr(r.unit_buy_usd)}</small></div><div><span>Sell 1 on ${escapeHtml(r.sell_to)}</span><strong>${unitPrice(r.unit_sell_usd)}</strong><small>${approxInr(r.unit_sell_usd)}</small></div></div><div class="price-meta">Sampled ${escapeHtml(shortTime(r.timestamp_utc))} UTC · block ${escapeHtml(r.block)} · V2 pool quote including swap fee/impact; excludes gas/flash fee. Not a current executable order. Stablecoin ≈ USD; INR uses assumed ₹90/USD, not live FX.</div></div>`);
 }
 $('priceTiles').innerHTML=cards.join('');
 $('priceFreshness').textContent='Historical pool snapshots';
}
function renderComparison(){
 const r=state.selectedRow||state.rows.slice().sort((a,b)=>String(b.timestamp_utc).localeCompare(String(a.timestamp_utc)))[0],out=[];
 const add=(name,before,after='Not executed')=>out.push(`<tr><td>${escapeHtml(name)}</td><td>${escapeHtml(before)}</td><td>${escapeHtml(after)}</td></tr>`);
 if(!r){add('Status','No paper observations','No transactions');$('comparisonTitle').textContent='No route has been sampled.';}
 else{
  $('comparisonTitle').textContent=`${r.network==='polygon'?'Polygon':'BNB Chain'} · ${r.buy_from} → ${r.sell_to} · ${shortTime(r.timestamp_utc)} UTC · block ${r.block}`;
  add('Asset',`1 ${r.network==='polygon'?'WPOL':'WBNB'}: buy ${unitPrice(r.unit_buy_usd)}, sell ${unitPrice(r.unit_sell_usd)}`);
  add('Hypothetical flash loan',`${r.virtual_flash_usd} ${r.network==='polygon'?'USDC':'USDT'}`);
  add('Swap gross spread',`$${r.gross_spread_usd} (exchange fees included)`);
  add('Loan premium (modeled)',`$${r.estimated_flash_fee_usd}`);
  add('Gas (modeled)',`$${r.estimated_gas_usd}`);
  add('Risk buffer (modeled)',`$${r.extra_risk_buffer_usd}`);
  add('Net result',`$${r.estimated_net_usd} / ₹${r.estimated_net_inr}`,'Actual P&L not measured');
  add('Decision',explainDecision(r),'NOT APPROVED FOR LIVE TRADING');
  add('Transaction hash','None','None');
 }
 $('comparisonBody').innerHTML=out.join('');
 window.PaperPlanner?.select(r||null);
}
function renderTable(){
 const all=listRows(),limited=$('rowCount').value==='all'?all:all.slice(0,Number($('rowCount').value));
 $('rowMeta').textContent=`Showing ${limited.length} of ${all.length} paper quotes. No real trades were executed.`;
 $('tableBody').innerHTML=limited.length?limited.map((r,i)=>{
  const net=asNumber(r.estimated_net_inr),good=r.verdict==='HYPOTHETICAL_CANDIDATE_NOT_EXECUTED',reason=explainDecision(r),verdict=good?'Paper pass · unexecuted':r.verdict==='SKIP_NO_LIQUIDITY'?'No liquidity':'Rejected';
  return `<tr class="${state.selectedRow===r?'selected':''}"><td>${escapeHtml(shortTime(r.timestamp_utc))}</td><td>${r.network==='polygon'?'Polygon':'BNB'}</td><td>${escapeHtml(r.buy_from)} → ${escapeHtml(r.sell_to)}</td><td>${escapeHtml(r.gross_spread_usd)} USD</td><td>${escapeHtml(r.estimated_flash_fee_usd)} USD</td><td>${escapeHtml(r.estimated_gas_usd)} USD</td><td class="${net>0?'valuepos':'valueneg'}">${net!==null?'₹'+fmt(net):'—'}</td><td><span class="tag ${good?'pos':'neg'}">${verdict}</span></td><td class="reasoncell" title="${escapeHtml(reason)}">${escapeHtml(reason)}</td><td><button class="inspectbtn" type="button" data-inspect="${i}">View</button></td></tr>`;
 }).join(''):'<tr><td colspan="10" class="empty">No matching observations. See cloud job logs for RPC failures.</td></tr>';
}
function renderChart(){const rows=state.rows.filter(r=>state.chart==='all'||r.network===state.chart).slice(-65).filter(r=>asNumber(r.estimated_net_inr)!==null),holder=$('chartHolder');if(!rows.length){holder.innerHTML='<div class="chartempty">No observed market estimates to plot.</div>';return}const vals=rows.map(r=>Number(r.estimated_net_inr)),low=Math.min(0,...vals),high=Math.max(0,...vals),range=Math.max(1,high-low),x=i=>55+i*(610/Math.max(rows.length-1,1)),y=v=>24+(high-v)*170/range,points=vals.map((v,i)=>`${x(i)},${y(v)}`).join(' '),zero=y(0),svg=`<svg class="chart" viewBox="0 0 725 230" role="img" aria-label="Estimated INR profit per route quote; hypothetical only"><g stroke="#22344b" stroke-width="1">${[0,1,2,3,4].map(i=>`<line x1="55" y1="${24+i*42.5}" x2="675" y2="${24+i*42.5}"/>`).join('')}</g><line x1="55" y1="${zero}" x2="675" y2="${zero}" stroke="#7991a4" stroke-dasharray="5 6"/><g class="axislabel"><text x="8" y="28">₹${Math.round(high)}</text><text x="8" y="${zero-5}">₹0</text><text x="8" y="200">₹${Math.round(low)}</text><text x="55" y="220">Oldest</text><text x="629" y="220">Latest</text></g><polyline class="line" points="${points}"/><g class="dots">${vals.map((v,i)=>`<circle cx="${x(i)}" cy="${y(v)}" r="${rows.length>25?2.5:4}"/>`).join('')}</g></svg>`;holder.innerHTML=svg;}
function render(){const s=state.summary||{};const cnt=state.rows.length;$('totalQuotes').textContent=int(cnt);$('candidates').textContent=int(state.rows.filter(r=>r.verdict==='HYPOTHETICAL_CANDIDATE_NOT_EXECUTED').length);$('realTrades').textContent='0';$('realized').textContent='N/A';for(const c of ['polygon','bsc']){const n=state.rows.filter(r=>r.network===c).length;$(c+'Count').textContent=`${n} route quotes`;$(c+'State').textContent=n?'Observations found':'No observations';$(c+'State').className='statuslabel'+(n?'':' warn');}$('latestObs').textContent=s.latest_observation_utc?shortTime(s.latest_observation_utc)+' UTC':'—';$('details').textContent=String(s.warning||'Gas usage, flash premium, FX and buffers are assumptions. No fills or P&L are verified.');renderTable();renderChart();renderPrices();renderComparison();}
async function refresh(){if(state.loading)return;state.loading=true;$('fetchStatus').innerHTML='<span class="spinner" aria-hidden="true"></span> Loading';try{const res=await fetch(DATA_URL+'?t='+Date.now(),{cache:'no-store'});if(!res.ok)throw Error(`Report not published yet (HTTP ${res.status})`);const data=validateData(await res.json());state.rows=data.observations;state.summary=data.summary;render();$('fetchStatus').textContent='Published read-only JSON';}catch(e){$('fetchStatus').textContent='Not available';$('details').textContent='Could not load published data: '+String(e.message)+'. You can still review GitHub Actions artifacts.';render();}finally{state.loading=false}}
function exportCsv(){const rows=listRows();if(!rows.length){alert('No observations available for download.');return}const keys=['timestamp_utc','network','block','buy_from','sell_to','virtual_flash_usd','unit_symbol','unit_buy_usd','unit_sell_usd','gross_spread_usd','estimated_flash_fee_usd','estimated_gas_usd','extra_risk_buffer_usd','estimated_net_inr','verdict','decision_reason','actual_transaction','realized_profit_inr'],esc=v=>'"'+String(v??'').replaceAll('"','""')+'"',content=[keys.join(','),...rows.map(r=>keys.map(k=>esc(k==='decision_reason'?explainDecision(r):r[k])).join(','))].join('\r\n');const url=URL.createObjectURL(new Blob([content],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download='crypto-paper-observations.csv';a.click();setTimeout(()=>URL.revokeObjectURL(url),500);}
async function connectWallet(){const p=window.ethereum;if(!p||typeof p.request!=='function'){$('walletState').textContent='No injected EVM wallet detected. On a phone, open this page in your wallet app browser. No wallet is needed for paper monitoring.';return}try{const accounts=await p.request({method:'eth_requestAccounts'});if(!Array.isArray(accounts)||!accounts[0]||!/^0x[0-9a-fA-F]{40}$/.test(accounts[0]))throw Error('Wallet did not return a valid public address');const chain=await p.request({method:'eth_chainId'});const balance=await p.request({method:'eth_getBalance',params:[accounts[0],'latest']});if(!/^0x[0-9a-f]+$/i.test(String(balance)))throw Error('Invalid balance response');state.wallet=accounts[0];const coin=chain==='0x89'?'POL':chain==='0x38'?'BNB':'native coin';const bal=(Number(BigInt(balance)/1000000000000000n)/1000).toLocaleString('en-IN',{maximumFractionDigits:6});$('walletState').innerHTML=`Viewing: <strong>${escapeHtml(accounts[0])}</strong><br/>Wallet chain ID: <strong>${escapeHtml(chain)}</strong><br/>Estimated native balance: <strong>${escapeHtml(bal)} ${coin}</strong><br/><span class="good">View-only. No transaction was sent.</span>`;}catch(e){$('walletState').textContent='Wallet connection was rejected or unavailable: '+String(e.message).slice(0,150)}}
$('refreshBtn').addEventListener('click',refresh);$('csvBtn').addEventListener('click',exportCsv);$('connectBtn').addEventListener('click',connectWallet);$('disconnectBtn').addEventListener('click',()=>{state.wallet=null;$('walletState').textContent='Wallet hidden in this page. To fully revoke access, use the wallet app’s connected-sites settings.'});$('tableBody').addEventListener('click',e=>{const button=e.target.closest('[data-inspect]');if(!button)return;const row=listRows()[Number(button.dataset.inspect)];if(!row)return;state.selectedRow=row;renderComparison();renderTable();$('comparison').scrollIntoView({behavior:'smooth',block:'start'});});['netFilter','verdictFilter','rowCount'].forEach(id=>$(id).addEventListener('change',renderTable));document.querySelectorAll('[data-chart]').forEach(btn=>btn.addEventListener('click',()=>{state.chart=btn.dataset.chart;document.querySelectorAll('[data-chart]').forEach(x=>x.classList.toggle('active',x===btn));renderChart()}));refresh();
setInterval(()=>{if(document.visibilityState==='visible')refresh();},60000);
})();
