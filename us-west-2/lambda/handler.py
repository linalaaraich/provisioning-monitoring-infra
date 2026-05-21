"""
Lambda autoshutoff gateway for the us-west-2 GPU triage instance.

Two entry points exported from a single module so we can zip-deploy one
artifact and select via the Lambda `handler` setting:

    lambda_handler_router      — fronted by API Gateway HTTP API
    lambda_handler_idle_check  — fired every 5 min by EventBridge

Design notes:

- Both handlers are idempotent. The router uses a DDB conditional update
  to claim a "starting" lock so two concurrent webhooks don't both call
  StartInstances. The idle checker re-reads DDB after StopInstances to
  avoid racing a freshly-arrived webhook.
- The router forwards live traffic to the instance via private IP. We
  set a 25 s HTTP client timeout — the triage service queues async and
  returns in ms, so any hang implies the host is half-up. On hang we
  return 502 to the caller (NOT Lambda timeout) so Grafana sees a clean
  error instead of an API GW 504.
- urllib stdlib only — no `requests` layer needed.
- ISO8601 strings in DDB (not epoch ints) so a human can read the table
  in the console during incident triage.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

import boto3
from botocore.exceptions import ClientError

# -----------------------------------------------------------------------------
# Config (env-injected by Terraform)
# -----------------------------------------------------------------------------
INSTANCE_ID = os.environ["INSTANCE_ID"]
INSTANCE_PRIVATE_IP = os.environ["INSTANCE_PRIVATE_IP"]
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
DDB_TABLE = os.environ["DDB_TABLE"]
IDLE_THRESHOLD_MIN = int(os.environ.get("IDLE_THRESHOLD_MIN", "20"))

# IP allowlist — comma-separated /32 CIDRs of callers permitted to hit the
# API Gateway. Anything not in this set gets a 403 before any AWS work.
# Sourced from env var so updates don't require a Lambda redeploy.
# Default is empty -> "deny all" (safer fail-closed than fail-open).
ALLOWED_SOURCE_IPS = {
    ip.strip().split("/")[0]
    for ip in os.environ.get("ALLOWED_SOURCE_IPS", "").split(",")
    if ip.strip()
}

FORWARD_PORT = 8090
FORWARD_PATH = "/webhook/grafana"
FORWARD_TIMEOUT_S = 25
STATE_KEY = "singleton"

# -----------------------------------------------------------------------------
# Module-level clients (reused across warm invocations)
# -----------------------------------------------------------------------------
log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
sqs = boto3.client("sqs")
ddb = boto3.client("dynamodb")


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _describe_instance_state() -> str:
    """Return the AWS-reported instance state: pending|running|stopping|stopped|..."""
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0]["State"]["Name"]


def _ddb_get_state() -> dict[str, Any]:
    resp = ddb.get_item(
        TableName=DDB_TABLE,
        Key={"id": {"S": STATE_KEY}},
        ConsistentRead=True,
    )
    return resp.get("Item", {})


def _ddb_record_traffic() -> None:
    ddb.update_item(
        TableName=DDB_TABLE,
        Key={"id": {"S": STATE_KEY}},
        UpdateExpression="SET last_traffic_at = :t, instance_state = :s",
        ExpressionAttributeValues={
            ":t": {"S": _now_iso()},
            ":s": {"S": "running"},
        },
    )


def _ddb_try_claim_cold_start() -> bool:
    """
    Conditional-update lock: only one concurrent invocation wins the
    right to call ec2:StartInstances. The condition is
        (instance_state attr missing) OR (instance_state != "starting")
    so a second webhook arriving 50 ms later sees the "starting" state
    and skips the API call — just queues to SQS.
    """
    try:
        ddb.update_item(
            TableName=DDB_TABLE,
            Key={"id": {"S": STATE_KEY}},
            UpdateExpression="SET instance_state = :starting, cold_start_began_at = :t",
            ConditionExpression="attribute_not_exists(instance_state) OR instance_state <> :starting",
            ExpressionAttributeValues={
                ":starting": {"S": "starting"},
                ":t": {"S": _now_iso()},
            },
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _ddb_mark_stopped() -> None:
    ddb.update_item(
        TableName=DDB_TABLE,
        Key={"id": {"S": STATE_KEY}},
        UpdateExpression="SET instance_state = :s",
        ExpressionAttributeValues={":s": {"S": "stopped"}},
    )


def _forward_to_instance(body: bytes, headers: dict[str, str]) -> dict[str, Any]:
    """
    POST the payload through to the instance on its private IP. Returns a
    response dict suitable for API Gateway. On any transport-level error
    (timeout, connection refused, half-open socket) we return 502 with a
    diagnostic body — the Lambda itself does NOT propagate the error so
    Grafana retries against a clean status code instead of API GW 504.
    """
    url = f"http://{INSTANCE_PRIVATE_IP}:{FORWARD_PORT}{FORWARD_PATH}"
    # Strip hop-by-hop headers and anything API GW set on the inbound side.
    forward_headers = {
        "Content-Type": headers.get("content-type", "application/json"),
        "X-Forwarded-By": "triage-gateway-router",
    }
    req = urllib_request.Request(url, data=body, headers=forward_headers, method="POST")
    try:
        with urllib_request.urlopen(req, timeout=FORWARD_TIMEOUT_S) as resp:
            return {
                "statusCode": resp.status,
                "headers": {"Content-Type": "application/json"},
                "body": resp.read().decode("utf-8", errors="replace"),
            }
    except urllib_error.HTTPError as e:
        # Instance returned a non-2xx — pass it through verbatim.
        return {
            "statusCode": e.code,
            "headers": {"Content-Type": "application/json"},
            "body": e.read().decode("utf-8", errors="replace"),
        }
    except (urllib_error.URLError, TimeoutError, ConnectionError) as e:
        log.warning("forward to %s failed: %s", url, e)
        return {
            "statusCode": 502,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "instance_unreachable", "detail": str(e)}),
        }


def _enqueue_for_cold_start(raw_body: str, headers: dict[str, str]) -> None:
    payload = {
        "body": raw_body,
        "headers": {k.lower(): v for k, v in headers.items() if k.lower() == "content-type"},
        "queued_at": _now_iso(),
    }
    sqs.send_message(QueueUrl=SQS_QUEUE_URL, MessageBody=json.dumps(payload))


# -----------------------------------------------------------------------------
# Entry point: gateway router
# -----------------------------------------------------------------------------
def lambda_handler_router(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Handles API Gateway HTTP API v2 events. Two paths:

    1. Instance is running -> forward, update last_traffic_at, return upstream response.
    2. Instance is NOT running -> push to SQS, claim start-lock (idempotent),
       call ec2:StartInstances if we won the lock, return 202 Accepted.

    All paths are gated by an IP allowlist (ALLOWED_SOURCE_IPS env var).
    """
    # Source-IP allowlist gate — fail closed.
    source_ip = (event.get("requestContext", {}).get("http", {}).get("sourceIp") or "")
    if source_ip not in ALLOWED_SOURCE_IPS:
        log.warning("router blocked: source_ip=%s not in allowlist", source_ip)
        return {
            "statusCode": 403,
            "headers": {"Content-Type": "application/json"},
            "body": '{"error": "source IP not permitted"}',
        }

    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw_body = base64.b64decode(raw_body).decode("utf-8", errors="replace")
    headers = event.get("headers") or {}

    state = _describe_instance_state()
    log.info("router invoked, source_ip=%s, instance state=%s", source_ip, state)

    if state == "running":
        # Hot path — forward then bookkeep. Order matters: if forward succeeds
        # we definitely want last_traffic_at bumped, but if forward fails with
        # 502 we ALSO bump it (the instance is up, just unhappy — don't let
        # the idle checker stop it mid-incident).
        resp = _forward_to_instance(raw_body.encode("utf-8"), headers)
        try:
            _ddb_record_traffic()
        except ClientError as e:
            log.warning("ddb update_item failed (non-fatal): %s", e)
        return resp

    # Cold-start path.
    # Always enqueue FIRST — even if StartInstances ends up failing, the
    # message is durable in SQS and the next idle-checker tick or manual
    # restart will drain it.
    _enqueue_for_cold_start(raw_body, headers)

    if state in ("stopped", "stopping"):
        if _ddb_try_claim_cold_start():
            try:
                ec2.start_instances(InstanceIds=[INSTANCE_ID])
                log.info("ec2:StartInstances issued for %s", INSTANCE_ID)
            except ClientError as e:
                # Common race: instance already transitioned to pending between
                # describe_instances and start_instances. Treat as success.
                if e.response["Error"]["Code"] in ("IncorrectInstanceState",):
                    log.info("start raced with state change: %s", e)
                else:
                    log.error("ec2:StartInstances failed: %s", e)
                    # Don't 500 — the message is in SQS, drain_queue.py will
                    # pick it up once the instance comes back by any means.
        else:
            log.info("cold start already in progress, payload queued only")

    return {
        "statusCode": 202,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "status": "accepted",
                "detail": "instance cold start in progress; payload queued to SQS",
                "instance_state": state,
            }
        ),
    }


