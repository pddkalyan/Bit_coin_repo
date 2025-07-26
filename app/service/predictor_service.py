# app/service/predictor_service.py
import datetime
import random
from app.model.prediction_output import PredictionOutput

def predict_bitcoin(weeks: int) -> PredictionOutput:
    try:
        today = datetime.date.today()
        buy_date = today + datetime.timedelta(weeks=random.randint(1, weeks))
        sell_date = buy_date + datetime.timedelta(weeks=random.randint(1, weeks))
        profit = round(random.uniform(5.0, 25.0), 2)

        return PredictionOutput(
            recommended_buy_date=str(buy_date),
            recommended_sell_date=str(sell_date),
            expected_profit_percentage=profit,
            message="Prediction generated successfully"
        )
    except Exception as e:
        print("Error in prediction:", e)
        raise
