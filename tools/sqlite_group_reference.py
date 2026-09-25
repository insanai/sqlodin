"""Pinned SQLite FIFO reference: up to 16 already-waiting requests per FULL commit.

No batching timer. Every response follows the outer commit; callers cannot use
this helper with invalid transactions. It is a qualification reference only.
"""
import queue
import threading


class GroupReference:
    def __init__(self, database, maximum=16):
        self.database = database
        self.maximum = maximum
        self.queue = queue.Queue(maxsize=64)
        self.groups = []
        self.thread = threading.Thread(target=self._serve)
        self.thread.start()

    def _serve(self):
        while True:
            first = self.queue.get()
            if first is None:
                return
            group = [first]
            for _ in range(self.maximum-1):
                try:
                    group.append(self.queue.get_nowait())
                except queue.Empty:
                    break
            writing = any(request[1] for request in group)
            error = None
            try:
                if writing:
                    self.database.run('BEGIN IMMEDIATE')
                for text, _, _, _ in group:
                    self.database.run(text)
                if writing:
                    self.database.run('COMMIT')
            except BaseException as exc:
                error = exc
                if writing:
                    self.database.run('ROLLBACK')
            self.groups.append(dict(requests=len(group), writes=sum(r[1] for r in group)))
            for _, _, done, result in group:
                result.append(error)
                done.set()

    def connect(self):
        return GroupConnection(self)

    def close(self):
        self.queue.put(None)
        self.thread.join(timeout=60)
        assert not self.thread.is_alive()


class GroupConnection:
    def __init__(self, owner):
        self.owner = owner

    def run(self, text, write=False):
        done, result = threading.Event(), []
        self.owner.queue.put((text, write, done, result), timeout=60)
        assert done.wait(timeout=60), 'Reference worker did not respond'
        if result[0] is not None:
            raise result[0]

    def close(self):
        pass
