# app/model/bitcoin_input.py
from pydantic import BaseModel

class BitcoinInput(BaseModel):
    weeks: int
