#!/usr/bin/env bash
# Create a zip containing the monitoring/demo files for the libfiber presentation.
# Usage:
#   chmod +x create_demo_zip.sh
#   ./create_demo_zip.sh
# Output: libfiber_demo_package.zip (in the current directory)
set -euo pipefail

OUT_ZIP="libfiber_demo_package.zip"
PKG_DIR="libfiber_demo_package"
echo "Creating package in ./$PKG_DIR ..."

# Remove any previous temp dir
rm -rf "$PKG_DIR" "$OUT_ZIP"
mkdir -p "$PKG_DIR"

write_file() {
  local path="$1"; shift
  local content="$*"
  mkdir -p "$(dirname "$PKG_DIR/$path")"
  cat > "$PKG_DIR/$path" <<'EOF'
'"$content"'
EOF
}

# We'll use here-docs per-file to preserve content exactly.
# docker-compose.yml
cat > "$PKG_DIR/docker-compose.yml" <<'YAML'
version: "3.8"
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "9090:9090"
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana-storage:/var/lib/grafana
      - ./grafana/dashboard.json:/var/lib/grafana/dashboards/libfiber-dashboard.json:ro
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "3000:3000"
    depends_on:
      - prometheus
    restart: unless-stopped

  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    network_mode: "host"
    pid: "host"
    restart: unless-stopped

  app_exporter:
    build: ./app_exporter
    container_name: app_exporter
    volumes:
      - ./results:/results  # mount results dir (created by run_experiment.sh)
    ports:
      - "9123:9123"
    restart: unless-stopped

volumes:
  grafana-storage:
YAML

# prometheus/prometheus.yml
mkdir -p "$PKG_DIR/prometheus"
cat > "$PKG_DIR/prometheus/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'app_exporter'
    static_configs:
      - targets: ['app_exporter:9123', '127.0.0.1:9123']
    metrics_path: /metrics
YAML

# app_exporter files
mkdir -p "$PKG_DIR/app_exporter"
cat > "$PKG_DIR/app_exporter/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY exporter.py .
CMD ["python", "exporter.py", "--results-dir", "/results", "--port", "9123", "--interval", "5"]
DOCKER

cat > "$PKG_DIR/app_exporter/requirements.txt" <<'REQ'
prometheus-client
psutil
REQ

cat > "$PKG_DIR/app_exporter/exporter.py" <<'PY'
#!/usr/bin/env python3
"""
App exporter: reads experiment result JSON files and exposes Prometheus metrics.

Expected filenames: <label>_c<concurrency>.json (e.g. fiber_c100.json)
"""
import os, time, json, argparse
from glob import glob
from prometheus_client import start_http_server, Gauge

m_requests = Gauge("lib_perf_requests_total", "Requests counted in experiment", ["server", "concurrency"])
m_throughput = Gauge("lib_perf_throughput_rps", "Estimated throughput (requests/sec)", ["server", "concurrency"])
m_median = Gauge("lib_perf_median_ms", "Median latency (ms)", ["server", "concurrency"])
m_p95 = Gauge("lib_perf_p95_ms", "P95 latency (ms)", ["server", "concurrency"])
m_mean = Gauge("lib_perf_mean_ms", "Mean latency (ms)", ["server", "concurrency"])
m_max_rss = Gauge("lib_perf_max_rss_bytes", "Max RSS memory (bytes) during run", ["server", "concurrency"])
m_avg_cpu = Gauge("lib_perf_avg_cpu_percent", "Average CPU percent during run", ["server", "concurrency"])
m_max_threads = Gauge("lib_perf_max_threads", "Max threads observed during run", ["server", "concurrency"])

def parse_filename(path):
    name = os.path.basename(path)
    base = name.rsplit('.',1)[0]
    parts = base.split('_c')
    if len(parts) != 2:
        return None, None
    return parts[0], parts[1]

