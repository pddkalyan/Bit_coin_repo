# ₹0 cloud paper trading — October 10–17, 2026

This is an **observation tool**, not a trading bot. The original `ArbitrageExecutor` file is not included in the workflow, is not run, and is unchanged.

## Safety and cost

- No wallet, seed phrase, secret, private key, API trading key, payment, contract deployment, transfer, approval, signer, or raw transaction submission.
- Only public RPC read methods, limited to `eth_chainId`, `eth_blockNumber`, `eth_gasPrice` and whitelisted `eth_call` selectors.
- Workflow GitHub token permissions: `contents: read`, `actions: read`. Checkout does not persist credentials.
- Uses `ubuntu-latest` standard runner in **public GitHub repo**; this is free under GitHub's standard hosted runner policy. Public endpoints may fail/rate-limit. No paid third-party RPC.
- End of collection: **2026-10-17 09:00 UTC**. After that date the scheduled workflow triggers but skips jobs' collection steps. Disable the workflow in GitHub Actions to eliminate skipped scheduling after the period.
- Start of collection: **2026-10-10 09:00 UTC** (14:30 IST). Runs 4 times daily at 00:17, 06:17, 12:17, 18:17 UTC (05:47, 11:47, 17:47, 23:47 IST), subject to GitHub scheduler delays or omissions. Total expected observations: ~28 (up to 2 directional quotes per chain per run), if data is available.

## Reporting

Each scheduled or manual run builds an `crypto-paper-cumulative` downloadable artifact from `reports/` containing:

- `observations.csv`: consolidated read-only quotes from the window; no real trades.
- `summary.json`: counts of Polygon/BNB observations, skipped routes, hypothetical candidates.
- `SUMMARY.md`: readable cumulative summary.
- `polygon_log.txt`, `bsc_log.txt`: current run success, errors, missing pools and estimates.
- `polygon_new.csv`, `bsc_new.csv`: latest observations if the configured public pair(s) exist.

View in repository **Actions → Crypto paper monitor — 7 days (NO TRADING) → newest run → Artifacts → crypto-paper-cumulative**. Download the latest artifact, not all prior copies. Final cumulative report is in the latest successful run near the end of the period. GitHub may skip/delay scheduled runs and public RPCs may refuse requests. In that case the records will be incomplete, and `SUMMARY.md` will say so through counts/logs rather than inventing prices/profits.

Data caveats: fixed `--usd-inr 90` (manual assumption), `--gas-units 400000` (assumption), `--flash-premium-bps 9` (assumption), `--virtual-flash-usd 1000` (borrowed hypothetical amount, not user's money). Aave V3 premium may vary; quote is indicative. The monitored *V2 pools only* do not cover all Aave/DEX combinations and do not execute any route. Results do not measure win rate, fill rate, earned profit, ROI, tax or safe custody.

## Local validation

```bash
python3 -m unittest discover -s crypto_paper_agent -p 'test_*.py' -v
python3 crypto_paper_agent/paper_agent.py --demo --once --network polygon --csv demo.csv
```

**Do not use with real capital based on paper results.**