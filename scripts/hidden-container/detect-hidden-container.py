#!/usr/bin/env python3
"""
Find PLAIN dm-crypt containers hidden inside cover files (zuluCrypt "hidden in video" mode).

Usage:
    detect-hidden-container.py                  -> scan your own files for candidates
    detect-hidden-container.py /path/to/file    -> analyse only the given file

If the given path does not exist, falls back to the scan mode.
"""
import os, sys, struct, subprocess, tempfile, getpass

KB = 1024; MB = KB*KB; GB = MB*KB

CIPHERS = [
    "aes.cbc-essiv:sha256.256.sha256", "aes.cbc-essiv:sha256.256.sha512",
    "aes.cbc-essiv:sha256.256.sha1",   "aes.cbc-essiv:sha256.256.ripemd160",
    "aes.cbc-essiv:sha256.512.sha256", "aes.cbc-essiv:sha256.512.sha512",
    "aes.cbc-essiv:sha256.512.sha1",   "aes.cbc-essiv:sha256.512.ripemd160",
    "aes.xts-plain64.256.sha256",      "aes.xts-plain64.256.sha512",
    "aes.xts-plain64.256.sha1",        "aes.xts-plain64.256.ripemd160",
    "aes.xts-plain64.512.sha256",      "aes.xts-plain64.512.sha512",
    "aes.xts-plain64.512.sha1",        "aes.xts-plain64.512.ripemd160",
]

# ---------- where the cover file legitimately ends ----------

def end_mp4(h, sz):
    pos = 0; seen = 0
    while pos < sz:
        h.seek(pos); hdr = h.read(8)
        if len(hdr) < 8: break
        n = struct.unpack('>I', hdr[:4])[0]; typ = hdr[4:8]
        if not all(32 <= c < 127 for c in typ): break
        if n == 1:
            e = h.read(8)
            if len(e) < 8: break
            n = struct.unpack('>Q', e)[0]
        elif n == 0:
            n = sz - pos
        if n < 8 or pos + n > sz: break
        seen += 1; pos += n
    return pos if seen >= 2 else None

def end_riff(h, sz):
    # An AVI over 2 GB is OpenDML: a chain of RIFF/AVIX chunks; walk all of them
    pos = 0; k = 0
    while pos < sz:
        h.seek(pos); d = h.read(12)
        if len(d) < 12 or d[:4] != b'RIFF': break
        n = struct.unpack('<I', d[4:8])[0]
        if n < 4: break
        pos += 8 + n; k += 1
    return pos if k else None

def _vint(h, mask):
    b = h.read(1)
    if not b: return None, 0
    v = b[0]; n = 0
    for i in range(8):
        if v & (0x80 >> i): n = i+1; break
    if n == 0: return None, 0
    val = (v & (0xFF >> n)) if mask else v
    rest = h.read(n-1)
    if len(rest) < n-1: return None, 0
    for c in rest: val = (val << 8) | c
    return val, n

def end_mkv(h, sz):
    h.seek(0)
    if h.read(4) != b'\x1aE\xdf\xa3': return None
    pos = 0
    while pos < sz:
        h.seek(pos)
        eid, n1 = _vint(h, False)
        if eid is None: break
        size, n2 = _vint(h, True)
        if size is None: break
        if size >= (1 << (7*n2)) - 1: return None   # unknown size
        pos += n1 + n2 + size
        if pos > sz: return None
    return pos

def end_zip(h, sz):
    # The index (EOCD) sits at the end of the archive, but an attached container can
    # push it arbitrarily far from the end, so search the whole file, not just the tail.
    import mmap
    try:
        with mmap.mmap(h.fileno(), 0, access=mmap.ACCESS_READ) as m:
            i = m.rfind(b'PK\x05\x06')
            if i < 0 or i + 22 > sz: return None
            clen = struct.unpack('<H', m[i+20:i+22])[0]
            return i + 22 + clen
    except Exception:
        return None

def end_pdf(h, sz):
    import mmap
    try:
        with mmap.mmap(h.fileno(), 0, access=mmap.ACCESS_READ) as m:
            i = m.rfind(b'%%EOF')
            return (i + 5) if i >= 0 else None
    except Exception:
        return None

HANDLERS = {
    '.mp4': end_mp4, '.mov': end_mp4, '.m4v': end_mp4, '.m4a': end_mp4, '.3gp': end_mp4,
    '.avi': end_riff, '.wav': end_riff,
    '.mkv': end_mkv, '.webm': end_mkv,
    '.zip': end_zip, '.docx': end_zip, '.xlsx': end_zip, '.pptx': end_zip,
    '.jar': end_zip, '.apk': end_zip,
    '.pdf': end_pdf,
}

