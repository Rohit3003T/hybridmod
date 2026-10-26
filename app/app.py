import os
import time
import socket
from contextlib import contextmanager

import psycopg2
from psycopg2 import OperationalError
from flask import Flask, jsonify, redirect, render_template_string, request, url_for

app = Flask(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL")
INSTANCE = socket.gethostname()

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL environment variable is required")


@contextmanager
def db_connection():
    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def init_db():
    # Retry while PostgreSQL starts.
    for attempt in range(30):
        try:
            with db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("""
                        CREATE TABLE IF NOT EXISTS records (
                            id SERIAL PRIMARY KEY,
                            title VARCHAR(120) NOT NULL,
                            details TEXT DEFAULT '',
                            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
                        )
                    """)
            print("Database initialized successfully.")
            return
        except OperationalError:
            if attempt == 29:
                raise
            print("Waiting for PostgreSQL...")
            time.sleep(2)


@app.route("/")
def home():
    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, title, details, created_at
                FROM records
                ORDER BY created_at DESC
            """)
            records = cur.fetchall()

    return render_template_string("""
    <!doctype html>
    <html lang="en">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>HybridMod | Operations Logbook</title>
        <style>
            body {
                max-width: 900px;
                margin: 40px auto;
                padding: 0 20px;
                font-family: Arial, sans-serif;
                background: #f4f6f8;
                color: #202938;
            }
            .card {
                background: white;
                padding: 24px;
                margin-bottom: 20px;
                border-radius: 10px;
                box-shadow: 0 2px 8px #0000000d;
            }
            input, textarea, button {
                box-sizing: border-box;
                width: 100%;
                padding: 12px;
                margin-top: 10px;
                border: 1px solid #ccd3dc;
                border-radius: 6px;
                font: inherit;
            }
            button {
                background: #2459a9;
                color: white;
                border: none;
                cursor: pointer;
            }
            table {
                width: 100%;
                border-collapse: collapse;
                overflow-wrap: anywhere;
            }
            th, td {
                padding: 12px 8px;
                text-align: left;
                border-bottom: 1px solid #e5e7eb;
            }
            small { color: #64748b; }
        </style>
    </head>
    <body>
        <h1>HybridMod</h1>
        <p>Operations Logbook</p>

        <section class="card">
            <h2>Create an operational record</h2>
            <form action="/records" method="post">
                <input name="title" maxlength="120"
                       placeholder="Title, e.g. Server maintenance"
                       required>
                <textarea name="details" rows="3"
                          placeholder="Describe the incident or task"></textarea>
                <button type="submit">Save Record</button>
            </form>
        </section>

        <section class="card">
            <h2>Recent records</h2>
            {% if records %}
            <table>
                <tr>
                    <th>ID</th>
                    <th>Title</th>
                    <th>Details</th>
                    <th>Created (UTC)</th>
                </tr>
                {% for record in records %}
                <tr>
                    <td>{{ record[0] }}</td>
                    <td>{{ record[1] }}</td>
                    <td>{{ record[2] }}</td>
                    <td>{{ record[3].strftime('%Y-%m-%d %H:%M') }}</td>
                </tr>
                {% endfor %}
            </table>
            {% else %}
            <p>No records yet. Create your first record above.</p>
            {% endif %}
        </section>

        <p><small>Application instance: {{ instance }}</small></p>
    </body>
    </html>
    """, records=records, instance=INSTANCE)


@app.route("/records", methods=["POST"])
def create_record():
    title = request.form.get("title", "").strip()
    details = request.form.get("details", "").strip()

    if not title:
        return "Title is required.", 400

    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO records (title, details) VALUES (%s, %s)",
                (title, details)
            )

    return redirect(url_for("home"))


@app.route("/health")
def health():
    try:
        with db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")

        return jsonify(status="ok", instance=INSTANCE), 200
    except psycopg2.Error:
        return jsonify(status="error", instance=INSTANCE), 503


init_db()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
