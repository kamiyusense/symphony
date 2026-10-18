import json,os,time
from pathlib import Path
workspace=Path.cwd()
with (workspace/'partial.txt').open('x') as f:f.write('OFFLINE_PARTIAL_RESULT\n')
with (Path(os.environ['ONE_TASK_EVIDENCE'])/'hooks.jsonl').open('a') as f:
 f.write(json.dumps({'workspace':str(workspace),'pid':os.getpid()})+'\n');f.flush();os.fsync(f.fileno())
while True:time.sleep(0.1)
