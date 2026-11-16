import sys,re
p='docs/PROGRESS.md'
s=open(p,encoding='utf-8').read()
s=re.sub(r'- \[ \] %s ([^\n]*)'%sys.argv[1], lambda m:'- [x] %s %s — %s'%(sys.argv[1],m.group(1),sys.argv[2]), s)
open(p,'w',encoding='utf-8',newline='\n').write(s)
