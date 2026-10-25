import re,sys
ATTR=re.compile(r'^(\s*)([A-Za-z0-9_"\-.]+)(\s*)=(\s*)(.*)$')
def multiline(v):
    v=v.strip()
    if v.endswith(('{','[','(')) or v.startswith('<<'): return True
    return False
def check(path):
    lines=open(path).read().split('\n'); bad=[]; i=0
    while i<len(lines):
        m=ATTR.match(lines[i])
        if m and not multiline(m.group(5)) and not lines[i].strip().startswith('#'):
            j=i; run=[]
            while j<len(lines):
                mm=ATTR.match(lines[j])
                if mm and mm.group(1)==m.group(1) and not multiline(mm.group(5)) and not lines[j].strip().startswith('#'):
                    run.append((j,mm)); j+=1
                else: break
            width=max(len(r[1].group(2)) for r in run)
            for idx,mm in run:
                want=mm.group(1)+mm.group(2)+' '*(width-len(mm.group(2))+1)+'= '+mm.group(5)
                if lines[idx]!=want: bad.append((idx+1,lines[idx],want))
            i=j
        else: i+=1
    return bad
rc=0
for p in sys.argv[1:]:
    b=check(p)
    print(p, "OK" if not b else f"{len(b)} misaligned")
    for n,have,want in b[:8]: print("  line",n,"\n   have:",have,"\n   want:",want)
    rc|=bool(b)
sys.exit(rc)
