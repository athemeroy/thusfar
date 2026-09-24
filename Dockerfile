# Thusfar web reader: the Python standard library is the whole dependency tree.
FROM python:3.12-slim
WORKDIR /app
COPY pipeline ./pipeline
COPY server ./server
COPY web ./web
COPY scripts ./scripts
ENV DATA_DIR=/data \
    PYTHONUNBUFFERED=1 \
    AUTO_PROCESS=0 \
    COOKIE_SECURE=0
VOLUME ["/data"]
EXPOSE 18770
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18770/healthz', timeout=4)"
CMD ["python", "-m", "server.app", "--host", "0.0.0.0", "--port", "18770"]
