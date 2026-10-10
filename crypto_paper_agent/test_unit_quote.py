import unittest
from decimal import Decimal
from paper_agent import Pool, unit_quote, measure_candidate

class TestOneUnitQuotes(unittest.TestCase):
    def setUp(self):
        self.a = Pool('Buy', '0x'+'0'*40, 30, 200_000*10**6, 100*10**18)
        self.b = Pool('Sell','0x'+'1'*40, 30, 210_000*10**6, 100*10**18)
    def test_buy_and_sell_include_fee_and_impact(self):
        buy, sell = unit_quote(self.a, self.b, 6)
        self.assertGreater(Decimal(buy), Decimal('2000'))
        self.assertLess(Decimal(sell), Decimal('2100'))
    def test_no_one_unit_quote_if_pool_too_small(self):
        p = Pool('tiny','x',30,10**6,10**18)
        self.assertEqual(unit_quote(p,self.b,6), ('',''))
    def test_no_live_trade_assertion(self):
        v=measure_candidate(chain='bsc',buy=self.a,sell=self.b,amount_stable_units=1000*10**6,
            stable_decimals=6,native_usd=Decimal('2000'),gas_wei=10**9,gas_units=400000,
            flash_premium_bps=9,extra_buffer_bps=30,min_profit_bps=50,min_profit_usd=Decimal('1'),
            usd_inr=Decimal('90'),block_number=100,now='2026-10-10T12:00:00+00:00',
            source='PUBLIC_RPC_READ_ONLY_SAME_BLOCK_RESERVES',unit_symbol='WBNB')
        self.assertEqual(v['unit_symbol'],'WBNB')
        self.assertEqual(v['actual_transaction'],'NONE')
        self.assertNotEqual(v['unit_buy_usd'],'')
