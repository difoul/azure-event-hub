# Pin to digest for reproducible builds — update intentionally when upgrading Python
FROM python:3.12-slim@sha256:5072b08ad74609c5329ab4085a96dfa873de565fb4751a4cfcd7dcc427661df0

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

RUN useradd -m -u 1000 appuser && chown -R appuser /app
USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
