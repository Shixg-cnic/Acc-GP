#!/usr/bin/env python3
"""Isolated old/new full-pipeline comparison; native times and CSR oracle."""
import argparse, hashlib, json, os, re, shutil, statistics, subprocess, time
from datetime import datetime, timezone
from pathlib import Path

from result_storage import discard_partition, experiment_path, publish_tables, write_run_table

PROJECT = Path(__file__).resolve().parents[1]
UUID = 'GPU-40ed18d5-a82c-390a-c124-0e9374f1add6'

def save(path, obj):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(obj, indent=2) + '\n'); temp.replace(path)

def occupancy():
    value = subprocess.check_output(['nvidia-smi', '--query-compute-apps=gpu_uuid,pid,process_name', '--format=csv,noheader'], text=True)
    occupied=[int(line.split(',')[1]) for line in value.splitlines() if line.startswith(UUID)]
    return occupied

def idle():
    stable=0
    while stable<3:
        stable=stable+1 if not occupancy() else 0
        time.sleep(0.15)

def measured(command,env,logpath):
    for attempt in range(20):
        idle(); contaminated=False
        # Jet appends JSON to its metrics path. An overlapping process forces
        # a retry, so retain that attempt separately and start a fresh file.
        metrics = Path(command[-1]) if command[-1].endswith('.metrics.json') else logpath.with_suffix('.metrics.json')
        if metrics.exists():
            shutil.copy2(metrics, metrics.with_suffix(f'.stale-{time.time_ns()}.json'))
            metrics.unlink()
        with logpath.open('w') as stream:
            proc=subprocess.Popen(command,env=env,stdout=stream,stderr=subprocess.STDOUT)
            begin=time.monotonic()
            while proc.poll() is None:
                contaminated |= any(pid!=proc.pid for pid in occupancy())
                if time.monotonic()-begin>600:
                    proc.kill();proc.wait();raise RuntimeError('timeout: '+str(command))
                time.sleep(0.15)
        contaminated |= bool(occupancy())
        if not contaminated:
            if proc.returncode:
                raise RuntimeError('partition command failed: '+str(logpath))
            return
        shutil.copy2(logpath,logpath.with_suffix(f'.contaminated-{attempt}.log'))
        print('Discarded overlapping GPU run: '+str(logpath),flush=True)
    raise RuntimeError('No uncontended GPU window')

