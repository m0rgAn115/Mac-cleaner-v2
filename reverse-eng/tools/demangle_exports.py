import json,sys,subprocess,os,re
E,O=sys.argv[1],sys.argv[2]
dm='/Library/Developer/CommandLineTools/usr/bin/swift-demangle'
skip=re.compile(r'^(type metadata|nominal type descriptor|protocol conformance descriptor|method descriptor|outlined|reabstraction|value witness|associated|base conformance|merged|protocol witness table|property descriptor|key path|type metadata accessor|dispatch thunk of|lazy cache|metaclass|class metadata|full type|flat unique|protocol requirements base)')
for fn in sorted(os.listdir(E)):
    if not fn.startswith('10-macho-'): continue
    mod=fn[9:-5]; d=json.load(open(os.path.join(E,fn)))
    names=[x['name'] for x in d['normalized_result']['exports']['items']]
    sw=[n[1:] for n in names if n.startswith('_$s')]
    out=subprocess.run([dm,'-simplified'],input='\n'.join(sw),capture_output=True,text=True).stdout.splitlines()
    keep=sorted(set(l for l in out if not skip.match(l)))
    other=sorted(n for n in names if not n.startswith('_$s'))
    with open(f'{O}/{mod}.txt','w') as f:
        f.write(f'# {mod} — demangled exported symbols (REA inspect-macho evidence {d["evidence_id"]})\n# total exports={len(names)}; swift={len(sw)}; shown (filtered of metadata/witness noise)={len(keep)}\n\n')
        f.write('\n'.join(keep)+'\n')
        if other: f.write('\n# non-Swift exports\n'+'\n'.join(other)+'\n')
