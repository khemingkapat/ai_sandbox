#!/usr/bin/env python3
import os
import sqlite3
import logging
import yaml
from pathlib import Path
from typing import Optional, Tuple
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime

logger = logging.getLogger(__name__)


@dataclass
class PortLease:
    port: int
    job_id: int
    username: str
    node_hostname: str
    node_ip: str
    leased_at: str
    status: str


class PortManager:
    def __init__(
        self,
        db_path: str = "/var/lib/portal/leases.db",
        port_range: Tuple[int, int] = (30000, 31000),
        traefik_config_dir: str = "/etc/traefik/dynamic",
    ):
        self.db_path = db_path
        self.port_min, self.port_max = port_range
        self.traefik_config_dir = Path(traefik_config_dir)
        self.traefik_config_dir.mkdir(parents=True, exist_ok=True)

        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._init_db()
        logger.info(f"Port Manager initialized: pool={port_range}, db={db_path}")

    def _init_db(self):
        with self._db_connection() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS port_leases (
                    port INTEGER PRIMARY KEY,
                    job_id INTEGER,
                    username TEXT,
                    node_hostname TEXT,
                    node_ip TEXT,
                    leased_at TIMESTAMP,
                    released_at TIMESTAMP,
                    status TEXT DEFAULT 'active'
                )
            """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS port_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    last_allocated_port INTEGER DEFAULT 29999
                )
            """
            )
            cursor = conn.execute("SELECT COUNT(*) FROM port_queue")
            if cursor.fetchone()[0] == 0:
                conn.execute(
                    "INSERT INTO port_queue (last_allocated_port) VALUES (?)",
                    (self.port_min - 1,),
                )
            conn.commit()

    @contextmanager
    def _db_connection(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()

    def _get_next_port_circular(self, conn) -> int:
        cursor = conn.execute("SELECT last_allocated_port FROM port_queue WHERE id = 1")
        last_port = cursor.fetchone()[0]

        next_port = last_port + 1
        if next_port > self.port_max:
            next_port = self.port_min

        attempts = 0
        max_attempts = self.port_max - self.port_min + 1

        while attempts < max_attempts:
            cursor = conn.execute(
                "SELECT port FROM port_leases WHERE port = ? AND status = 'active'",
                (next_port,),
            )
            if cursor.fetchone() is None:
                conn.execute(
                    "UPDATE port_queue SET last_allocated_port = ? WHERE id = 1",
                    (next_port,),
                )
                return next_port

            next_port += 1
            if next_port > self.port_max:
                next_port = self.port_min
            attempts += 1

        raise RuntimeError(
            f"No available ports in range {self.port_min}-{self.port_max}"
        )

    def allocate_port(
        self, job_id: int, username: str, node_hostname: str, node_ip: str
    ) -> int:
        with self._db_connection() as conn:
            port = self._get_next_port_circular(conn)
            conn.execute(
                """
                INSERT OR REPLACE INTO port_leases 
                (port, job_id, username, node_hostname, node_ip, leased_at, status)
                VALUES (?, ?, ?, ?, ?, ?, 'active')
            """,
                (
                    port,
                    job_id,
                    username,
                    node_hostname,
                    node_ip,
                    datetime.now().isoformat(),
                ),
            )
            conn.commit()

            self._update_traefik_routes()
            return port

    def release_port(self, job_id: int) -> Optional[int]:
        with self._db_connection() as conn:
            cursor = conn.execute(
                "SELECT port FROM port_leases WHERE job_id = ? AND status = 'active'",
                (job_id,),
            )
            row = cursor.fetchone()
            if row is None:
                return None

            port = row[0]
            conn.execute(
                """
                UPDATE port_leases 
                SET status = 'released', released_at = ?
                WHERE job_id = ? AND status = 'active'
            """,
                (datetime.now().isoformat(), job_id),
            )
            conn.commit()

            self._update_traefik_routes()
            return port

    def get_lease_by_job(self, job_id: int) -> Optional[PortLease]:
        with self._db_connection() as conn:
            cursor = conn.execute(
                """
                SELECT port, job_id, username, node_hostname, node_ip, leased_at, status
                FROM port_leases WHERE job_id = ? AND status = 'active'
            """,
                (job_id,),
            )
            row = cursor.fetchone()
            if row is None:
                return None
            return PortLease(*row)

    def get_active_leases(self) -> list[PortLease]:
        with self._db_connection() as conn:
            cursor = conn.execute(
                """
                SELECT port, job_id, username, node_hostname, node_ip, leased_at, status
                FROM port_leases WHERE status = 'active' ORDER BY leased_at DESC
            """
            )
            return [PortLease(*row) for row in cursor.fetchall()]

    def _update_traefik_routes(self):
        leases = self.get_active_leases()
        config = {"http": {"routers": {}, "services": {}}}

        for lease in leases:
            router_name = f"jupyter-job-{lease.job_id}"
            service_name = f"jupyter-service-{lease.job_id}"

            config["http"]["routers"][router_name] = {
                "rule": f"PathPrefix(`/{lease.username}/jupyter/{lease.job_id}`)",
                "service": service_name,
                "entryPoints": ["web"],
            }

            config["http"]["services"][service_name] = {
                "loadBalancer": {
                    "servers": [{"url": f"http://{lease.node_ip}:{lease.port}"}]
                }
            }

            # Middlewares removed completely!

        config_file = self.traefik_config_dir / "dynamic-routes.yml"
        with open(config_file, "w") as f:
            import yaml

            yaml.dump(config, f, default_flow_style=False)
