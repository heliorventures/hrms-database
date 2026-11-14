"""Report catchable termination only after a bounded maintenance block closes.

Wrap the complete admission context, including __enter__ and __exit__. Recording
signals (rather than raising inside cleanup) lets its normal closure/readback run.
The operator receives interruption instead of a successful completion receipt.
"""
from contextlib import contextmanager
import signal
import sys
import threading


@contextmanager
def defer_termination():
    if threading.current_thread() is not threading.main_thread():
        raise ValueError("MAIN_THREAD_MAINTENANCE_REQUIRED")
    pending=[]
    previous={}
    def record(signum,frame):
        pending.append(signum)
    try:
        for name in ("SIGHUP","SIGTERM","SIGINT"):
            signum=getattr(signal,name,None)
            if signum is not None:
                previous[signum]=signal.getsignal(signum)
                signal.signal(signum,record)
        yield
    finally:
        for signum,handler in previous.items():
            signal.signal(signum,handler)
        # Preserve an existing barrier/transport error over cancellation.
        if pending and sys.exc_info()[0] is None:
            raise ValueError("MAINTENANCE_INTERRUPTED_AFTER_CLEANUP")
