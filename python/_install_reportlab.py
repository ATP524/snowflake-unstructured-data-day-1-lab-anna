import subprocess, sys
r = subprocess.run([sys.executable, "-m", "pip", "install", "reportlab"], capture_output=True, text=True, timeout=300)
print(r.returncode)
print(r.stdout[-1500:])
print(r.stderr[-1500:])
