"""Resume la Evidence de inspect_native_dispatch_metadata: clases ObjC, ivars tipados y selectores."""
import json,sys,collections
d=json.load(open(sys.argv[1])); r=d['normalized_result']['result']
iv=collections.defaultdict(list)
for i in r['objc_ivars']: iv[i['class_name']].append(f"{i['name']}: {i['type_encoding']}")
out=[f"# {d['subject']['name']} — dispatch metadata (REA evidence {d['evidence_id']})",
     "# coverage: "+", ".join(f"{c['facet']}={c['status']}" for c in r['coverage']),""]
for c in sorted(r['objc_classes'],key=lambda c:c['name']):
    if c.get('is_meta_class'): continue
    out.append(f"class {c['name']} : {c.get('super_class')}")
    for x in iv.get(c['name'],[]): out.append(f"    ivar {x}")
    for m in c.get('methods',[]): out.append(f"    {'+' if m['method_type']=='class' else '-'} {m['selector']}")
out.append("\n# protocols")
for p in sorted(r['objc_protocols'],key=lambda p:p['name']):
    out.append(f"protocol {p['name']}: "+", ".join(m['selector'] for m in p.get('methods',[]))[:600])
open(sys.argv[2],'w').write("\n".join(out)+"\n")
print(len(r['objc_classes']),'classes',len(r['objc_ivars']),'ivars',len(r['swift_decls']),'swift_decls',len(r['swift_conformances']),'conf')