def main():
    global UUID
    p=argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--gpu-uuid',default=UUID,help='fixed UUID, or auto (one idle identical GPU per graph)')
    p.add_argument('--fine-factor',type=int,default=64)
    p.add_argument('--capacity-growth',type=int,default=8)
    p.add_argument('--coarse-beta',type=int,help='explicit final coarse size/capacity factor, 2..256')
    p.add_argument('--hem',action=argparse.BooleanOptionalAction,default=True)
    p.add_argument('--hem-degree-limit',type=int,default=64)
    p.add_argument('--binary', type=Path, default=PROJECT/'build/gpart_partition_standard')
    p.add_argument('--jet', type=Path, help='use official Jet as before method')
    p.add_argument('--reference', type=Path, required=True, help='saved old ours binary')
    p.add_argument('--names', nargs='+')
    p.add_argument('--parts', nargs='+', type=int, default=[4,8,16,32,64,128])
    p.add_argument('--repeats', type=int, default=3)
    a=p.parse_args(); UUID=a.gpu_uuid; out=experiment_path(a.output); out.mkdir(parents=True,exist_ok=True)
    inventory=[line.split(', ',2) for line in subprocess.check_output(
        ['nvidia-smi','--query-gpu=uuid,name,memory.total','--format=csv,noheader'],text=True).strip().splitlines()]
    if a.gpu_uuid=='auto' and len({tuple(row[1:]) for row in inventory})!=1:
        p.error('auto requires identical GPU models and memory sizes; otherwise choose a fixed UUID')
    selection=json.loads((PROJECT/'tools/benchmark_selection.json').read_text())
    a.names=a.names or sum(selection['categories'].values(),[])
    if len(set(a.names))!=len(a.names) or a.repeats<1 or any(k not in selection['parts'] for k in a.parts):
        p.error('Use unique names, positive repeats, primary k=4/8/16/32/64/128')
    excluded=set(selection['excluded_due_to_memory'])|set(selection.get('excluded_by_user',[]))
    if set(a.names)&excluded:p.error('Excluded dataset requested: '+', '.join(sorted(set(a.names)&excluded)))
    if a.coarse_beta is not None and not 2<=a.coarse_beta<=256:p.error('coarse-beta must be 2..256')
    a.jet=a.jet or PROJECT.parent/'sotas/.build-deps/jet-5090/build-jet/app/jet'
    candidate=out/'candidate'; digest=hashlib.sha256(a.binary.read_bytes()).hexdigest()
    if candidate.exists() and hashlib.sha256(candidate.read_bytes()).hexdigest()!=digest:
        raise RuntimeError('Candidate changed; use a new tag')
    if not candidate.exists(): shutil.copy2(a.binary,candidate)
    binaries=out/'binaries'; binaries.mkdir(exist_ok=True)
    bins={'after':candidate}
    for method,source in [('before',a.jet),('reference',a.reference),('oracle',PROJECT/'build/gpart_verify_csr')]:
        target=binaries/method
        if not target.exists():shutil.copy2(source,target)
        if hashlib.sha256(source.read_bytes()).digest()!=hashlib.sha256(target.read_bytes()).digest():
            raise RuntimeError('Frozen binary changed: '+method)
        if method!='oracle':bins[method]=target
    bins={method:bins[method] for method in ['before','after','reference']}
    manifest=json.loads((PROJECT.parent/'dataset_benchmark/manifest.json').read_text())
    graphs={g['name']:g for g in manifest['graphs']}
    metadata={'coarse_beta':a.coarse_beta,'coarse_beta_scope':'after only; reference default','heavy_edge_degree_limit':a.hem_degree_limit,'hybrid_heavy_edge':a.hem,'capacity_growth':a.capacity_growth,'fine_factor':a.fine_factor,'names':a.names,'parts':a.parts,'repeats':a.repeats,'seed':0,'gpu_uuid':UUID,
              'binaries':{k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in bins.items()},
              'before_method':'jet' if a.jet else 'old_ours',
              'idle_checks':{'samples':3,'interval_seconds':0.15,'single_wait_before_launch':True},
              'driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'time_scope':'complete native algorithm including internal transfer, repair, cleanup/free/trim; excludes load, upload and final download/write',
              'selection':selection['categories'],'excluded_due_to_memory':selection['excluded_due_to_memory'],
              'excluded_by_user':selection.get('excluded_by_user',[]),
              'performance_targets':selection.get('performance_targets',{}),
              'oracle_sha256':hashlib.sha256((binaries/'oracle').read_bytes()).hexdigest(),
              'manifest_sha256':hashlib.sha256((PROJECT.parent/'dataset_benchmark/manifest.json').read_bytes()).hexdigest()}
    metadata.update(omp_num_threads=4,imbalance='1.03',strict_capacity='floor(103*N/(100*k))')
    metadata.update(gpu_inventory=inventory,device_policy='one fixed GPU per graph; all methods, k and repeats use it')
    if (out/'metadata.json').exists() and json.loads((out/'metadata.json').read_text())!=metadata:
        raise RuntimeError('Benchmark identity differs')
    save(out/'metadata.json',metadata)
    if not (out/'driver.py').exists(): shutil.copy2(Path(__file__),out/'driver.py')
    if not (out/'source').exists():
        source_root=a.binary.resolve().parent/'source'
        if not source_root.exists():source_root=PROJECT
        for subdir in ['src','include','app','tests']:
            shutil.copytree(source_root/subdir,out/'source'/subdir)
        shutil.copy2(source_root/'CMakeLists.txt',out/'source/CMakeLists.txt')
    def command(method,binary,g,inputs,k,part):
        if method!='before' or not a.jet:
            return [str(binary),*map(str,inputs),str(k),str(part),'1.03','0']
        nominal=(g['vertices']+k-1)//k;capacity=(103*g['vertices'])//(100*k)
        alpha='1.03' if int(1.03*nominal)==capacity else repr((capacity+0.5)/nominal)
        config=out/(g['name']+f'-k{k}.config')
        config.write_text(chr(10).join(('0',str(k),'1',alpha,'0'))+chr(10))
        metis=PROJECT.parent/'dataset_benchmark'/g['folder']/(g['name']+'.metis')
        return [str(binary),str(metis),str(config),str(part),str(part.with_suffix('.metrics.json'))]
    runs=json.loads((out/'runs.json').read_text()) if (out/'runs.json').exists() else []
    done={(r['graph'],r['k'],r['repeat'],r['method']) for r in runs}
    env=dict(os.environ,CUDA_VISIBLE_DEVICES=UUID,OMP_NUM_THREADS='4')
    for key in ['GPART_GPU_TIMINGS','SCLP_DIAGNOSTICS','GPART_PROGRESSIVE_SMALL_K']:
        env.pop(key,None)
    env.pop('GPART_COARSE_BETA',None)
    if a.coarse_beta is not None:env['GPART_COARSE_BETA']=str(a.coarse_beta)
    if a.fine_factor is not None:env['GPART_FINE_FACTOR']=str(a.fine_factor)
    if a.capacity_growth is not None:env['GPART_CAPACITY_GROWTH']=str(a.capacity_growth)
    env['GPART_HEM_COARSEN']='1' if a.hem else '0'
    env['GPART_HEM_DEGREE_LIMIT']=str(a.hem_degree_limit)
    def method_env(method):
        own=env.copy()
        # Coarse-budget experiments change only the candidate. A reference
        # may be the very same binary running its unchanged default policy.
        if method!='after':own.pop('GPART_COARSE_BETA',None)
        return own
    assignments=json.loads((out/'gpu-assignments.json').read_text()) if (out/'gpu-assignments.json').exists() else {}
    for name in a.names:
        if a.gpu_uuid=='auto':
            if name not in assignments:
                while True:
                    active={line.strip() for line in subprocess.check_output(['nvidia-smi','--query-compute-apps=gpu_uuid','--format=csv,noheader'],text=True).splitlines()}
                    free=[row[0] for row in reversed(inventory) if row[0] not in active]
                    if free:
                        UUID=free[0];idle();break
                    time.sleep(1)
                assignments[name]=UUID;save(out/'gpu-assignments.json',assignments)
            UUID=assignments[name]
        else:
            assignments[name]=UUID;save(out/'gpu-assignments.json',assignments)
        env['CUDA_VISIBLE_DEVICES']=UUID
        g=graphs[name]; folder=PROJECT.parent/'dataset_benchmark'/g['folder']
        inputs=[folder/(name+'_indptr.bin'),folder/(name+'_indices.bin')]
        if 2*g['undirected_edges']>=2**31: raise RuntimeError('Unsupported 32-bit CSR dataset: '+name)
        for method,binary in bins.items():
            marker=out/(name+'-'+method+'-warmup.log')
            if marker.exists(): continue
            measured(command(method,binary,g,inputs,8,out/'warmup.part'),method_env(method),marker)
            discard_partition({'partition':str(out/'warmup.part')})
        for k in a.parts:
            for repeat in range(a.repeats):
                order=list(bins);shift=repeat%len(order);order=order[shift:]+order[:shift]
                for method in order:
                    key=(name,k,repeat,method)
                    if key in done: continue
                    stem=f'{name}-k{k}-r{repeat}-{method}'
                    part,log=out/(stem+'.part'),out/(stem+'.log')
                    started=datetime.now(timezone.utc).isoformat()
                    run_command=command(method,bins[method],g,inputs,k,part)
                    measured(run_command,method_env(method),log)
                    text=log.read_text()
                    if method=='after':
                        if f'seed_matching={int(a.hem)}' not in text:
                            raise RuntimeError('Requested hybrid coarsening did not apply: '+str(log))
                        if a.hem and f'heavy_edge_degree_limit={a.hem_degree_limit}' not in text:
                            raise RuntimeError('Requested matching degree limit did not apply: '+str(log))
                        pipeline=re.findall(r'^pipeline_mode=(.*)$',text,re.M)[-1]
                        observed=dict(re.findall(r'(\w+)=([^ ]+)',pipeline))
                        for parameter_name,expected in [('cluster_size_factor',a.coarse_beta),('progressive_fine_factor',a.fine_factor),('progressive_capacity_growth',a.capacity_growth)]:
                            if expected is not None and int(observed.get(parameter_name,-1))!=expected:
                                raise RuntimeError('Requested parameter did not apply: '+parameter_name+' '+str(log))
                    if a.jet and method=='before':
                        stage=json.loads(part.with_suffix('.metrics.json').read_text())[0]
                        native={'algorithm_total_seconds':stage['total-duration-seconds'],
                            'coarsen_seconds':stage['coarsen-duration-seconds'],
                            'initial_partition_seconds':stage['initial-partition-duration-seconds'],
                            'uncoarsen_seconds':stage['refine-duration-seconds'],
                            'hierarchy_free_seconds':stage['free-graph-duration-seconds']}
                        cut=int(stage['edge-cut'])
                    else:
                        timing=re.findall(r'^partition_timing (.*)$',text,re.M)[-1]
                        native={n:float(v) for n,v in re.findall(r'(\w+_seconds)=([0-9.e+-]+)',timing)}
                        cut=int(re.findall(r'^final_edge_cut=(\d+)$',text,re.M)[-1])
                    assert name==g['name'], 'Graph label changed during parameter validation'
                    row={'graph':name,'k':k,'repeat':repeat,'method':method,'started_utc':started,'gpu_uuid':UUID,
                         'command':run_command,'log':str(log),'partition':str(part),'inputs':list(map(str,inputs)),
                         'reported_cut':cut,'timing':native}
                    runs.append(row);done.add(key);save(out/'runs.json',runs)
                    print(json.dumps({n:row[n] for n in ['graph','k','repeat','method','reported_cut']}),flush=True)
    expected={(graph,parts,repeat,method) for graph in a.names for parts in a.parts for repeat in range(a.repeats) for method in bins}
    actual={(row['graph'],row['k'],row['repeat'],row['method']) for row in runs}
    assert actual==expected and len(runs)==len(expected), 'Incomplete or mislabeled experiment matrix'
    for row in runs:
        if row.get('verified'):
            discard_partition(row)
            continue
        cmd=[str(binaries/'oracle'),*row['inputs'],str(row['k']),row['partition'],'text' if a.jet and row['method']=='before' else 'binary']
        result=subprocess.run(cmd,capture_output=True,text=True,env=env,timeout=600)
        exact=json.loads(result.stdout)
        if result.returncode or exact['cut']!=row['reported_cut'] or not exact['capacity_ok']:
            row.update(verified=False, exact=exact, status='verification_failed')
            save(out/'runs.json',runs)
            discard_partition(row)
            save(out/'runs.json',runs)
            write_run_table(out/'runs.csv',runs)
            publish_tables(out)
            raise RuntimeError('Independent verification failed: '+str(row)+' '+result.stdout+' '+result.stderr)
        row.update(verified=True,exact=exact);save(out/'runs.json',runs)
        discard_partition(row)
        save(out/'runs.json',runs)
    save(out/'runs.json',runs)
    write_run_table(out/'runs.csv',runs)
    publish_tables(out)
    summary=[]
    for name in a.names:
        for k in a.parts:
            entry={'graph':name,'k':k}
            for method in bins:
                own=[r for r in runs if (r['graph'],r['k'],r['method'])==(name,k,method)]
                entry[method]={'seconds':statistics.median(r['timing']['algorithm_total_seconds'] for r in own),
                               'coarsen':statistics.median(r['timing']['coarsen_seconds'] for r in own),
                               'initial':statistics.median(r['timing']['initial_partition_seconds'] for r in own),
                               'refine':statistics.median(r['timing']['uncoarsen_seconds'] for r in own),
                               'cut':statistics.median(r['exact']['cut'] for r in own)}
            entry['speedup']=entry['before']['seconds']/entry['after']['seconds']
            entry['cut_change_percent']=100*(entry['after']['cut']/entry['before']['cut']-1)
            summary.append(entry)
    save(out/'summary.json',summary)
    print(json.dumps(summary,indent=2),flush=True)

if __name__=='__main__': main()