def process_file(path):
    try:
        j = json.load(open(path))
    except Exception as e:
        print("Failed to load", path, e)
        return None
    server, conc = parse_filename(path)
    if not server:
        return None
    agg = j.get("agg", {})
    metrics = j.get("metrics", [])
    count = agg.get("count", 0)
    duration = j.get("duration", 10) or 10
    mean_ms = agg.get("mean_ms", 0)
    median_ms = agg.get("median_ms", 0)
    p95_ms = agg.get("p95_ms", 0)
    max_rss = 0
    cpu_vals = []
    max_threads = 0
    for m in metrics:
        mem = m.get("mem")
        if mem:
            max_rss = max(max_rss, mem)
        cpu = m.get("cpu")
        if cpu is not None:
            cpu_vals.append(cpu)
        thr = m.get("threads")
        if thr:
            max_threads = max(max_threads, thr)
    avg_cpu = sum(cpu_vals)/len(cpu_vals) if cpu_vals else 0.0
    throughput = (count / float(duration)) if duration and count else 0.0
    return dict(server=server, concurrency=conc,
                count=count, throughput=throughput,
                median_ms=median_ms, p95_ms=p95_ms, mean_ms=mean_ms,
                max_rss=max_rss, avg_cpu=avg_cpu, max_threads=max_threads)

def update_metrics(results_dir):
    files = glob(os.path.join(results_dir, "*.json"))
    for f in files:
        info = process_file(f)
        if not info:
            continue
        s = info["server"]
        c = info["concurrency"]
        labels = [s, str(c)]
        m_requests.labels(*labels).set(info["count"])
        m_throughput.labels(*labels).set(info["throughput"])
        m_median.labels(*labels).set(info["median_ms"])
        m_p95.labels(*labels).set(info["p95_ms"])
        m_mean.labels(*labels).set(info["mean_ms"])
        m_max_rss.labels(*labels).set(info["max_rss"])
        m_avg_cpu.labels(*labels).set(info["avg_cpu"])
        m_max_threads.labels(*labels).set(info["max_threads"])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", default="/results")
    parser.add_argument("--port", type=int, default=9123)
    parser.add_argument("--interval", type=int, default=5)
    args = parser.parse_args()
    start_http_server(args.port)
    print(f"Exporter started on :{args.port}, reading results from: {args.results_dir}")
    while True:
        try:
            update_metrics(args.results_dir)
        except Exception as e:
            print("update error:", e)
        time.sleep(args.interval)

if __name__ == "__main__":
    main()
PY

# grafana provisioning and dashboard
mkdir -p "$PKG_DIR/grafana/provisioning/dashboards" "$PKG_DIR/grafana/provisioning/datasources"
cat > "$PKG_DIR/grafana/provisioning/dashboards/dashboards.yml" <<'YAML'
apiVersion: 1
providers:
  - name: 'libfiber'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
YAML

cat > "$PKG_DIR/grafana/provisioning/datasources/datasource.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
YAML

