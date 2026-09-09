import {test,expect} from 'bun:test';
import {mkdtempSync,mkdirSync,writeFileSync,existsSync,readFileSync,rmSync} from 'node:fs';
import {join,dirname} from 'node:path';import {tmpdir} from 'node:os';
import {workflow as makeWorkflow,run,type Opts} from 'red/workflow';
import {wireFn,nextSteps} from '../src/workflow.ts';import * as tools from '../src/tools.ts';
test('retired workflow resumes only local cleanup without SSH keys',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'agent-network-k8s-retired-'));try{
  const opts:Opts={profile:'retired',workdir:dir,'red/event':'delete'};const paths=[tools.kubeconfigPath(opts),join(tools.stateDir(opts),'leftover'),join(tools.profileDir(opts),'proofs/leftover')];
  for(const path of paths){mkdirSync(dirname(path),{recursive:true});writeFileSync(path,'synthetic leftover');}
  const keep=join(dir,'keep');writeFileSync(keep,'unrelated');let seen:string[]=[];let inspectionExit=0;
  const native=makeWorkflow({start:'agent-network-k8s/start',nextFn:nextSteps,wireFn:(step,current)=>{
   if(step==='agent-network-k8s/start')return [(o:Opts)=>(seen.push(step),{...o,'red/exit':0}),'agent-network-k8s/load-managed'];
   if(step==='agent-network-k8s/load-managed')return [(o:Opts)=>(seen.push(step),{...o,'red/exit':inspectionExit,'managed/already-destroyed':true}),'forbidden/remote'];
   if(step==='agent-network-k8s/cleanup')return [async(o:Opts)=>{seen.push(step);return await wireFn(step,o)![0](o);}];
   return [()=>{throw new Error('remote stage executed');}];
  }});
  for(let i=0;i<2;i++){seen=[];expect((await run(native,opts))['red/exit']).toBe(0);expect(seen).toEqual(['agent-network-k8s/start','agent-network-k8s/load-managed','agent-network-k8s/cleanup']);for(const path of paths)expect(existsSync(path)).toBe(false);expect(readFileSync(keep,'utf8')).toBe('unrelated');}
  inspectionExit=1;seen=[];expect((await run(native,opts))['red/exit']).toBe(1);expect(seen).toEqual(['agent-network-k8s/start','agent-network-k8s/load-managed']);
  expect(nextSteps('agent-network-k8s/load-managed',['forbidden/remote'],{...opts,'red/exit':1,'managed/already-destroyed':true})).toEqual([]);
  expect(existsSync(join(dir,'.ssh'))).toBe(false);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
