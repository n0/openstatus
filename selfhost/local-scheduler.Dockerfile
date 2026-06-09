FROM python:3.12-alpine
WORKDIR /app
COPY selfhost/local-scheduler.py /app/local-scheduler.py
CMD ["python", "/app/local-scheduler.py"]
