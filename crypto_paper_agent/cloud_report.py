#!/usr/bin/env python3
"""Merge read-only observations; NEVER turn quotes into executed trades.

Pure standard library; no chain transactions or wallet interaction.
"""
from __future__ import annotations
import argparse
import csv
import json
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

START = datetime.fromisoformat('2026-10-10T09:00:00+00:00')
END = datetime.fromisoformat('2026-10-17T09:00:00+00:00')
REQUIRED = {'timestamp_utc', 'network', 'source', 'block', 'buy_from', 'sell_to', 'verdict',
            'estimated_net_inr', 'actual_transaction', 'realized_profit_inr'}


def read_rows(dir_path: Path):
    for fn in sorted(dir_path.glob('*.csv')):
        # Only paper observations; ignore previously generated unrelated CSVs.
        if fn.name not in ('observations.csv', 'polygon_new.csv', 'bsc_new.csv'):
            continue
        with fn.open(newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            if not REQUIRED.issubset(reader.fieldnames or ()):
                continue
            for row in reader:
                # Defense in depth: never allow externally sourced trade/fill claims.
                if row.get('actual_transaction') != 'NONE' or row.get('realized_profit_inr') != 'NOT_MEASURED':
                    continue
                try:
                    dt = datetime.fromisoformat(row['timestamp_utc'].replace('Z','+00:00'))
                    if not START <= dt.astimezone(timezone.utc) < END:
                        continue
                    if row['network'] not in ('polygon','bsc'):
                        continue
                    if row['source'] != 'PUBLIC_RPC_READ_ONLY_SAME_BLOCK_RESERVES':
                        continue
                    Decimal(row['estimated_net_inr'])
                except (ValueError, InvalidOperation, KeyError):
                    continue
                yield row


def merge(previous: Path, current: Path, dest: Path, status: dict|None=None):
    by_key = {}
    for row in [*read_rows(previous), *read_rows(current)]:
        key = (row['network'],row['timestamp_utc'],row['block'],row['buy_from'],row['sell_to'])
        by_key[key] = row
    rows = sorted(by_key.values(), key=lambda r:(r['timestamp_utc'],r['network'],r['buy_from'],r['sell_to']))
    dest.mkdir(parents=True, exist_ok=True)
    columns = ['timestamp_utc','network','source','block','buy_from','sell_to','virtual_flash_usd',
               'unit_symbol','unit_buy_usd','unit_sell_usd','gross_spread_usd','estimated_flash_fee_usd','estimated_gas_usd','extra_risk_buffer_usd',
               'estimated_net_usd','estimated_net_inr','min_profit_usd','verdict','actual_transaction','realized_profit_inr']
    with (dest/'observations.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=columns,extrasaction='ignore'); w.writeheader(); w.writerows(rows)
    candidates=[r for r in rows if r['verdict']=='HYPOTHETICAL_CANDIDATE_NOT_EXECUTED']
    counts=Counter(r['network'] for r in rows)
    verdicts=Counter(r['verdict'] for r in rows)
    summary={
        'report_generated_utc':datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'experiment_start_utc':START.isoformat(), 'experiment_end_utc':END.isoformat(),
        'total_hypothetical_route_quotes':len(rows),
        'network_route_quotes':dict(counts),'verdict_counts':dict(verdicts),
        'hypothetical_candidates_not_executed':len(candidates),
        'real_trades_executed':0, 'realized_pnl_inr':'NOT_MEASURED',
        'virtual_starting_budget_inr':'10000',
        'mode':'READ_ONLY_NOT_EXECUTED',
        'warning':'Estimates are snapshots only; not executable orders, not profits, and not a portfolio return.',
        'samples_this_run':status or {},
        'latest_observation_utc':max((r['timestamp_utc'] for r in rows),default=None),
    }
    (dest/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    summary_md=(
      '# 7-day Polygon + BNB crypto paper monitoring\n\n'
      f"Generated: {summary['report_generated_utc']}\n\n"
      f"Window: {START.isoformat()} through {END.isoformat()} (UTC, end exclusive)\n\n"
      f"- **Real trades: 0**\n- **Realized profit: NOT MEASURED**\n"
      f"- Route observations: {len(rows)} (Polygon {counts['polygon']}, BNB {counts['bsc']})\n"
      f"- Hypothetical candidate quotes: {len(candidates)}\n"
      f"- Latest market observation: {summary['latest_observation_utc'] or 'none'}\n\n"
      '**DO NOT sum hypothetical candidate profits:** they are snapshots of overlapping routes, not fills, '
      'and cannot be interpreted as return on ₹10,000. Gas usage, flash-loan fees, and INR/USD rate are estimates/assumptions. '
      'There is no bundle simulation or live execution verification.\n\n'
      'Files: `observations.csv` (combined history), `summary.json` (machine-readable), '
      '`polygon_new.csv`/`bsc_new.csv` and logs for the current run.\n'
    )
    (dest/'SUMMARY.md').write_text(summary_md,encoding='utf-8')
    return summary


def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--previous',default='previous')
    ap.add_argument('--current',default='reports'); ap.add_argument('--output',default='reports')
    args=ap.parse_args()
    current=Path(args.current)
    stat={}
    for chain in ('polygon','bsc'):
        sf=current/f'{chain}_status.txt'
        stat[chain]=sf.read_text().strip() if sf.exists() else 'NOT_RUN'
    s=merge(Path(args.previous),current,Path(args.output),stat)
    print(json.dumps(s,indent=2))

if __name__=='__main__':main()