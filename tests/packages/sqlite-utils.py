"""Exercise the installed CLI as a regular user, including database persistence."""
import csv
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(['sqlite-utils', *map(str, args)], text=True)


def main():
    assert os.geteuid() != 0
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        db = work / 'records.db'
        rows = [
            {'id': 1, 'name': 'café, "hello"', 'count': 7},
            {'id': 2, 'name': 'OpenBSD', 'count': None},
        ]
        source = work / 'records.json'
        source.write_text(json.dumps(rows))
        run('insert', db, 'records', source, '--pk', 'id')
        assert json.loads(run('query', db, 'select * from records order by id')) == rows

        # Read the CLI's CSV export and import it into a second table.
        exported = run('query', db, 'select id, name from records order by id', '--csv')
        expected_csv = [{'id': str(row['id']), 'name': row['name']} for row in rows]
        assert list(csv.DictReader(io.StringIO(exported))) == expected_csv
        source = work / 'records.csv'
        source.write_text(exported)
        run('insert', db, 'imported', source, '--csv')
        imported = json.loads(run('query', db, 'select * from imported order by id'))
        # CSV imports infer integer columns by default.
        assert imported == [{'id': row['id'], 'name': row['name']} for row in rows], imported

        # Each CLI invocation reopens the database. Verify its contents independently.
        with sqlite3.connect(db) as connection:
            assert connection.execute('pragma integrity_check').fetchone() == ('ok',)
            assert connection.execute('select count(*) from records').fetchone() == (2,)
            connection.execute("update records set count = 9 where id = 1")
        assert json.loads(run('query', db, 'select count from records where id = 1')) == [{'count': 9}]
    print('SQLITE_UTILS_PASS')


if __name__ == '__main__':
    main()
