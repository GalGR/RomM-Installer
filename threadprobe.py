import os, resource, sys, threading
def probe(stack_kib):
    if stack_kib: threading.stack_size(stack_kib * 1024)
    stop = threading.Event(); ts = []
    try:
        while len(ts) < 2000:
            t = threading.Thread(target=stop.wait, daemon=True); t.start(); ts.append(t)
        err = "hit the 2000 safety stop"
    except RuntimeError as e:
        err = str(e)
    n = len(ts); stop.set()
    for t in ts: t.join()
    return n, err
lim = lambda r: "unlimited" if r == resource.RLIM_INFINITY else r
print(f"nproc={os.cpu_count()}  RLIMIT_NPROC={lim(resource.getrlimit(resource.RLIMIT_NPROC)[0])}  "
      f"RLIMIT_AS={lim(resource.getrlimit(resource.RLIMIT_AS)[0])}  RLIMIT_STACK={lim(resource.getrlimit(resource.RLIMIT_STACK)[0])}")
for kib in (0, 256):
    n, err = probe(kib)
    print(f"stack={'default' if not kib else str(kib)+' KiB':>8}: started {n} extra threads, then: {err}")
