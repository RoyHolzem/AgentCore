import subprocess, json, urllib.request, sys, os

os.chdir(os.path.dirname(os.path.abspath(__file__)))

# Step 1: Create deployment
print("Creating deployment...")
result = subprocess.run(
    ['aws', 'amplify', 'create-deployment', '--app-id', 'dwklc2sf3vn8b',
     '--branch-name', 'main', '--region', 'eu-north-1', '--output', 'json'],
    capture_output=True, text=True
)
# AWS CLI v2 writes warnings to stderr, json to stdout
stdout = result.stdout.strip()
stderr = result.stderr.strip()
if not stdout and stderr:
    print(f'STDERR: {stderr}')
    sys.exit(1)
# Try to find JSON in output
try:
    deploy = json.loads(stdout)
except json.JSONDecodeError:
    # Maybe mixed with warnings
    json_start = stdout.find('{')
    if json_start >= 0:
        deploy = json.loads(stdout[json_start:])
    else:
        print(f'Cannot parse output: {stdout[:500]}')
        sys.exit(1)
job_id = deploy['jobId']
upload_url = deploy['zipUploadUrl']
print(f"Job ID: {job_id}")

# Step 2: Upload zip
print("Uploading zip (8.3 MB)...")
with open('deploy.zip', 'rb') as f:
    data = f.read()

req = urllib.request.Request(upload_url, data=data, method='PUT')
req.add_header('Content-Type', 'application/zip')
try:
    resp = urllib.request.urlopen(req)
    print(f"Upload status: {resp.status}")
except urllib.error.HTTPError as e:
    print(f"Upload error: {e.code} {e.reason}")
    body = e.read().decode()[:500]
    print(f"Response: {body}")
    sys.exit(1)

# Step 3: Start deployment
print("Starting deployment...")
result = subprocess.run(
    ['aws', 'amplify', 'start-deployment', '--app-id', 'dwklc2sf3vn8b',
     '--branch-name', 'main', '--job-id', job_id, '--region', 'eu-north-1',
     '--output', 'json'],
    capture_output=True, text=True
)
lines2 = [l for l in result.stdout.strip().split('\n') if l.strip()]
if lines2:
    try:
        print(json.dumps(json.loads(lines2[-1]), indent=2))
    except:
        print(result.stdout)
else:
    print(result.stderr)
print("Done! Deployment started.")
