FROM python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f
RUN pip install --no-cache-dir aiohttp==3.14.4
WORKDIR /app
COPY proxy.py /app/proxy.py
ENV MODEL_FAMILY=glm UPSTREAM_URL=http://vllm:8000
CMD ["python", "/app/proxy.py"]
