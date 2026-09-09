#!/usr/bin/env python3
"""Probe teardown failure gates without provider or Kubernetes access."""
import json,os,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
for package in [Path(__file__).resolve().parents[1].name]:
 bundle=json.loads(subprocess.check_output(['uv','run','--project',str(root/package/'blue'),'python','-c',
  'import json,sys;from blue.cli import load_yaml;from colors_compute.managed import managed_application_artifacts;print(json.dumps(managed_application_artifacts(load_yaml(open(sys.argv[1]).read()))))',str(root/package/'test/fixtures/colors.yml')],text=True))
 for failure in ['', 'access','inventory','delete','provider','malformed','new-resources']:
  with tempfile.TemporaryDirectory() as directory:
   temp=Path(directory);commands=temp/'bin';commands.mkdir();state=temp/'state';state.mkdir()
   (state/'registry.env').write_text('REGISTRY_ADOPTED=false\n')
   (temp/'teardown.sh').write_bytes((root/package/'red/resources/tools/deploy/teardown.sh').read_bytes())
   for filename,content in bundle.items():(temp/filename).write_text(content)
   if failure in ['provider','malformed','new-resources']:
    (state/'compute-cleanup.json').write_text(json.dumps({'volumes':['owned-volume'],'lb_ip':'192.0.2.1'}))
   scripts={'kubectl':'''#!/usr/bin/env python3
import os,sys
args=sys.argv[1:];failure=os.environ['FAILURE']
if failure=='access' and args[0]=='version':sys.exit(1)
if failure=='inventory' and args[:2]==['get','pv']:sys.exit(1)
if failure=='delete' and 'delete' in args:sys.exit(1)
if args[:2]==['get','pv'] and '-o' in args:
 print('{"items":[{"spec":{"csi":{"volumeHandle":"new-volume"}}}]}' if failure=='new-resources' else '{"items":[]}')
''','curl':'''#!/usr/bin/env python3
import os
print('{"error":"bad response"}' if os.environ['FAILURE']=='malformed' else '{"blocks":[{"id":"owned-volume"}],"volumes":[{"id":"owned-volume"}],"load_balancers":[]}')
''','sleep':'#!/usr/bin/env python3\n'}
   for name,script in scripts.items():
    path=commands/name;path.write_text(script);path.chmod(0o755)
   env={**os.environ,'PATH':str(commands)+':'+os.environ['PATH'],'FAILURE':failure,'STATE_DIR':str(state),'COLORS_PAR_VULTR_API_KEY':'fixture','COLORS_PAR_DO_TOKEN':'fixture'}
   r=subprocess.run(['bash',str(temp/'teardown.sh')],env=env,capture_output=True,text=True,timeout=20)
   assert (r.returncode==0)==(failure==''),(package,failure,r.returncode,r.stderr)
   print(package,failure or 'empty', 'passed',flush=True)
