import unittest
from decimal import Decimal
from unittest.mock import patch
from paper_agent import (ALLOWED_RPC, NETWORKS, Pool, ReadOnlyRPC, amount_out,
                         build_get_pair, check_address, demo_pools, ensure_rpc_url,
                         measure_candidate, native_price_stable, parse_reserves, quote_direction)

class TestSafety(unittest.TestCase):
    def test_write_methods_explicitly_refused(self):
        client = ReadOnlyRPC('https://polygon-bor-rpc.publicnode.com')
        for method in ('eth_sendRawTransaction','eth_sendTransaction','personal_sign','eth_sign',
                       'eth_signTransaction', 'wallet_sendTransaction'):
            with self.assertRaises(PermissionError):
                client.call(method, [])

    def test_eth_call_rejects_unknown_selector(self):
        client = ReadOnlyRPC('https://polygon-bor-rpc.publicnode.com')
        with self.assertRaises(PermissionError):
            client.call('eth_call', [{'to': NETWORKS['polygon']['stable'], 'data': '0xa9059cbb'}, 'latest'])

    def test_does_not_call_network_for_blocked_methods(self):
        client = ReadOnlyRPC('https://polygon-bor-rpc.publicnode.com')
        with patch('paper_agent.urlopen') as req:
            with self.assertRaises(PermissionError):
                client.call('eth_sendRawTransaction', ['0xdeadbeef'])
            req.assert_not_called()

    def test_credentials_url_rejected(self):
        with self.assertRaises(ValueError):
            ensure_rpc_url('https://user:password@rpc.example.org')
        with self.assertRaises(ValueError):
            ensure_rpc_url('http://evil.example.org')

    def test_supported_address_lengths(self):
        for config in NETWORKS.values():
            for address in [config['stable'],config['wrapped']] + [d['factory'] for d in config['dexes']]:
                self.assertEqual(len(check_address(address)),42)

class TestMath(unittest.TestCase):
    def test_fee_reduces_output(self):
        full = amount_out(1000, 1000000, 1000000, 0)
        with_fee = amount_out(1000, 1000000, 1000000, 30)
        self.assertLess(with_fee,full)

    def test_identical_pools_are_unprofitable(self):
        p=demo_pools()[0]
        w,output=quote_direction(p,p,1000*10**6)
        self.assertLess(output,1000*10**6)

    def test_reserves_decode(self):
        x = '0x'+ format(123,'064x') + format(456,'064x')+format(100,'064x')
        self.assertEqual(parse_reserves(x),(123,456))

    def test_route_reports_hypothetical_only(self):
        pools=demo_pools()
        v=measure_candidate(chain='demo',buy=pools[0],sell=pools[1],amount_stable_units=1000*10**6,
            stable_decimals=6,native_usd=native_price_stable(pools,6),gas_wei=3_000_000_000,
            gas_units=400000,flash_premium_bps=9,extra_buffer_bps=30,min_profit_bps=50,
            min_profit_usd=Decimal('1'),usd_inr=Decimal('90'),block_number=0,now='TEST',source='SYNTHETIC')
        self.assertEqual(v['actual_transaction'],'NONE')
        self.assertEqual(v['realized_profit_inr'],'NOT_MEASURED')
        self.assertEqual(v['source'],'SYNTHETIC')

    def test_high_fees_force_skip(self):
        p=demo_pools()
        v=measure_candidate(chain='demo',buy=p[0],sell=p[1],amount_stable_units=1000*10**6,
            stable_decimals=6,native_usd=Decimal('10'),gas_wei=100_000_000_000,
            gas_units=1_000_000,flash_premium_bps=9,extra_buffer_bps=30,min_profit_bps=50,
            min_profit_usd=Decimal('1'),usd_inr=Decimal('90'),block_number=0,now='TEST',source='SYNTHETIC')
        self.assertEqual(v['verdict'],'SKIP_NOT_PROFITABLE_ENOUGH')

if __name__=='__main__':
    unittest.main(verbosity=2)