cat > "$PKG_DIR/grafana/dashboard.json" <<'JSON'
{
  "annotations": { "list": [] },
  "editable": true,
  "gnetId": null,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "type": "row",
      "title": "libfiber experiment overview",
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 }
    },
    {
      "type": "timeseries",
      "title": "Throughput (req/sec)",
      "gridPos": { "h": 6, "w": 12, "x": 0, "y": 1 },
      "options": { "tooltip": { "mode": "single" } },
      "targets": [
        {
          "expr": "lib_perf_throughput_rps{server=\"$server\",concurrency=~\"$concurrency\"}",
          "legendFormat": "{{server}} c={{concurrency}}",
          "refId": "A"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Latency: median & p95 (ms)",
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 1 },
      "targets": [
        {
          "expr": "lib_perf_median_ms{server=\"$server\",concurrency=~\"$concurrency\"}",
          "legendFormat": "median {{concurrency}}",
          "refId": "A"
        },
        {
          "expr": "lib_perf_p95_ms{server=\"$server\",concurrency=~\"$concurrency\"}",
          "legendFormat": "p95 {{concurrency}}",
          "refId": "B"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Avg CPU (%)",
      "gridPos": { "h": 4, "w": 8, "x": 0, "y": 7 },
      "targets": [
        {
          "expr": "lib_perf_avg_cpu_percent{server=\"$server\",concurrency=~\"$concurrency\"}",
          "legendFormat": "{{server}} c={{concurrency}}",
          "refId": "A"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Max Memory (MB)",
      "gridPos": { "h": 4, "w": 8, "x": 8, "y": 7 },
      "targets": [
        {
          "expr": "lib_perf_max_rss_bytes{server=\"$server\",concurrency=~\"$concurrency\"} / 1024 / 1024",
          "legendFormat": "{{server}} c={{concurrency}}",
          "refId": "A"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Max Threads",
      "gridPos": { "h": 4, "w": 8, "x": 16, "y": 7 },
      "targets": [
        {
          "expr": "lib_perf_max_threads{server=\"$server\",concurrency=~\"$concurrency\"}",
          "legendFormat": "{{server}} c={{concurrency}}",
          "refId": "A"
        }
      ]
    }
  ],
  "schemaVersion": 34,
  "style": "dark",
  "tags": ["libfiber", "benchmark"],
  "templating": {
    "list": [
      {
        "name": "server",
        "type": "query",
        "query": "label_values(lib_perf_throughput_rps, server)",
        "refresh": 1,
        "multi": false,
        "includeAll": false
      },
      {
        "name": "concurrency",
        "type": "query",
        "query": "label_values(lib_perf_throughput_rps{server=\"$server\"}, concurrency)",
        "refresh": 1,
        "multi": true,
        "includeAll": true
      }
    ]
  },
  "time": { "from": "now-1h", "to": "now" },
  "title": "libfiber vs threads (experiment results)",
  "uid": "libfiber-dashboard"
}
JSON

# tools
mkdir -p "$PKG_DIR/tools"
cat > "$PKG_DIR/tools/thread_echo_server.c" <<'CFILE'
/* Simple pthread-per-connection echo server.
   Compile: gcc -O2 -pthread -o bin/thread_server tools/thread_echo_server.c
*/
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define BACKLOG 128

void *conn_handler(void *arg) {
    int sock = (intptr_t)arg;
    char buf[128];
    while (1) {
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
        if (n <= 0) break;
        ssize_t w = 0;
        while (w < n) {
            ssize_t s = send(sock, buf + w, n - w, 0);
            if (s <= 0) break;
            w += s;
        }
        if (w < n) break;
    }
    close(sock);
    return NULL;
}

int main(int argc, char **argv) {
    const char *port = argc > 1 ? argv[1] : "10000";
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_PASSIVE };
    struct addrinfo *res;
    if (getaddrinfo(NULL, port, &hints, &res) != 0) {
        perror("getaddrinfo");
        return 1;
    }
    int lfd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    if (bind(lfd, res->ai_addr, res->ai_addrlen) != 0) { perror("bind"); return 1; }
    freeaddrinfo(res);
    if (listen(lfd, BACKLOG) != 0) { perror("listen"); return 1; }
    fprintf(stderr, "thread_server listening on %s\n", port);
    while (1) {
        int sock = accept(lfd, NULL, NULL);
        if (sock < 0) continue;
        pthread_t t;
        pthread_create(&t, NULL, conn_handler, (void*)(intptr_t)sock);
        pthread_detach(t);
    }
    close(lfd);
    return 0;
}
CFILE

cat > "$PKG_DIR/tools/loadgen.py" <<'PY'
#!/usr/bin/env python3
"""
Async TCP load generator for echo servers.
Usage:
  python3 loadgen.py --host 127.0.0.1 --port 10000 --concurrency 1000 --duration 10 --out results.json --server-pid 1234
"""
import argparse, asyncio, json, time, statistics, os
import psutil

MSG = b"hello"

async def single_client(host, port, dur, latencies, stop_event):
    try:
        reader, writer = await asyncio.open_connection(host, port)
    except Exception:
        return
    t0 = time.time()
    while not stop_event.is_set():
        s = time.time()
        try:
            writer.write(MSG)
            await writer.drain()
            data = await reader.readexactly(len(MSG))
        except Exception:
            break
        e = time.time()
        latencies.append((e - s))
        if time.time() - t0 > dur:
            break
    try:
        writer.close()
        await writer.wait_closed()
    except:
        pass

async def run_load(host, port, concurrency, duration, sample_pid):
    latencies = []
    stop_event = asyncio.Event()
    tasks = [asyncio.create_task(single_client(host, port, duration, latencies, stop_event)) for _ in range(concurrency)]
    metrics = []
    start = time.time()
    try:
        while time.time() - start < duration:
            if sample_pid:
                try:
                    p = psutil.Process(sample_pid)
                    with p.oneshot():
                        cpu = p.cpu_percent(interval=None)
                        mem = p.memory_info().rss
                        thr = p.num_threads()
                    metrics.append({"t": time.time() - start, "cpu": cpu, "mem": mem, "threads": thr})
                except psutil.NoSuchProcess:
                    metrics.append({"t": time.time() - start, "cpu": None, "mem": None, "threads": None})
            await asyncio.sleep(1)
    finally:
        stop_event.set()
        await asyncio.gather(*tasks, return_exceptions=True)
    return latencies, metrics

def aggregate(latencies):
    if not latencies:
        return {}
    lat_ms = [l * 1000.0 for l in latencies]
    p95 = max(lat_ms)
    if len(lat_ms) >= 100:
        import statistics as st
        p95 = st.quantiles(lat_ms, n=100)[94]
    return {
        "count": len(lat_ms),
        "min_ms": min(lat_ms),
        "max_ms": max(lat_ms),
        "mean_ms": statistics.mean(lat_ms),
        "median_ms": statistics.median(lat_ms),
        "p95_ms": p95
    }

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=10000)
    parser.add_argument("--concurrency", type=int, default=100)
    parser.add_argument("--duration", type=int, default=10)
    parser.add_argument("--out", default="results.json")
    parser.add_argument("--server-pid", type=int, default=None)
    args = parser.parse_args()
    lat, metrics = asyncio.run(run_load(args.host, args.port, args.concurrency, args.duration, args.server_pid))
    agg = aggregate(lat)
    out = {
        "host": args.host, "port": args.port, "concurrency": args.concurrency,
        "duration": args.duration, "agg": agg, "raw_latencies_ms": [l*1000.0 for l in lat],
        "metrics": metrics
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    print("Wrote", args.out)

if __name__ == "__main__":
    main()
PY

cat > "$PKG_DIR/tools/run_experiment.sh" <<'SH'
#!/bin/sh
# Orchestrate experiments.
# Usage:
# tools/run_experiment.sh /path/to/fiber_server /path/to/thread_server
CONCURRENCIES="100 500 1000 2000 5000"
OUTDIR=results
mkdir -p $OUTDIR

FIBER_BIN="$1"
THREAD_BIN="$2"

if [ -z "$FIBER_BIN" ] || [ -z "$THREAD_BIN" ]; then
  echo "Usage: $0 /path/to/fiber_server /path/to/thread_server"
  exit 1
fi

run_one() {
  label=$1
  bin=$2
  echo "Running $label server ($bin)"
  $bin 10000 >/dev/null 2>&1 &
  SPID=$!
  sleep 0.5
  echo "Server PID: $SPID"
  for c in $CONCURRENCIES; do
    out="$OUTDIR/${label}_c${c}.json"
    echo "  concurrency $c -> $out"
    python3 tools/loadgen.py --host 127.0.0.1 --port 10000 --concurrency $c --duration 8 --out "$out" --server-pid $SPID
    sleep 1
  done
  kill $SPID || true
  sleep 1
}

run_one fiber "$FIBER_BIN"
run_one thread "$THREAD_BIN"

python3 - <<'PY'
import json,glob
files = glob.glob("results/*.json")
data = {}
for f in files:
    data[f.split('/')[-1]] = json.load(open(f))
open("results/data.json","w").write(json.dumps(data,indent=2))
print("Wrote results/data.json")
PY

echo "Done. Results in ./results. Launch docker-compose and Grafana to visualize."
SH

# docs README
mkdir -p "$PKG_DIR/docs"
cat > "$PKG_DIR/docs/README-monitoring.md" <<'MD'
# Monitoring & Demo: Prometheus + Grafana + app_exporter for benchmark visualization

This package adds a complete monitoring stack (Prometheus, Grafana, node_exporter, app_exporter)
and tools to run experiments comparing a libfiber-based server and a pthreads-based server.

Quick steps (automated by setup_demo.sh):
1. Build the repository (make) if needed.
2. Build a pthread-per-connection server (tools/thread_echo_server.c).
3. Build and run the monitoring stack with Docker Compose (Prometheus + Grafana).
4. Run the experiment orchestrator to generate results in `./results/`.
5. Grafana auto-imports the dashboard; open http://localhost:3000 (admin/admin).

See the repo root `setup_demo.sh` for a single-command setup and run flow.
MD

# setup_demo.sh (top-level orchestrator)
cat > "$PKG_DIR/setup_demo.sh" <<'SH'
#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "Repository root: $ROOT"

# 1) Ensure docker and zip are available
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found. Please install Docker and re-run."
  exit 1
fi

if ! command -v docker-compose >/dev/null 2>&1; then
  echo "docker-compose not found. Using 'docker compose' if available."
fi

# 2) Build tools and items
echo "Compiling thread server..."
mkdir -p bin
gcc -O2 -pthread -o bin/thread_server tools/thread_echo_server.c

# 3) Build app_exporter image
echo "Building app_exporter docker image..."
docker build -t app_exporter ./app_exporter

# 4) Start stack
if command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d
else
  docker compose up -d
fi

echo "Stack started. Prometheus: http://localhost:9090 Grafana: http://localhost:3000 (admin/admin)"

echo "You can run experiments with:"
echo "  ./tools/run_experiment.sh /path/to/fiber_server ./bin/thread_server"
echo "After experiments, results will be in ./results and Grafana will visualize them."
SH

# Make everything executable where appropriate
chmod +x "$PKG_DIR/app_exporter/exporter.py" "$PKG_DIR/tools/loadgen.py" "$PKG_DIR/tools/run_experiment.sh" "$PKG_DIR/setup_demo.sh"

# Create a README in the package root
cat > "$PKG_DIR/README.md" <<'TXT'
libfiber demo package
=====================

This package contains:
- docker-compose.yml (Prometheus + Grafana + node_exporter + app_exporter)
- prometheus/prometheus.yml
- grafana provisioning and dashboard (grafana/)
- app_exporter (Dockerfile, exporter.py, requirements)
- tools/ (thread server, load generator, experiment orchestrator)
- setup_demo.sh (quick script to build thread server, build app_exporter image, and start the stack)

How to use:
1. Unzip the package or clone into your repo.
2. Build / run the demo:
   chmod +x setup_demo.sh
   ./setup_demo.sh

3. Build or provide a libfiber-backed server binary (listening on port 10000).
   Then run:
     ./tools/run_experiment.sh /path/to/fiber_server ./bin/thread_server

4. Open Grafana: http://localhost:3000 (admin/admin). Dashboard: "libfiber vs threads (experiment results)"

TXT

# Create results dir
mkdir -p "$PKG_DIR/results"

# zip the package
echo "Zipping package into $OUT_ZIP ..."
zip -r -q "$OUT_ZIP" "$PKG_DIR"

echo "Done. Created $OUT_ZIP"
echo "You can extract it with: unzip $OUT_ZIP"