import json
import pytest
import sqlodin
from sqlodin.client import Connection
from sqlodin.parameters import prepare
from sqlodin.transport import Transport


def test_qmarks_respect_sql_lexical_boundaries():
    sql, values = prepare("SELECT '?', \"?\", `?`, [?], ? -- ?\n/* ? */ , ?", (1, 2), offset=3)
    assert '?4 -- ?' in sql and sql.endswith('?5')
    assert values == (1, 2)
    for sql in ('SELECT ?1', 'SELECT :x', "SELECT 'unterminated", 'SELECT /* no end'):
        with pytest.raises(ValueError):
            prepare(sql, (1,))


def test_parameter_bounds():
    for value in (2**63, float('inf'), 'x' * 257):
        with pytest.raises(ValueError):
            prepare('SELECT ?', (value,))
    with pytest.raises(TypeError):
        prepare('SELECT ?', (b'blob',))
    with pytest.raises(ValueError):
        prepare('SELECT ?', ())


def test_rows_and_duplicate_names():
    row = sqlodin.Row(('id', 'id'), (1, 2))
    assert row['id'] == 1 and row[1] == 2
    assert row.as_tuple() == (1, 2) and dict(row) == {'id': 1}
    with pytest.raises(KeyError):
        row['missing']
    rows = sqlodin.Rows(('id',), (sqlodin.Row(('id',), (42,)),), 10, 1)
    assert rows.scalar() == 42
    with pytest.raises(ValueError):
        sqlodin.Rows((), (), 0, 1).one()


def make_db(monkeypatch, exchange, epoch=0):
    monkeypatch.setattr(Transport, '__init__', lambda self, tls: None)
    monkeypatch.setattr(Transport, 'close', lambda self: None)
    def serving(self, endpoint, request, deadline):
        if request['op'] == 'session_epoch' and epoch is not None:
            return dict(reply(request), session_epoch=epoch)
        return exchange(self, endpoint, request, deadline)
    monkeypatch.setattr(Transport, 'exchange', serving)
    return sqlodin.connect([sqlodin.Endpoint('127.0.0.1:1', 'one'), sqlodin.Endpoint('127.0.0.1:2', 'two')],
                           cluster='test', tls=None, timeout=0.05)


def reply(request, code=''):
    return dict(cluster='test', protocol=1, node=2, applied=10, changes=1,
                sequence=request.get('sequence', 0), status='error' if code else 'ok', error=code)


def test_failover_preserves_write_identity(monkeypatch):
    requests = []
    def exchange(self, endpoint, request, deadline):
        requests.append(dict(request))
        if len(requests) == 1:
            raise sqlodin.ConnectionError('lost response after commit')
        return reply(request)
    with make_db(monkeypatch, exchange) as db:
        assert db.execute('UPDATE account SET n=n+?', (1,)).sequence == 1
        assert db.pending is None
    assert requests[0]['session'] == requests[1]['session']
    assert requests[0]['sequence'] == requests[1]['sequence'] == 1
    assert requests[0]['parameters'] == requests[1]['parameters']


def test_unknown_outcome_blocks_new_write_and_roundtrips(monkeypatch):
    def exchange(*args):
        raise sqlodin.ConnectionError('unavailable')
    with make_db(monkeypatch, exchange) as db:
        with pytest.raises(sqlodin.UnknownOutcome) as exc:
            db.execute('UPDATE account SET n=n+?', (1,))
        assert sqlodin.PendingWrite.from_json(exc.value.pending.to_json()) == db.pending
        with pytest.raises(sqlodin.PendingWriteError):
            db.execute('DELETE FROM account')
        monkeypatch.setattr(Transport, 'exchange', lambda self, endpoint, request, deadline: reply(request))
        assert db.resolve_pending().sequence == 1
        assert db.execute('DELETE FROM account').sequence == 2


def test_constraint_consumes_sequence_and_batches_keep_distinct_bindings(monkeypatch):
    requests = []
    def exchange(self, endpoint, request, deadline):
        requests.append(dict(request))
        return reply(request, 'Constraint' if len(requests) == 1 else '')
    with make_db(monkeypatch, exchange) as db:
        with pytest.raises(sqlodin.ConstraintError):
            db.execute('INSERT INTO x VALUES(?)', (1,))
        with db.transaction() as tx:
            tx.execute('UPDATE x SET n=? -- end', (2,))
            tx.execute('UPDATE y SET n=?', (3,))
        assert tx.result.sequence == 2
    assert requests[1]['sql'] == 'UPDATE x SET n=?1 -- end\n\n;\nUPDATE y SET n=?2\n'
    assert requests[1]['parameters'] == [{'kind': 'integer', 'integer': 2}, {'kind': 'integer', 'integer': 3}]


def test_exception_discards_unsent_batch(monkeypatch):
    requests = []
    def exchange(self, endpoint, request, deadline):
        requests.append(request)
        return reply(request)
    with make_db(monkeypatch, exchange) as db:
        with pytest.raises(RuntimeError):
            with db.transaction() as tx:
                tx.execute('DELETE FROM x')
                raise RuntimeError('abort')
        assert db.pending is None and requests == []


def test_malformed_write_reply_remains_pending(monkeypatch):
    def exchange(self, endpoint, request, deadline):
        result = reply(request)
        result['sequence'] += 1
        return result
    with make_db(monkeypatch, exchange) as db:
        with pytest.raises(sqlodin.UnknownOutcome):
            db.execute('DELETE FROM x')
        assert db.pending.sequence == 1


def test_epoch_discovery_is_once_and_expired_pending_is_never_relabelled(monkeypatch):
    requests = []
    def exchange(self, endpoint, request, deadline):
        requests.append(dict(request))
        if request['op'] == 'session_epoch':
            return dict(reply(request), session_epoch=7)
        return reply(request, 'Expired')
    with make_db(monkeypatch, exchange, epoch=None) as db:
        with pytest.raises(sqlodin.SessionError, match='Expired'):
            db.execute('UPDATE x SET n=n+1')
        pending = db.pending
        assert pending.epoch == 7
        assert sqlodin.PendingWrite.from_json(pending.to_json()) == pending
        with pytest.raises(sqlodin.SessionError, match='Expired'):
            db.resolve_pending()
        assert db.pending == pending
    assert [r['op'] for r in requests] == ['session_epoch', 'execute', 'execute']
    assert requests[1]['session_epoch'] == requests[2]['session_epoch'] == 7
    legacy = json.loads(pending.to_json())
    legacy.pop('epoch')
    assert sqlodin.PendingWrite.from_json(json.dumps(legacy)).epoch == 0


def test_failed_epoch_discovery_never_creates_or_submits_pending_write(monkeypatch):
    requests = []
    def exchange(self, endpoint, request, deadline):
        requests.append(request['op'])
        raise sqlodin.ConnectionError('No quorum')
    with make_db(monkeypatch, exchange, epoch=None) as db:
        with pytest.raises(sqlodin.ConnectionError):
            db.execute('DELETE FROM x')
        assert db.pending is None
    assert requests and set(requests) == {'session_epoch'}


def test_retirement_keeps_explicit_expected_epoch(monkeypatch):
    requests = []
    def exchange(self, endpoint, request, deadline):
        requests.append(dict(request))
        return dict(reply(request), session_epoch=4)
    with make_db(monkeypatch, exchange) as db:
        assert db.retire_sessions(expected_epoch=3) == 4
        assert db.retire_sessions(expected_epoch=3) == 4
    assert [(r['op'], r['session_epoch']) for r in requests] == [('retire_sessions', 3)]*2
