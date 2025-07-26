# app/controller/predict_controller.py
from fastapi import APIRouter
from app.model.bitcoin_input import BitcoinInput
from app.model.prediction_output import PredictionOutput
from app.service.predictor_service import predict_bitcoin

router = APIRouter()

@router.post("/predict", response_model=PredictionOutput)
def predict(input_data: BitcoinInput):
    return predict_bitcoin(input_data.weeks)
