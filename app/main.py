# app/main.py
from fastapi import FastAPI
from app.controller import predict_controller

app = FastAPI()
app.include_router(predict_controller.router)
