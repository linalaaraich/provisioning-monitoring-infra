#!/usr/bin/env python3
"""
SQS cold-start drainer — runs on the GPU instance as a systemd unit.

Long-polls the triage-cold-start queue and replays each buffered webhook
against the local triage service at http://127.0.0.1:8090/webhook/grafana.

Contract with the Lambda gateway (handler.py::_enqueue_for_cold_start):

    {
      "body":       "<raw JSON Grafana sent>",
      "headers":    {"content-type": "application/json"},
      "queued_at":  "2026-05-21T13:45:12+00:00"
    }

Behaviour:
- 2xx upstream     -> delete the SQS message
- non-2xx / error  -> leave the message; SQS visibility timeout (90s) requeues it
- malformed JSON   -> delete (poison-pill quarantine — better than infinite retry)

Stdlib only except boto3 (already on the instance via the triage container
host, and via apt's `python3-boto3` on Ubuntu 22.04 if running on the host).

Env vars required:
    SQS_QUEUE_URL        — full URL of the cold-start queue
    AWS_DEFAULT_REGION   — us-west-2

Optional:
    DRAIN_LOCAL_URL      — defaults to http://127.0.0.1:8090/webhook/grafana
    DRAIN_POST_TIMEOUT_S — defaults to 25
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
from urllib import error as urllib_error
from urllib import request as urllib_request

import boto3

QUEUE_URL = os.environ["SQS_QUEUE_URL"]
LOCAL_URL = os.environ.get("DRAIN_LOCAL_URL", "http://127.0.0.1:8090/webhook/grafana")
POST_TIMEOUT_S = int(os.environ.get("DRAIN_POST_TIMEOUT_S", "25"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s drain_queue %(levelname)s %(message)s",
)
log = logging.getLogger("drain_queue")

sqs = boto3.client("sqs")

_running = True


def _shutdown(_signum, _frame):  # noqa: ANN001
    global _running
    log.info("shutdown signal received, exiting after current poll")
    _running = False


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)


def _post_local(body: str, content_type: str) -> int:
    req = urllib_request.Request(
        LOCAL_URL,
        data=body.encode("utf-8"),
        headers={"Content-Type": content_type, "X-Forwarded-By": "drain_queue"},
        method="POST",
    )
    try:
        with urllib_request.urlopen(req, timeout=POST_TIMEOUT_S) as resp:
            return resp.status
    except urllib_error.HTTPError as e:
        return e.code
    except (urllib_error.URLError, TimeoutError, ConnectionError) as e:
        log.warning("local POST failed: %s", e)
        return 0


def _handle_message(msg: dict) -> bool:
    """Return True if the message should be deleted from SQS."""
    receipt = msg["ReceiptHandle"]
    try:
        payload = json.loads(msg["Body"])
    except json.JSONDecodeError:
        log.error("dropping malformed message receipt=%s", receipt[:12])
        return True  # poison-pill — delete

    body = payload.get("body", "")
    content_type = payload.get("headers", {}).get("content-type", "application/json")
    queued_at = payload.get("queued_at", "?")

    status = _post_local(body, content_type)
    if 200 <= status < 300:
        log.info("replayed queued_at=%s -> %s", queued_at, status)
        return True
    log.warning("replay failed status=%s queued_at=%s — leaving in queue", status, queued_at)
    return False


def main() -> int:
    log.info("drain_queue starting, queue=%s local=%s", QUEUE_URL, LOCAL_URL)
    while _running:
        try:
            resp = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                VisibilityTimeout=90,
            )
        except Exception as e:  # noqa: BLE001 — never let the loop die
            log.error("receive_message failed: %s — sleeping 5s", e)
            time.sleep(5)
            continue

        messages = resp.get("Messages", [])
        if not messages:
            continue  # long-poll returned empty; loop again

        for msg in messages:
            if _handle_message(msg):
                try:
                    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
                except Exception as e:  # noqa: BLE001
                    log.error("delete_message failed: %s", e)
    log.info("drain_queue exiting cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
