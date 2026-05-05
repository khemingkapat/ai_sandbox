#!/bin/bash
docker compose down -v
docker compose up -d --build
docker compose up -d
./setup-users.sh
