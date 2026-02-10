#!/usr/bin/env python3
"""
Flask server for the libfiber benchmark dashboard.
"""

from flask import Flask, jsonify, send_file
import subprocess
import json
import sys
from pathlib import Path

app = Flask(__name__)

@app.route('/')
def index():
    """Serve the dashboard HTML."""
    return send_file('dashboard.html')

@app.route('/api/benchmark')
def run_benchmark():
    """Run the benchmark and return results."""
    try:
        # Run the benchmark script
        result = subprocess.run(
            [sys.executable, 'run_benchmark.py'],
            capture_output=True,
            text=True,
            check=True
        )
        
        # Load and return results
        with open('benchmark_results.json', 'r') as f:
            data = json.load(f)
        
        return jsonify(data)
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Benchmark failed: {e.stderr}"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    print("=" * 50)
    print("  libfiber Benchmark Dashboard")
    print("=" * 50)
    print("\n  🌐 Opening browser at http://localhost:5000\n")
    print("  Press Ctrl+C to stop the server\n")
    
    # Try to open browser
    import webbrowser
    webbrowser.open('http://localhost:5000')
    
    app.run(host='0.0.0.0', port=5000, debug=False)
