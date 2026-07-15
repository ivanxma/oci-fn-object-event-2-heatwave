"""OCI Function handler for Object Storage CloudEvents."""
from __future__ import annotations

import io
import json
import os
from datetime import UTC, datetime
from typing import Any

import mysql.connector
from fdk import response


def _setting(name: str, *, required: bool = True, default: str | None = None) -> str | None:
    value = os.getenv(name, default)
    if required and not value:
        raise ValueError(f"Missing required function configuration: {name}")
    return value


def _event_summary(event: dict[str, Any]) -> dict[str, Any]:
    details = event.get("data", {}).get("additionalDetails", {})
    data = event.get("data", {})
    return {
        "eventType": event.get("eventType"),
        "eventId": event.get("id"),
        "compartmentId": data.get("compartmentId"),
        "resourceName": data.get("resourceName"),
        "bucketName": details.get("bucketName"),
        "objectName": details.get("objectName"),
    }


CREATE_EVENT_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS fndb.object_event (
    event_date DATETIME(6) NOT NULL,
    event_type VARCHAR(255) NOT NULL,
    event_message JSON NOT NULL
)
"""


def _event_date(event: dict[str, Any]) -> datetime:
    """Use the producer timestamp when valid; otherwise record current UTC."""
    value = event.get("eventTime")
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC).replace(tzinfo=None)
        except ValueError:
            pass
    return datetime.now(UTC).replace(tzinfo=None)


def handler(ctx: Any, data: io.BytesIO | None = None) -> response.Response:
    try:
        raw_event = data.getvalue().decode("utf-8") if data else "{}"
        event = json.loads(raw_event)
        if not isinstance(event, dict):
            raise ValueError("Expected a JSON Object Storage event object")

        connection = mysql.connector.connect(
            host=_setting("DB_HOST"),
            port=int(_setting("DB_PORT", default="3306") or "3306"),
            user=_setting("DB_USER"),
            password=_setting("DB_PASSWORD"),
            connection_timeout=10,
            ssl_disabled=False,
        )
        try:
            with connection.cursor() as cursor:
                cursor.execute(CREATE_EVENT_TABLE_SQL)
                cursor.execute(
                    "INSERT INTO fndb.object_event (event_date, event_type, event_message) VALUES (%s, %s, %s)",
                    (_event_date(event), str(event.get("eventType", "unknown")), json.dumps(event, separators=(",", ":"))),
                )
            connection.commit()
        finally:
            connection.close()

        payload = {"status": "accepted", "database": "event stored", "event": _event_summary(event)}
        return response.Response(ctx, response_data=json.dumps(payload), headers={"Content-Type": "application/json"}, status_code=200)
    except Exception as exc:  # Return a safe message; never disclose DB credentials.
        payload = {"status": "error", "message": str(exc)}
        return response.Response(ctx, response_data=json.dumps(payload), headers={"Content-Type": "application/json"}, status_code=500)