# -----------------------------------------------------------------------------
# Entry point: idle checker
# -----------------------------------------------------------------------------
def lambda_handler_idle_check(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Fired by EventBridge every 5 min. Stops the instance if BOTH:
      - AWS reports state=running
      - DDB last_traffic_at is older than IDLE_THRESHOLD_MIN

    Note: we deliberately do not stop if state is "pending" / "stopping" —
    those mean StartInstances or a previous stop is mid-flight. Stopping
    a pending instance is allowed by EC2 but would defeat a cold-start
    that's already underway.
    """
    state = _describe_instance_state()
    if state != "running":
        log.info("idle check skip: state=%s", state)
        return {"action": "skip", "reason": f"state={state}"}

    item = _ddb_get_state()
    last_iso = item.get("last_traffic_at", {}).get("S")
    if not last_iso:
        # No traffic ever recorded but the instance is up — likely a manual
        # start. Don't stop on the first tick; the operator may be debugging.
        # Stamp a traffic marker so the NEXT tick has something to compare.
        log.info("idle check: no last_traffic_at, stamping now and deferring")
        _ddb_record_traffic()
        return {"action": "skip", "reason": "no_prior_traffic_marker"}

    last_dt = datetime.fromisoformat(last_iso)
    age = datetime.now(timezone.utc) - last_dt
    if age < timedelta(minutes=IDLE_THRESHOLD_MIN):
        log.info("idle check: last traffic %.1f min ago, below threshold", age.total_seconds() / 60)
        return {"action": "skip", "reason": "within_threshold", "age_min": age.total_seconds() / 60}

    log.info("idle threshold exceeded (%.1f min), stopping instance %s", age.total_seconds() / 60, INSTANCE_ID)
    try:
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        _ddb_mark_stopped()
    except ClientError as e:
        log.error("ec2:StopInstances failed: %s", e)
        return {"action": "error", "error": str(e)}

    return {"action": "stopped", "age_min": age.total_seconds() / 60}
