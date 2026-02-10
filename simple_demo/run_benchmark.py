#!/usr/bin/env python3
"""
Benchmark runner for libfiber vs pthread echo servers.
Runs both servers at multiple concurrency levels and captures performance metrics.
"""

import subprocess
import time
import json
import os
import signal
import psutil
import statistics
from pathlib import Path

# Configuration
CONCURRENCY_LEVELS = [100, 500, 1000, 2000, 5000]
DURATION = 8  # seconds per test
PORT = 10000
HOST = "127.0.0.1"

def compile_servers():
    """Compile both echo servers if needed."""
    print("Building servers...")
    subprocess.run(["make"], check=True, cwd="..")
    
    # Compile thread server
    thread_server = Path("../bin/thread_server")
    if not thread_server.exists():
        subprocess.run([
            "gcc", "-O2", "-pthread", 
            "-o", "../bin/thread_server", 
            "../tools/thread_echo_server.c"
        ], check=True)
    
    print("✓ Servers compiled")

def run_benchmark(server_binary, concurrency):
    """Run a single benchmark test."""
    # Start server
    proc = subprocess.Popen(
        [server_binary, str(PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    
    time.sleep(0.5)  # Let server start
    
    try:
        # Monitor process
        p = psutil.Process(proc.pid)
        
        # Run load test (using simple Python implementation)
        result = run_load_test(concurrency, DURATION, proc.pid)
        
        return result
    finally:
        proc.terminate()
        proc.wait(timeout=2)

def run_load_test(concurrency, duration, server_pid):
    """Simple load test implementation."""
    import socket
    import threading
    import time
    
    latencies = []
    errors = 0
    lock = threading.Lock()
    stop_event = threading.Event()
    
    def client_worker():
        nonlocal errors
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.connect((HOST, PORT))
            sock.settimeout(5)
            
            msg = b"hello"
            while not stop_event.is_set():
                start = time.time()
                try:
                    sock.sendall(msg)
                    data = sock.recv(len(msg))
                    if data != msg:
                        break
                    elapsed = (time.time() - start) * 1000  # ms
                    with lock:
                        latencies.append(elapsed)
                except:
                    with lock:
                        errors += 1
                    break
            sock.close()
        except:
            with lock:
                errors += 1
    
    # Start threads
    threads = []
    for _ in range(concurrency):
        t = threading.Thread(target=client_worker, daemon=True)
        t.start()
        threads.append(t)
    
    # Monitor metrics
    metrics = []
    p = psutil.Process(server_pid)
    start_time = time.time()
    
    while time.time() - start_time < duration:
        try:
            with p.oneshot():
                cpu = p.cpu_percent(interval=0.1)
                mem = p.memory_info().rss
                num_threads = p.num_threads()
            
            metrics.append({
                "cpu": cpu,
                "mem": mem,
                "threads": num_threads,
                "time": time.time() - start_time
            })
        except:
            pass
        time.sleep(0.5)
    
    # Stop clients
    stop_event.set()
    for t in threads:
        t.join(timeout=1)
    
    # Calculate aggregate stats
    if latencies:
        sorted_lat = sorted(latencies)
        p95_idx = int(len(sorted_lat) * 0.95)
        
        return {
            "count": len(latencies),
            "errors": errors,
            "throughput": len(latencies) / duration,
            "latency": {
                "mean": statistics.mean(latencies),
                "median": statistics.median(latencies),
                "p95": sorted_lat[p95_idx] if p95_idx < len(sorted_lat) else sorted_lat[-1],
                "min": min(latencies),
                "max": max(latencies)
            },
            "resources": {
                "max_cpu": max(m["cpu"] for m in metrics) if metrics else 0,
                "avg_cpu": statistics.mean(m["cpu"] for m in metrics) if metrics else 0,
                "max_mem_mb": max(m["mem"] for m in metrics) / (1024 * 1024) if metrics else 0,
                "max_threads": max(m["threads"] for m in metrics) if metrics else 0
            }
        }
    else:
        return None

def main():
    """Run all benchmarks and output JSON."""
    os.chdir(Path(__file__).parent)
    
    compile_servers()
    
    results = {
        "fiber": {},
        "thread": {}
    }
    
    # Test fiber server
    print("\n=== Testing libfiber server ===")
    for c in CONCURRENCY_LEVELS:
        print(f"  Concurrency {c}...", end=" ", flush=True)
        result = run_benchmark("../bin/echo_server", c)
        if result:
            results["fiber"][str(c)] = result
            print(f"✓ {result['throughput']:.0f} req/s")
        else:
            print("✗ Failed")
    
    # Test thread server
    print("\n=== Testing pthread server ===")
    for c in CONCURRENCY_LEVELS:
        print(f"  Concurrency {c}...", end=" ", flush=True)
        result = run_benchmark("../bin/thread_server", c)
        if result:
            results["thread"][str(c)] = result
            print(f"✓ {result['throughput']:.0f} req/s")
        else:
            print("✗ Failed")
    
    # Save results
    output_file = "benchmark_results.json"
    with open(output_file, "w") as f:
        json.dump(results, f, indent=2)
    
    print(f"\n✓ Results saved to {output_file}")
    return results

if __name__ == "__main__":
    main()
