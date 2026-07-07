import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import logging
import urllib.parse
import threading
import time
import subprocess

logging.basicConfig(level=logging.INFO)

# Store received jobs in memory
received_jobs = []

# Store polled cluster status
cluster_status = {"nodes": "Waiting for data...", "jobs": "Waiting for data...", "last_updated": "Never"}

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Mock Central Portal</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 40px; background-color: #f4f4f9; }}
        h1, h2 {{ color: #333; }}
        .container {{ display: flex; gap: 40px; }}
        .panel {{ background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); flex: 1; }}
        .job {{ background: #e9ecef; margin-bottom: 10px; padding: 10px; border-left: 4px solid #007bff; }}
        form {{ display: flex; flex-direction: column; gap: 10px; }}
        input, select {{ padding: 8px; border: 1px solid #ccc; border-radius: 4px; }}
        button {{ padding: 10px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }}
        button:hover {{ background: #0056b3; }}
        pre {{ background: #222; color: #0f0; padding: 10px; border-radius: 4px; overflow-x: auto; font-size: 0.9em; }}
    </style>
    <script>
        // Auto-refresh the page every 5 seconds to show new polling data
        setTimeout(function(){{ location.reload(); }}, 5000);
    </script>
</head>
<body>
    <h1>Central Portal (Mock POC)</h1>
    
    <div class="container" style="margin-bottom: 40px;">
        <div class="panel">
            <h2>Live Cluster Telemetry (Polling via native JSON)</h2>
            <p><small>Last Updated: {last_updated}</small></p>
            <h3>Nodes:</h3>
            <pre>{nodes}</pre>
            <h3>Jobs:</h3>
            <pre>{jobs}</pre>
        </div>
    </div>

    <div class="container">
        <div class="panel">
            <h2>Received Slurm Webhooks (Push)</h2>
            <div id="jobs">
                {jobs_html}
            </div>
            <p><a href="/">Refresh List</a></p>
        </div>
        
        <div class="panel">
            <h2>Simulate Webhook Payload</h2>
            <form method="POST" action="/api/webhook/slurm">
                <label>Job ID:</label>
                <input type="text" name="job_id" value="9999" required>
                
                <label>User:</label>
                <input type="text" name="user" value="khemi" required>
                
                <label>Account:</label>
                <input type="text" name="account" value="ai_research" required>
                
                <label>Partition:</label>
                <input type="text" name="partition" value="gpu" required>
                
                <label>Node List:</label>
                <input type="text" name="nodelist" value="node[01]" required>
                
                <button type="submit">Send Mock Webhook</button>
            </form>
        </div>
    </div>
</body>
</html>
"""

def poll_cluster_metrics():
    while True:
        try:
            # Poll Nodes
            sinfo_out = subprocess.check_output(
                ["kubectl", "exec", "-n", "slurm", "slurm-controller-0", "-c", "slurmctld", "--", "sinfo", "--json"],
                stderr=subprocess.DEVNULL
            ).decode('utf-8')
            sinfo_data = json.loads(sinfo_out)
            
            sinfo_groups = sinfo_data.get("sinfo", [])
            total_nodes = 0
            idle_nodes = 0
            alloc_nodes = 0
            
            for group in sinfo_groups:
                nodes_info = group.get("nodes", {})
                total_nodes += nodes_info.get("total", 0)
                idle_nodes += nodes_info.get("idle", 0)
                alloc_nodes += nodes_info.get("allocated", 0)
            
            node_summary = f"Total Nodes: {total_nodes}\nIdle: {idle_nodes}\nAllocated: {alloc_nodes}"
            cluster_status["nodes"] = node_summary
            
            # Poll Jobs
            squeue_out = subprocess.check_output(
                ["kubectl", "exec", "-n", "slurm", "slurm-controller-0", "-c", "slurmctld", "--", "squeue", "--json"],
                stderr=subprocess.DEVNULL
            ).decode('utf-8')
            squeue_data = json.loads(squeue_out)
            
            jobs = squeue_data.get("jobs", [])
            running = sum(1 for j in jobs if j.get("job_state") == "RUNNING")
            pending = sum(1 for j in jobs if j.get("job_state") == "PENDING")
            
            job_summary = f"Total Active Jobs: {len(jobs)}\nRunning: {running}\nPending: {pending}"
            cluster_status["jobs"] = job_summary
            
            import datetime
            cluster_status["last_updated"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
        except Exception as e:
            cluster_status["nodes"] = f"Error fetching node data: {e}"
            cluster_status["jobs"] = "Error fetching job data"
            
        time.sleep(5)

class MockCentralPortal(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            
            jobs_html = ""
            for job in reversed(received_jobs):
                jobs_html += f"<div class='job'><strong>Job ID:</strong> {job.get('job_id', 'N/A')} <br> <strong>User:</strong> {job.get('user', 'N/A')} <br> <strong>Time:</strong> {job.get('timestamp', 'N/A')}</div>"
            
            if not jobs_html:
                jobs_html = "<p>No webhooks received yet.</p>"
                
            response_html = HTML_TEMPLATE.format(
                jobs_html=jobs_html,
                nodes=cluster_status["nodes"],
                jobs=cluster_status["jobs"],
                last_updated=cluster_status["last_updated"]
            )
            self.wfile.write(response_html.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length).decode('utf-8')
        
        try:
            if 'application/x-www-form-urlencoded' in self.headers.get('Content-Type', ''):
                parsed = urllib.parse.parse_qs(post_data)
                payload = {k: v[0] for k, v in parsed.items()}
                import datetime
                payload['timestamp'] = datetime.datetime.utcnow().isoformat() + "Z"
                payload['event'] = "job_completed_simulated"
                received_jobs.append(payload)
                logging.info(f"Received form payload: {json.dumps(payload, indent=2)}")
                
                self.send_response(303)
                self.send_header('Location', '/')
                self.end_headers()
            else:
                payload = json.loads(post_data)
                received_jobs.append(payload)
                logging.info(f"Received JSON payload: {json.dumps(payload, indent=2)}")
                
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"status": "success", "message": "Payload received"}).encode())
        except Exception as e:
            logging.error(f"Error processing payload: {e}")
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Bad Request")

    def log_message(self, format, *args):
        # Disable noisy GET logs since we auto-refresh
        if not "GET / HTTP/1.1" in format%args:
            logging.info("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format%args))

def run(server_class=HTTPServer, handler_class=MockCentralPortal, port=8080):
    # Start polling thread
    poller = threading.Thread(target=poll_cluster_metrics, daemon=True)
    poller.start()
    
    server_address = ('', port)
    httpd = server_class(server_address, handler_class)
    logging.info(f"Starting mock central portal on http://localhost:{port}/ ...")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()
    logging.info("Stopping mock central portal...")

if __name__ == '__main__':
    run()
