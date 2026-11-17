import struct
def u30(d,p):
    a=int.from_bytes(d[p:p+4].ljust(4,b'\0'),'little'); n=(a&3)+1
    return (a & ((1<<(8*n))-1))>>2, p+n
def find_node_blob(binpath, ro_checksum):
    d=open(binpath,'rb').read()
    ver=b'15.6.75.25-electron.0'; i=0
    while True:
        i=d.find(ver,i+1)
        if i<0: raise Exception('blob not found')
        b=i-16
        if struct.unpack_from('<I',d,b+12)[0]==ro_checksum: return d,b
def ro_image(d,base):
    nctx=struct.unpack_from('<I',d,base)[0]
    startup=struct.unpack_from('<I',d,base+0x50)[0]
    p=base+((0x58+4*nctx+7)&~7)+8; end=base+startup
    pages={}; img={}
    while p<end:
        bc=d[p]; p+=1
        if bc in (0,1):
            i,p=u30(d,p); sz,p=u30(d,p)
            if bc==1: p+=4
            pages[i]=sz; img[i]=bytearray(0x10+sz)
        elif bc==2:
            i,p=u30(d,p); off,p=u30(d,p); sz,p=u30(d,p)
            img[i][0x10+off:0x10+off+sz]=d[p:p+sz]; p+=sz
        elif bc in (4,5): break
        else: raise Exception('bad ro bytecode %d'%bc)
    return img
