import yfinance as yf
import pandas as pd
from datetime import datetime, timedelta

def fetch_bitcoin_data(weeks):
    end_date = datetime.now()
    start_date = end_date - timedelta(weeks=weeks)
    try:
        data = yf.download("BTC-USD", start=start_date, end=end_date, interval="1d", progress=False)
        data = data[['Close']].dropna()
        return data
    except Exception as e:
        print("Error fetching data:", e)
        return None
