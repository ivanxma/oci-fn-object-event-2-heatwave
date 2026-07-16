"""OCI Function handler for Object Storage CloudEvents."""
from __future__ import annotations

import io
import json
import os
import re
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
        "eventId": event.get("eventID") or event.get("id"),
        "compartmentId": data.get("compartmentId"),
        "resourceName": data.get("resourceName"),
        "bucketName": details.get("bucketName"),
        "objectName": details.get("objectName"),
    }


EVENT_COLUMNS = {
    "bucket_name": "VARCHAR(255) NULL",
    "compartment_name": "VARCHAR(255) NULL",
    "resource_name": "TEXT NULL",
    "namespace": "VARCHAR(255) NULL",
    "event_time": "DATETIME(6) NULL",
}


def _mysql_identifier(setting_name: str) -> str:
    """Return a safe MySQL schema or table identifier from Function configuration."""
    name = _setting(setting_name)
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_]{1,64}", name):
        raise ValueError(f"{setting_name} must contain 1-64 letters, digits, or underscores")
    return name


def _event_table(database_name: str, table_name: str) -> str:
    return f"`{database_name}`.`{table_name}`"


def _create_event_table_sql(database_name: str, table_name: str) -> str:
    return f"""
CREATE TABLE IF NOT EXISTS {_event_table(database_name, table_name)} (
    event_date DATETIME(6) NOT NULL,
    event_type VARCHAR(255) NOT NULL,
    event_message JSON NOT NULL,
    bucket_name VARCHAR(255) NULL,
    compartment_name VARCHAR(255) NULL,
    resource_name TEXT NULL,
    namespace VARCHAR(255) NULL,
    event_time DATETIME(6) NULL
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


def _ensure_event_columns(cursor: Any, database_name: str, table_name: str) -> None:
    """Add extracted-event columns when upgrading an existing table."""
    for name, definition in EVENT_COLUMNS.items():
        cursor.execute(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_schema = %s AND table_name = %s AND column_name = %s",
            (database_name, table_name, name),
        )
        if cursor.fetchone() is None:
            cursor.execute(f"ALTER TABLE {_event_table(database_name, table_name)} ADD COLUMN `{name}` {definition}")


def _event_fields(event: dict[str, Any]) -> tuple[str | None, str | None, str | None, str | None]:
    data = event.get("data", {})
    details = data.get("additionalDetails", {})
    return (
        details.get("bucketName"),
        data.get("compartmentName"),
        data.get("resourceName"),
        details.get("namespace") or data.get("namespace"),
    )


def handler(ctx: Any, data: io.BytesIO | None = None) -> response.Response:
    try:
        raw_event = data.getvalue().decode("utf-8") if data else "{}"
        event = json.loads(raw_event)
        if not isinstance(event, dict):
            raise ValueError("Expected a JSON Object Storage event object")

        database_name = _mysql_identifier("DB_NAME")
        table_name = _mysql_identifier("DB_TABLE")

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
                cursor.execute(_create_event_table_sql(database_name, table_name))
                _ensure_event_columns(cursor, database_name, table_name)
                bucket_name, compartment_name, resource_name, namespace = _event_fields(event)
                event_time = _event_date(event)
                cursor.execute(
                    f"INSERT INTO {_event_table(database_name, table_name)} "
                    "(event_date, event_type, event_message, bucket_name, compartment_name, resource_name, namespace, event_time) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                    (
                        event_time,
                        str(event.get("eventType", "unknown")),
                        json.dumps(event, separators=(",", ":")),
                        bucket_name,
                        compartment_name,
                        resource_name,
                        namespace,
                        event_time,
                    ),
                )
            connection.commit()
        finally:
            connection.close()

        payload = {"status": "accepted", "database": "event stored", "event": _event_summary(event)}
        return response.Response(ctx, response_data=json.dumps(payload), headers={"Content-Type": "application/json"}, status_code=200)
    except Exception as exc:  # Return a safe message; never disclose DB credentials.
        payload = {"status": "error", "message": str(exc)}
        return response.Response(ctx, response_data=json.dumps(payload), headers={"Content-Type": "application/json"}, status_code=500)
