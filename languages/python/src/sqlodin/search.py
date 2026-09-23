"""FTS5 and exact vector retrieval over one atomically maintained search index."""
import re
from .vector import Vector


def identifier(name: str) -> str:
    if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}', name):
        raise ValueError('Index names need 1..64 ASCII letters, digits or underscores, starting with a letter')
    if name.lower().startswith('sqlite_'):
        raise ValueError('Reserved index name')
    return '"' + name + '"'


def bound(value, name, maximum=100):
    if type(value) is not int or not 1 <= value <= maximum:
        raise ValueError(f'{name} must be an integer in 1..{maximum}')
    return value


class SearchIndex:
    def __init__(self, connection, name: str, *, dimensions: int):
        self.connection, self.name = connection, name
        if not isinstance(name, str) or len(name) > 60:
            raise ValueError("Search index names must be at most 60 characters")
        self.table, self.fts = identifier(name), identifier(name + '_fts')
        self.dimensions = bound(dimensions, 'dimensions', 384)

    def create(self):
        """Fail if either table exists; never silently accept a different schema."""
        return self.connection.execute(
            f'CREATE TABLE {self.table}(id INTEGER PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,'
            f'embedding BLOB NOT NULL CHECK(length(embedding)={self.dimensions * 4}));'
            f'CREATE VIRTUAL TABLE {self.fts} USING fts5(title,body);')

    def _vector(self, value):
        value = value if isinstance(value, Vector) else Vector(value)
        if len(value) != self.dimensions:
            raise ValueError(f'Expected {self.dimensions} vector dimensions, received {len(value)}')
        return value

    def put(self, id: int, *, title: str, body: str, vector):
        """Atomically insert/update the content, embedding, and FTS document."""
        if type(id) is not int or not 1 <= id < 2**63 - 1:
            raise ValueError('Document ID must be a positive integer below SQLite maximum rowid')
        value = self._vector(vector)
        with self.connection.transaction() as tx:
            tx.execute(f'INSERT INTO {self.table}(id,title,body,embedding) VALUES(?,?,?,?) '
                       'ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,'
                       'embedding=excluded.embedding', (id, title, body, value))
            tx.execute(f'DELETE FROM {self.fts} WHERE rowid=?', (id,))
            tx.execute(f'INSERT INTO {self.fts}(rowid,title,body) VALUES(?,?,?)', (id, title, body))
        return tx.result

    def delete(self, id: int):
        if type(id) is not int or not 1 <= id < 2**63 - 1:
            raise ValueError('Invalid document ID')
        with self.connection.transaction() as tx:
            tx.execute(f'DELETE FROM {self.fts} WHERE rowid=?', (id,))
            tx.execute(f'DELETE FROM {self.table} WHERE id=?', (id,))
        return tx.result

    def full_text(self, text: str, *, limit: int = 20):
        """FTS5 query syntax; lower BM25 score is better. SQL values stay bound."""
        bound(limit, 'limit')
        return self.connection.query(
            f'SELECT d.id,d.title,d.body,bm25({self.fts}) AS score '
            f'FROM {self.fts} JOIN {self.table} AS d ON d.id={self.fts}.rowid '
            f'WHERE {self.fts} MATCH ? ORDER BY score,d.id LIMIT ?', (text, limit))

    def nearest(self, vector, *, limit: int = 20, metric: str = 'l2'):
        """Exact distance scan, not an ANN index. Lower distance is better."""
        function = self._metric(metric)
        value = self._vector(vector)
        if metric == 'cosine' and not any(value):
            raise ValueError('Cosine distance requires a nonzero query vector')
        bound(limit, 'limit')
        return self.connection.query(
            f'SELECT id,title,body,{function}(embedding,?) AS distance FROM {self.table} '
            'ORDER BY distance,id LIMIT ?', (value, limit))

    @staticmethod
    def _metric(metric):
        if metric not in ('l2', 'cosine'):
            raise ValueError("Metric must be 'l2' or 'cosine'")
        return 'vec_distance_' + metric

    def hybrid(self, text: str, vector, *, limit: int = 20, candidates: int = 50,
               rank_constant: int = 60, metric: str = 'l2'):
        """Reciprocal-rank fusion of FTS and vector candidates in one fenced snapshot."""
        bound(limit, 'limit')
        bound(candidates, 'candidates')
        bound(rank_constant, 'rank_constant', 1000)
        if candidates < limit:
            raise ValueError('Candidates must be at least limit')
        function = self._metric(metric)
        value = self._vector(vector)
        if metric == 'cosine' and not any(value):
            raise ValueError('Cosine distance requires a nonzero query vector')
        sql = f'''WITH
          ft AS MATERIALIZED (SELECT rowid AS id,bm25({self.fts}) AS score FROM {self.fts}
            WHERE {self.fts} MATCH ? ORDER BY score,id LIMIT ?),
          vt AS MATERIALIZED (SELECT id,{function}(embedding,?) AS distance FROM {self.table}
            ORDER BY distance,id LIMIT ?),
          ranks AS (SELECT id,ROW_NUMBER() OVER(ORDER BY score,id) AS rank FROM ft
            UNION ALL SELECT id,ROW_NUMBER() OVER(ORDER BY distance,id) AS rank FROM vt),
          fused AS (SELECT id,SUM(1.0 / (? + rank)) AS score FROM ranks GROUP BY id)
          SELECT d.id,d.title,d.body,f.score FROM fused AS f JOIN {self.table} AS d ON d.id=f.id
          ORDER BY f.score DESC,d.id LIMIT ?'''
        return self.connection.query(sql, (text, candidates, value, candidates,
                                           rank_constant, limit))
