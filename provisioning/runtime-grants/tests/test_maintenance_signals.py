"""Real Linux signals in owned child processes; no database or remote calls."""
from pathlib import Path
import signal
import subprocess
import sys
import unittest


@unittest.skipUnless(hasattr(signal,"SIGHUP"),"Real Unix signal semantics required")
class SignalTests(unittest.TestCase):
    def test_first_and_repeated_termination_are_reported_only_after_barrier_exit(self):
        for when in ("enter","body","exit"):
            with self.subTest(when=when):
                program=r"""import contextlib,os,signal,sys
sys.path.insert(0,sys.argv[1]);import maintenance_signals
when=sys.argv[2];events=[]
class Barrier:
 def __enter__(self):
  events.append('open')
  if when=='enter':os.kill(os.getpid(),signal.SIGHUP)
  return self
 def __exit__(self,*error):
  if when=='exit':
   os.kill(os.getpid(),signal.SIGTERM);os.kill(os.getpid(),signal.SIGHUP)
  events.append('closed')
try:
 with getattr(maintenance_signals,'defer_termination',contextlib.nullcontext)():
  with Barrier():
   if when=='body':os.kill(os.getpid(),signal.SIGTERM)
 assert False,'termination must be reported instead of success'
except ValueError as error:
 assert str(error)=='MAINTENANCE_INTERRUPTED_AFTER_CLEANUP'
assert events==['open','closed'],events
print('barrier_closed_before_interrupt')
"""
                result=subprocess.run([sys.executable,"-c",program,str(Path(__file__).parents[1]),when],text=True,capture_output=True,timeout=5)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),"barrier_closed_before_interrupt")


if __name__=="__main__":unittest.main()
