# evoscientist-bridge — tiny FastAPI poller that registers evoscientist as
# a Mission Control agent, polls MC's task queue, and drives the
# EvoScientist sidecar container via `docker exec`. Posts the result back
# to MC so the task moves to Done on the Kanban.
FROM python:3.12-slim

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
WORKDIR /app

# docker CLI so the bridge can `docker exec evoscientist …` from inside
# its own container (the host /var/run/docker.sock is bind-mounted in
# docker-compose-evoscientist.yml).
RUN apt-get update \
 && apt-get install -y --no-install-recommends docker.io ca-certificates \
 && apt-get clean \
 && find /var/lib/apt/lists -mindepth 1 -delete

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY bridge.py .
EXPOSE 7920

HEALTHCHECK --interval=30s --timeout=5s --retries=5 --start-period=15s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:7920/healthz').status==200 else 1)"

CMD ["python", "/app/bridge.py"]
