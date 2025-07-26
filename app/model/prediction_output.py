# app/model/prediction_output.py
from pydantic import BaseModel
from typing import Optional

class PredictionOutput(BaseModel):
    recommended_buy_date: Optional[str]
    recommended_sell_date: Optional[str]
    expected_profit_percentage: Optional[float]
    message: str