def host_end(path):
    ext = os.path.splitext(path)[1].lower()
    fn = HANDLERS.get(ext)
    if not fn: return None
    try:
        sz = os.path.getsize(path)
        with open(path, 'rb') as h:
            e = fn(h, sz)
        if e and 0 < e <= sz: return e
    except Exception:
        pass
    return None

def tier_round(o):
    u = GB if o >= GB else MB if o >= MB else KB if o >= KB else None
    return o if u is None else ((o + u - 1)//u)*u

# ---------- offset candidates ----------

COMMON = [1,2,4,5,8,10,16,20,25,32,40,50,64,75,100,128,150,200,250,256,300,400,500,512,
          750,1000,1024,1500,2000,2048,3000,4000,4096,5000,6000,8000,8192,10000,16000,
          16384,20000,25000,32000,32768,50000,51200,65536,100000,102400]

def candidates(size, known_end=None):
    out = []; seen = set()
    def tier_ok(o):
        if o >= GB: return o % GB == 0
        if o >= MB: return o % MB == 0
        if o >= KB: return o % KB == 0
        return False
    def add(o):
        if o and o > 0 and o < size and o not in seen:
            seen.add(o); out.append(o)
    if known_end:                      # most likely, from the file structure
        add(tier_round(known_end))
        add((known_end//KB)*KB)
    # Order: first the offsets derived from whole-MB container sizes, which cover the
    # usual case (a single creation pass) in a few attempts.
    for c in COMMON + list(range(1, size//MB + 1)):
        raw = size - c*MB
        if raw <= 0: continue
        o = (raw//KB)*KB
        if tier_ok(o): add(o)

    # Then the COMPLETE set of offsets the create dialog can produce: the offset is
    # always the host size rounded UP to its own KB/MB/GB tier. The relation
    # "file size - offset = a whole number of MB" is lost when containers are stacked,
    # so without these variants the older containers in the stack cannot be found.
    for k in range(1, 1025):
        add(k*KB)
    for k in range(1, 1025):
        add(k*MB)
    k = 1
    while k*GB < size:
        add(k*GB); k += 1
    return out

# ---------- automatic discovery ----------

def discover():
    roots = [os.path.expanduser('~')]
    for extra in ('/media', '/mnt', '/run/media'):
        if os.path.isdir(extra): roots.append(extra)
    found = []
    for r in roots:
        for dp, dn, fn in os.walk(r):
            dn[:] = [d for d in dn if not d.startswith('.') and
                     d not in ('snap','node_modules','__pycache__')]
            for name in fn:
                if os.path.splitext(name)[1].lower() not in HANDLERS: continue
                p = os.path.join(dp, name)
                try:
                    sz = os.path.getsize(p)
                except OSError:
                    continue
                if sz < 64*KB: continue
                e = host_end(p)
                if e is None: continue
                if sz - e > 512*KB:
                    found.append((sz-e, sz, e, p))
    found.sort(reverse=True)
    return found

# ---------- probing ----------

PROBE_NAME = 'zc-detect-%d' % os.getpid()

def probe(path, cipher, offset, keyfile):
    r = subprocess.run(['zuluCrypt-cli','-o','-d',path,'-m',PROBE_NAME,'-e','ro',
                        '-t', f'{cipher}.{offset}b', '-f', keyfile],
                       capture_output=True, text=True)
    out = (r.stdout or '') + (r.stderr or '')
    if 'opened mapper' in out: return 'BUSY'
    # A mount point left over from an interrupted run makes every later probe fail
    # this way. Reading it as "wrong key" would make a whole scan report nothing.
    if 'mount point' in out: return 'MOUNTFAIL'
    if 'SUCCESS' in out: return 'OK'
    return 'NO'

def close(path):
    subprocess.run(['zuluCrypt-cli','-q','-d',path],
                   capture_output=True, text=True)

def search(path, find_all=False):
    sz = os.path.getsize(path)
    e = host_end(path)
    print(f"\nFile   : {path}")
    print(f"Size   : {sz:,} bytes")
    if e:
        print(f"Cover file ends at {e:,} -> attached data: {sz-e:,} bytes")
        print(f"Most likely offset: {tier_round(e):,}")
    else:
        print("Cannot tell from the file structure where the cover ends; trying every candidate.")

    cands = candidates(sz, e)
    if not cands:
        print("The file is too small to hold a container."); return 1
    print(f"Offset candidates: {len(cands)}")

    try:
        pw = getpass.getpass("Volume passphrase: ")
    except (EOFError, KeyboardInterrupt):
        print("\nAborted."); return 2
    if not pw:
        print("Empty passphrase, aborting."); return 2

    hits = []
    fd, keyfile = tempfile.mkstemp()

    def report(off, c, idx):
        print("\r" + " "*46)
        print(f"=========== FOUND #{idx} ===========")
        print(f"  offset : {off} bytes")
        print(f"  cipher : {c}")
        print("\nOpen it with:")
        print(f'  zuluCrypt-cli -o -d "{path}" -m secret -t {c}.{off}b -h')
        print()

    try:
        os.write(fd, pw.encode()); os.close(fd); os.chmod(keyfile, 0o600)

        # Phase 1: find ONE container. The default cipher covers most cases; if not,
        # try all 16. Stopping at the first match lets phase 2 work with a single
        # cipher instead of sixteen.
        found_cipher = None
        n = 0
        for label, ciphers in (("the default cipher", CIPHERS[:1]),
                               ("all 16 ciphers", CIPHERS)):
            print(f"--- phase 1: searching with {label} ---")
            for c in ciphers:
                for off in cands:
                    n += 1
                    if n % 25 == 0:
                        print(f"\r  attempts: {n}", end='', flush=True)
                    r = probe(path, c, off, keyfile)
                    if r == 'BUSY':
                        print("\rThe volume is already open. Close it with:")
                        print(f'  zuluCrypt-cli -q -d "{path}"')
                        return 1
                    if r == 'MOUNTFAIL':
                        print("\rCannot create a mount point for the probes, so I am stopping")
                        print("the scan instead of wrongly reporting that nothing was found.")
                        print("Close any open volume and try again:")
                        print("  ls /run/media/private/$USER/")
                        return 1
                    if r == 'OK':
                        close(path)
                        found_cipher = c
                        hits.append((off, c))
                        report(off, c, 1)
                        break
                if found_cipher: break
            if found_cipher: break
            print("\r" + " "*46, end='\r')

        if not found_cipher:
            print("\nNo container found. Causes: wrong passphrase, the file holds no")
            print("container, or it was created with non-standard options.")
            return 1

        if not find_all:
            print("Run again with --all if you stacked several containers.")
            return 0

        # Phase 2: now that the cipher is known, sweep every offset for the rest of the stack.
        print(f"--- phase 2: searching the rest of the stack with {found_cipher} ---")
        n = 0
        for off in cands:
            if any(o == off for o, _ in hits):
                continue
            n += 1
            if n % 25 == 0:
                print(f"\r  attempts: {n}/{len(cands)}", end='', flush=True)
            r = probe(path, found_cipher, off, keyfile)
            if r == 'BUSY':
                print("\rA volume was left open; closing it and continuing.")
                close(path); continue
            if r == 'MOUNTFAIL':
                print("\rThe probe mount point is blocked; stopping phase 2 here")
                print("instead of silently missing containers.")
                break
            if r == 'OK':
                close(path)
                hits.append((off, found_cipher))
                report(off, found_cipher, len(hits))
        print("\r" + " "*46, end='\r')
    finally:
        os.unlink(keyfile)

    if hits:
        print(f"\nContainers found: {len(hits)}")
        for i, (off, c) in enumerate(hits, 1):
            print(f"  #{i}  offset {off:>14,}   {c}")
        return 0

    print("\nNo container found. Causes: wrong passphrase, the file holds no")
    print("container, or it was created with non-standard options.")
    return 1

def main():
    args = [a for a in sys.argv[1:] if a not in ('--all', '-a')]
    find_all = len(args) != len(sys.argv[1:])
    arg = args[0] if args else None

    if find_all:
        print("--all mode: looking for ALL stacked containers, not only the first.")

    if arg and os.path.isfile(arg):
        return search(os.path.abspath(arg), find_all)

    if arg:
        print(f"Path '{arg}' does not exist. Scanning for files that look like they hide a container.\n")

    print("Scanning... (may take a minute)")
    found = discover()
    if not found:
        print("\nFound no file with data attached after its end.")
        print("If you know the file, pass it as an argument:")
        print(f"  {sys.argv[0]} /real/path/to/file")
        return 1

    print(f"\nFiles that look like they hide a container:\n")
    for i, (trail, sz, e, p) in enumerate(found[:20], 1):
        print(f"  [{i}] {trail/MB:8.1f} MB attached   (file {sz/MB:.1f} MB)   {p}")

    try:
        sel = input(f"\nChoose a number (1-{min(len(found),20)}), Enter = 1: ").strip() or "1"
        idx = int(sel) - 1
        if not (0 <= idx < min(len(found),20)): raise ValueError
    except (ValueError, EOFError, KeyboardInterrupt):
        print("Invalid selection."); return 2

    return search(found[idx][3], find_all)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted."); sys.exit(130)
