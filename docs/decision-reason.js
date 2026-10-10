/* Paper-only verdict explanations. Never authorizes a transaction. */
(function (root) {
  'use strict';
  function money(value) {
    const amount = Number(value);
    if (!Number.isFinite(amount)) return null;
    const abs = Math.abs(amount).toFixed(2);
    return `${amount < 0 ? '−' : '+'}$${abs}`;
  }
  function explain(row) {
    if (!row || row.actual_transaction !== 'NONE' || row.realized_profit_inr !== 'NOT_MEASURED') {
      return 'Unavailable: not a verified paper-only observation';
    }
    if (row.verdict === 'SKIP_NO_LIQUIDITY') {
      return 'Rejected: insufficient liquidity for this route';
    }
    const gross = Number(row.gross_spread_usd);
    const net = Number(row.estimated_net_usd);
    const minimum = Number(row.min_profit_usd);
    if (![gross, net, minimum].every(Number.isFinite) || minimum < 0) {
      return 'Unavailable: incomplete or invalid price/fee estimate';
    }
    if (row.verdict === 'HYPOTHETICAL_CANDIDATE_NOT_EXECUTED') {
      if (net <= minimum) return 'Unavailable: candidate conflicts with profit threshold';
      return `Paper candidate: ${money(net)} net > ${money(minimum)} minimum; not traded`;
    }
    if (row.verdict !== 'SKIP_NOT_PROFITABLE_ENOUGH') {
      return 'Unavailable: unrecognized paper decision';
    }
    if (gross < 0) return `Rejected: route loses $${Math.abs(gross).toFixed(2)} before costs`;
    if (net <= 0) return `Rejected: fees and risk buffer erase spread (${money(net)} net)`;
    if (net <= minimum) return `Rejected: ${money(net)} net ≤ ${money(minimum)} minimum`;
    return 'Unavailable: rejection conflicts with profit threshold';
  }
  const api = Object.freeze({explain});
  if (root) root.PaperDecision = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : undefined);
