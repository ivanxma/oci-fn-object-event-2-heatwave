# OCI Functions custom image, deliberately based on Python 3.13 as required.
FROM python:3.13-slim

WORKDIR /function
COPY requirements.txt .
RUN pip install --no-cache-dir --target /python -r requirements.txt
COPY func.py .
ENV PYTHONPATH=/python
CMD ["/python/bin/fdk", "/function/func.py", "handler"]
