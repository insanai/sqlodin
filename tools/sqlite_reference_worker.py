#!/usr/bin/env python3
"""Isolated pinned SQLite reference process, allowing exact forwarded syscall counts."""
import json
import os
from pathlib import Path
import resource
import sys

from calibrate_native_mixed import SQLite, library, measure
from sqlite_group_reference import GroupReference


def usage():
    r = resource.getrusage(resource.RUSAGE_SELF)
    io = dict(line.split(': ') for line in Path('/proc/self/io').read_text().splitlines())
    return dict(cpu_seconds=r.ru_utime+r.ru_stime, peak_rss_bytes=r.ru_maxrss*1024,
                io={k:int(v) for k,v in io.items()})


def main():
    job = json.loads(Path(sys.argv[1]).read_text())
    reference = SQLite(library(Path(job['library'])), Path(job['database']))
    result = dict(complete=False)
    try:
        for text in job['setup']:
            reference.run(text, True)
        result['before'] = usage()
        if job['group']:
            grouping = GroupReference(reference, job['group'])
            try:
                result['measurement'] = measure(lambda _:grouping.connect(), job['case'], job['count'])
            finally:
                grouping.close()
                result['groups'] = grouping.groups
        else:
            lib = reference.lib
            result['measurement'] = measure(lambda _:SQLite(lib, Path(job['database'])),
                                            job['case'], job['count'])
        result['after'] = usage()
        measured = result['measurement']
        assert not measured['errors'] and measured['completed'] == job['count']*job['case']['clients']
        increments = max(job['case']['rows'], job['case']['statements'])
        assert reference.scalar('SELECT sum(balance) FROM account') == increments*sum(
            x['write'] for x in measured['raw'])
        result['complete'] = True
    except BaseException as exc:
        result['error'] = repr(exc)
        raise
    finally:
        reference.close()
        Path(job['output']).write_text(json.dumps(result)+'\n')


if __name__ == '__main__':
    main()
