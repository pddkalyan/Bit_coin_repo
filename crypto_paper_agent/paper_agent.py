#!/usr/bin/env python3
"""READ-ONLY cross-DEX V2 arbitrage paper monitor, standard-library only.

SECURITY CONTRACT: No wallets, no signing, no approvals, no raw transaction
submission, no deposits and no transfers. JSON-RPC method allowlist enforced.
No actual profit or transaction is claimed by this program.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, getcontext
import json
import re
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError

getcontext().prec = 56
ZERO = '0x' + '0' * 40
ALLOWED_RPC = frozenset({'eth_chainId', 'eth_blockNumber', 'eth_gasPrice', 'eth_call'})
ALLOWED_SELECTORS = frozenset({'0xe6a43905', '0x0902f1ac', '0x0dfe1681', '0xd21220a7'})
ADDRESS_PATTERN = re.compile(r'^0x[a-fA-F0-9]{40}$')

NETWORKS = {
    'polygon': {
        'chain_id': 137,
        'rpc': 'https://polygon-bor-rpc.publicnode.com',
        'stable': '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359',  # native USDC (6 decimals)
        'stable_symbol': 'USDC', 'stable_decimals': 6,
        'wrapped': '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270',  # WPOL / legacy WMATIC address
        'native_symbol': 'POL', 'native_decimals': 18,
        'dexes': [
            {'name': 'QuickSwap V2', 'factory': '0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32', 'fee_bps': 30},
            {'name': 'SushiSwap V2', 'factory': '0xc35DADB65012eC5796536bD9864eD8773aBc74C4', 'fee_bps': 30},
        ],
    },
    'bsc': {
        'chain_id': 56,
        'rpc': 'https://bsc-dataseed.bnbchain.org',
        'stable': '0x55d398326f99059fF775485246999027B3197955',  # BSC USDT (18 decimals)
        'stable_symbol': 'USDT', 'stable_decimals': 18,
        'wrapped': '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',  # WBNB
        'native_symbol': 'BNB', 'native_decimals': 18,
        'dexes': [
            {'name': 'PancakeSwap V2', 'factory': '0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73', 'fee_bps': 25},
            {'name': 'SushiSwap V2', 'factory': '0xc35DADB65012eC5796536bD9864eD8773aBc74C4', 'fee_bps': 30},
        ],
    },
}


def check_address(address: str) -> str:
    if not ADDRESS_PATTERN.fullmatch(address):
        raise ValueError('Invalid EVM contract address')
    return address.lower()


def encoded_address(address: str) -> str:
    return check_address(address)[2:].rjust(64, '0')


def build_get_pair(token_a: str, token_b: str) -> str:
    return '0xe6a43905' + encoded_address(token_a) + encoded_address(token_b)


def ensure_rpc_url(url: str) -> None:
    from urllib.parse import urlsplit
    p = urlsplit(url)
    if p.scheme != 'https' and not (p.scheme == 'http' and p.hostname in ('127.0.0.1', 'localhost')):
        raise ValueError('RPC must be HTTPS, or localhost for offline testing')
    if p.username or p.password or not p.netloc:
        raise ValueError('No credentials in RPC URL: use a public endpoint')


class ReadOnlyRPC:
    def __init__(self, url: str):
        ensure_rpc_url(url)
        self.url = url

    def call(self, method: str, params: list):
        if method not in ALLOWED_RPC:
            raise PermissionError(f'BLOCKED WRITE/UNKNOWN METHOD: {method}')
        if method == 'eth_call':
            if not isinstance(params, list) or len(params) != 2:
                raise ValueError('eth_call must include a call and block tag')
            target = params[0]
            if not isinstance(target, dict) or set(target) != {'to', 'data'}:
                raise ValueError('Only minimal read-only contract calls permitted')
            check_address(target['to'])
            if target['data'][:10] not in ALLOWED_SELECTORS:
                raise PermissionError('BLOCKED UNRECOGNIZED FUNCTION SELECTOR')
        payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
        req = Request(self.url, data=payload, headers={'Content-Type': 'application/json', 'User-Agent': 'ReadOnlyPaperArb/1.0'}, method='POST')
        with urlopen(req, timeout=16) as response:
            data = json.load(response)
        if 'error' in data:
            raise RuntimeError(f'RPC error on {method}: {data["error"]}')
        if 'result' not in data:
            raise RuntimeError(f'RPC result missing: {method}')
        return data['result']

    def view(self, to: str, selector_and_args: str, block_tag: str) -> str:
        return self.call('eth_call', [{'to': check_address(to), 'data': selector_and_args}, block_tag])


def parse_address(raw_hex: str) -> str:
    if not isinstance(raw_hex, str) or not raw_hex.startswith('0x') or len(raw_hex) < 42:
        raise ValueError('Invalid getPair response')
    return check_address('0x' + raw_hex[-40:])


def parse_reserves(raw_hex: str) -> tuple[int, int]:
    if not isinstance(raw_hex, str) or not raw_hex.startswith('0x') or len(raw_hex) < 130:
        raise ValueError('Invalid getReserves response')
    data = raw_hex[2:]
    return int(data[0:64], 16), int(data[64:128], 16)


@dataclass(frozen=True)
class Pool:
    name: str
    pair: str
    fee_bps: int
    reserve_stable: int
    reserve_wrapped: int


def discover_pool(rpc: ReadOnlyRPC, network: dict, dex: dict, block: str) -> Pool | None:
    pair = parse_address(rpc.view(dex['factory'], build_get_pair(network['stable'], network['wrapped']), block))
    if pair == ZERO:
        return None
    t0 = parse_address(rpc.view(pair, '0x0dfe1681', block))
    t1 = parse_address(rpc.view(pair, '0xd21220a7', block))
    if {t0, t1} != {check_address(network['stable']), check_address(network['wrapped'])}:
        raise ValueError(f'Pair token mismatch for {dex["name"]}: {pair}')
    r0, r1 = parse_reserves(rpc.view(pair, '0x0902f1ac', block))
    stable0 = t0 == check_address(network['stable'])
    reserve_stable, reserve_wrapped = (r0, r1) if stable0 else (r1, r0)
    if reserve_stable <= 0 or reserve_wrapped <= 0:
        return None
    return Pool(dex['name'], pair, dex['fee_bps'], reserve_stable, reserve_wrapped)


def amount_out(amount_in: int, reserve_in: int, reserve_out: int, fee_bps: int) -> int:
    if amount_in <= 0 or reserve_in <= 0 or reserve_out <= 0 or not 0 <= fee_bps < 10000:
        raise ValueError('Invalid swap input/reserves/fee')
    effective = amount_in * (10000 - fee_bps)
    return (effective * reserve_out) // (reserve_in * 10000 + effective)


def quote_direction(buy: Pool, sell: Pool, amount_stable_units: int) -> tuple[int, int]:
    wrapped = amount_out(amount_stable_units, buy.reserve_stable, buy.reserve_wrapped, buy.fee_bps)
    if wrapped <= 0:
        return (0, 0)
    stable_back = amount_out(wrapped, sell.reserve_wrapped, sell.reserve_stable, sell.fee_bps)
    return wrapped, stable_back


def native_price_stable(pools: list[Pool], stable_decimals: int) -> Decimal:
    # Estimated spot price of 1 wrapped native asset from the most liquid pool.
    best = max(pools, key=lambda p: p.reserve_stable)
    return ((Decimal(best.reserve_stable) / (10 ** stable_decimals)) /
            (Decimal(best.reserve_wrapped) / Decimal(10**18)))


def unit_quote(buy: Pool, sell: Pool, stable_decimals: int) -> tuple[str, str]:
    """Quote buying/selling exactly 1 wrapped native token against sampled V2 reserves.

    Buy uses exact-output required input. Sell uses exact-input output.
    Pool fees/price impact included; gas/flash loan charges excluded.
    """
    unit = 10 ** 18
    if buy.reserve_wrapped <= unit:
        return '', ''
    denominator = (buy.reserve_wrapped - unit) * (10000 - buy.fee_bps)
    if denominator <= 0:
        return '', ''
    stable_for_buy = (buy.reserve_stable * unit * 10000) // denominator + 1
    stable_from_sell = amount_out(unit, sell.reserve_wrapped, sell.reserve_stable, sell.fee_bps)
    decimals = Decimal(10 ** stable_decimals)
    return f'{Decimal(stable_for_buy)/decimals:.8f}', f'{Decimal(stable_from_sell)/decimals:.8f}'


def measure_candidate(*, chain: str, buy: Pool, sell: Pool, amount_stable_units: int,
                      stable_decimals: int, native_usd: Decimal, gas_wei: int,
                      gas_units: int, flash_premium_bps: int, extra_buffer_bps: int,
                      min_profit_bps: int, min_profit_usd: Decimal, usd_inr: Decimal,
                      block_number: int, now: str, source: str, unit_symbol: str = 'NATIVE') -> dict:
    wrapped, stable_back = quote_direction(buy, sell, amount_stable_units)
    unit_buy, unit_sell = unit_quote(buy, sell, stable_decimals)
    unit = Decimal(10 ** stable_decimals)
    borrowed_usd = Decimal(amount_stable_units) / unit
    proceeds_usd = Decimal(stable_back) / unit
    gross_usd = proceeds_usd - borrowed_usd  # DEX trading fees already in AMM quote
    loan_fee_usd = borrowed_usd * Decimal(flash_premium_bps) / Decimal(10000)
    gas_usd = (Decimal(gas_wei) * Decimal(gas_units) / Decimal(10**18)) * native_usd
    buffer_usd = borrowed_usd * Decimal(extra_buffer_bps) / Decimal(10000)
    expected_usd = gross_usd - loan_fee_usd - gas_usd - buffer_usd
    minimum_usd = max(min_profit_usd, borrowed_usd * Decimal(min_profit_bps) / Decimal(10000))
    if wrapped <= 0:
        verdict = 'SKIP_NO_LIQUIDITY'
    elif expected_usd <= minimum_usd:
        verdict = 'SKIP_NOT_PROFITABLE_ENOUGH'
    else:
        verdict = 'HYPOTHETICAL_CANDIDATE_NOT_EXECUTED'
    return {
        'timestamp_utc': now, 'network': chain, 'source': source,
        'block': block_number, 'buy_from': buy.name, 'sell_to': sell.name,
        'unit_symbol': unit_symbol, 'unit_buy_usd': unit_buy, 'unit_sell_usd': unit_sell,
        'virtual_flash_usd': f'{borrowed_usd:.2f}',
        'gross_spread_usd': f'{gross_usd:.4f}',
        'estimated_flash_fee_usd': f'{loan_fee_usd:.4f}',
        'estimated_gas_usd': f'{gas_usd:.4f}',
        'extra_risk_buffer_usd': f'{buffer_usd:.4f}',
        'estimated_net_usd': f'{expected_usd:.4f}',
        'estimated_net_inr': f'{(expected_usd * usd_inr):.2f}',
        'min_profit_usd': f'{minimum_usd:.4f}', 'verdict': verdict,
        'actual_transaction': 'NONE', 'realized_profit_inr': 'NOT_MEASURED',
    }


def write_csv(rows: list[dict], path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        return
    exists = path.exists() and path.stat().st_size > 0
    with path.open('a', newline='', encoding='utf-8') as fp:
        writer = csv.DictWriter(fp, fieldnames=list(rows[0]))
        if not exists:
            writer.writeheader()
        writer.writerows(rows)


def demo_pools() -> list[Pool]:
    # ALL TEST VALUES ARE SYNTHETIC. No market data is implied.
    d = 10**6
    w = 10**18
    return [
        Pool('FAKE_QUICK_V2', ZERO, 30, 3_000_000*d, 1_000_000*w),
        Pool('FAKE_SUSHI_V2', ZERO, 30, 3_010_000*d, 1_000_000*w),
    ]


def run(args) -> list[dict]:
    config = NETWORKS[args.network]
    usd_inr = Decimal(args.usd_inr)
    if args.virtual_flash_usd <= 0 or args.gas_units <= 0 or args.flash_premium_bps < 0 or args.extra_buffer_bps < 0:
        raise ValueError('Invalid virtual budget, gas, or fee assumptions')
    now = datetime.now(timezone.utc).isoformat(timespec='seconds')
    source = 'SYNTHETIC_DEMO'
    if args.demo:
        pools = demo_pools()
        block, gas_price_wei = 0, 3_000_000_000
        stable_decimals = 6
        chain = 'demo'
    else:
        rpc = ReadOnlyRPC(args.rpc or config['rpc'])
        reported_chain = int(rpc.call('eth_chainId', []), 16)
        if reported_chain != config['chain_id']:
            raise ValueError(f'WRONG NETWORK: expected {config["chain_id"]}, got {reported_chain}')
        block = int(rpc.call('eth_blockNumber', []), 16)
        blocktag = hex(block)
        gas_price_wei = int(rpc.call('eth_gasPrice', []), 16)
        pools = [p for dex in config['dexes'] if (p := discover_pool(rpc, config, dex, blocktag))]
        stable_decimals = config['stable_decimals']
        chain = args.network
        source = 'PUBLIC_RPC_READ_ONLY_SAME_BLOCK_RESERVES'
    if len(pools) < 2:
        print(f'[{chain}] No two usable V2 pools found. Nothing to simulate.')
        return []
    native_usd = native_price_stable(pools, stable_decimals)
    virtual_flash_units = int(Decimal(args.virtual_flash_usd) * (10 ** stable_decimals))
    rows = []
    for buy in pools:
        for sell in pools:
            if buy.name == sell.name:
                continue
            rows.append(measure_candidate(
                chain=chain, buy=buy, sell=sell, amount_stable_units=virtual_flash_units,
                stable_decimals=stable_decimals, native_usd=native_usd, gas_wei=gas_price_wei,
                gas_units=args.gas_units, flash_premium_bps=args.flash_premium_bps,
                extra_buffer_bps=args.extra_buffer_bps, min_profit_bps=args.min_profit_bps,
                min_profit_usd=Decimal(args.min_profit_usd), usd_inr=usd_inr,
                block_number=block, now=now, source=source, unit_symbol=config['native_symbol'],
            ))
    write_csv(rows, Path(args.csv))
    print(f'[{chain}] block={block}, fee quote={gas_price_wei / 1e9:.4f} gwei, '
          f'approx native price={native_usd:.5f} USD; {len(rows)} hypothetical routes')
    for row in rows:
        print(f"  {row['buy_from']} -> {row['sell_to']}: "
              f"net {row['estimated_net_usd']} USD ({row['estimated_net_inr']} INR) "
              f"{row['verdict']}")
    print('NO TRANSACTIONS SENT. NO WALLET USED. RESULTS ARE ESTIMATES, NOT REALIZED PROFIT.')
    return rows


def build_parser():
    p = argparse.ArgumentParser(description='Read-only V2 arbitrage paper-trading monitor. NEVER trades.')
    p.add_argument('--network', choices=NETWORKS.keys(), default='polygon')
    p.add_argument('--rpc', help='Optional PUBLIC HTTPS JSON-RPC endpoint, no keys or credentials')
    p.add_argument('--demo', action='store_true', help='Synthetic offline demonstration; NEVER live prices')
    p.add_argument('--once', action='store_true', help='Run one sample then exit (default)')
    p.add_argument('--loop', action='store_true', help='Repeat sampling until stopped')
    p.add_argument('--interval-seconds', type=int, default=300, help='At least 60 seconds in loop mode')
    p.add_argument('--virtual-flash-usd', type=Decimal, default=Decimal('1000'), help='Hypothetical borrowed stablecoin amount, not user capital')
    p.add_argument('--virtual-budget-inr', type=Decimal, default=Decimal('10000'), help='Label only: assumed bankroll for gas costs')
    p.add_argument('--usd-inr', type=str, default='90', help='MANUAL hypothetical FX assumption, update when needed')
    p.add_argument('--gas-units', type=int, default=400000, help='CONSERVATIVE ASSUMPTION, not a real gas estimate')
    p.add_argument('--flash-premium-bps', type=int, default=9, help='ASSUMED Aave premium (9bps); verify on-chain before any real use')
    p.add_argument('--extra-buffer-bps', type=int, default=30, help='Risk cushion beyond AMM fees, in basis points')
    p.add_argument('--min-profit-bps', type=int, default=50, help='Mirrors contract 0.5% minimum, on modeled after-gas estimate')
    p.add_argument('--min-profit-usd', type=str, default='1.00', help='Minimum modeled net USD profit')
    p.add_argument('--csv', default='paper_observations.csv')
    return p


def main():
    args = build_parser().parse_args()
    if args.loop and args.interval_seconds < 60:
        raise SystemExit('Refusing sub-60-second sampling to respect free RPC rate limits')
    print('PAPER ONLY: no wallets, deposits, trading API keys or real orders are used.')
    print(f'Virtual starting capital ₹{args.virtual_budget_inr}; this is NOT sent anywhere.')
    while True:
        try:
            run(args)
        except (RuntimeError, ValueError, URLError, TimeoutError, OSError) as e:
            print(f'NO DATA / SKIPPED (not a trade): {type(e).__name__}: {e}', file=sys.stderr)
            if not args.loop:
                return 1
        if not args.loop:
            break
        try:
            time.sleep(args.interval_seconds)
        except KeyboardInterrupt:
            print('Stopped. No transactions were ever sent.')
            break
    return 0


if __name__ == '__main__':
    sys.exit(main())