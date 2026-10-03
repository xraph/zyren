"""Bounded local process client. Native builds must finish before launch."""
from collections import deque
from concurrent.futures import Future
from pathlib import Path
import subprocess
import queue
import threading

from .protocol import Frame, MAX_HEADER, MAX_MESSAGE, ProtocolError, encode, read_frame


class WorkerFailed(RuntimeError):
    pass


class Worker:
    def __init__(self, command, *, cwd, run_id='local', timeout=10,
                 max_header=MAX_HEADER, max_message=MAX_MESSAGE):
        if not command or not all(isinstance(value, str) and value for value in command):
            raise ValueError('explicit worker command is required')
        if not 0 < timeout <= 300 or not 256 <= max_header <= MAX_HEADER or not max_header + 4 <= max_message <= MAX_MESSAGE:
            raise ValueError('invalid worker bounds')
        self.run_id, self.timeout = run_id, timeout
        self.cwd = Path(cwd).resolve()
        self.max_header, self.max_message = max_header, max_message
        self._lock = threading.Lock()
        self._pending, self._sequence, self._failed, self._closed = {}, 0, None, False
        self.stderr = deque(maxlen=64)
        self._write_queue = queue.Queue(maxsize=8)
        self.process = subprocess.Popen(list(command), cwd=self.cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        threading.Thread(target=self._receive, daemon=True).start()
        self._sender = threading.Thread(target=self._send, daemon=True)
        self._sender.start()
        threading.Thread(target=self._logs, daemon=True).start()
        try:
            result = self.call('hello', environment_id='supervisor', episode_id='none', actor_ids=[], tick=0,
                               extra={'max_header': max_header, 'max_message': max_message})
            h = result.header
            if not 256 <= h['max_header'] <= max_header or not h['max_header'] + 4 <= h['max_message'] <= max_message:
                raise ProtocolError('worker raised negotiated bounds')
            self.max_header, self.max_message = h['max_header'], h['max_message']
        except Exception:
            self.close()
            raise

    def _logs(self):
        try:
            while True:
                chunk = self.process.stderr.read(4096)
                if not chunk:
                    return
                self.stderr.append(chunk.decode('utf-8', errors='replace'))
        except (OSError, ValueError):
            return

    def _send(self):
        while True:
            data = self._write_queue.get()
            if data is None or self._closed:
                return
            try:
                view = memoryview(data)
                while view:
                    written = self.process.stdin.write(view)
                    if not written:
                        raise BrokenPipeError('worker input closed')
                    view = view[written:]
                self.process.stdin.flush()
            except (OSError, ValueError) as error:
                if not self._closed:
                    self._fail(error)
                return

    def _fail(self, error):
        with self._lock:
            if self._failed is None:
                self._failed = WorkerFailed(str(error) or type(error).__name__)
            pending = list(self._pending.values())
            self._pending.clear()
        for _, future in pending:
            if not future.done():
                future.set_exception(self._failed)
        if self.process.poll() is None:
            self.process.kill()

    def _receive(self):
        try:
            while True:
                frame = read_frame(self.process.stdout, max_header=self.max_header, max_message=self.max_message)
                sequence = frame.header['sequence']
                with self._lock:
                    pending = self._pending.pop(sequence, None)
                if pending is None:
                    raise ProtocolError('unexpected or duplicate worker response')
                header, future = pending
                for key in ('run_id', 'environment_id', 'operation'):
                    if frame.header[key] != header[key]:
                        error = ProtocolError('worker response identity differs')
                        future.set_exception(WorkerFailed(str(error) or type(error).__name__))
                        raise error
                future.set_result(frame)
        except Exception as error:
            if not self._closed:
                self._fail(error)

    def call(self, operation, *, environment_id, episode_id, actor_ids, tick, arrays=None, extra=None, actor_generations=None):
        with self._lock:
            if self._closed or self._failed:
                raise self._failed or WorkerFailed('worker is closed')
            if len(self._pending) >= 16:
                raise ProtocolError('pending request budget exceeded')
            self._sequence += 1
            h = dict(extra or {}, version=1, operation=operation, sequence=self._sequence,
                     run_id=self.run_id, environment_id=environment_id, episode_id=episode_id,
                     actor_ids=list(actor_ids), actor_generations=dict(actor_generations or {a: 1 for a in actor_ids}), tick=tick)
            frame = Frame.from_arrays(h, arrays or {})
            data = encode(frame, max_header=self.max_header, max_message=self.max_message)
            future = Future()
            self._pending[h['sequence']] = (h, future)
            try:
                self._write_queue.put_nowait(data)
            except queue.Full as error:
                self._pending.pop(h['sequence'], None)
                raise ProtocolError('worker write backpressure budget exceeded') from error
            data = frame = None

        try:
            response = future.result(timeout=self.timeout)
        except Exception as error:
            self._fail(error)
            raise WorkerFailed(str(error) or type(error).__name__) from error
        if response.header.get('ok') is not True:
            if response.header.get('ok') is not False:
                self._fail(ProtocolError('invalid response acceptance flag'))
                raise self._failed
            raise ProtocolError(response.header.get('error', 'worker rejected request'))
        return response

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
            pending = list(self._pending.values())
            self._pending.clear()
        for _, future in pending:
            if not future.done():
                future.set_exception(WorkerFailed('worker closed'))
        try:
            self._write_queue.put_nowait(None)
        except queue.Full:
            pass
        self._sender.join(timeout=.2)
        # Closing the pipe delivers EOF so the Dart host can dispose its isolates.
        closing = threading.Thread(target=self.process.stdin.close, daemon=True)
        closing.start()
        closing.join(timeout=.2)
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        closing.join(timeout=.2)
        self.process.stdout.close()
        self.process.stderr.close()
