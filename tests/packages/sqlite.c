#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { \
  fprintf(stderr, "SQLite check failed at line %d: %s\n", __LINE__, #expr); \
  exit(1); \
} } while (0)

static void exec(sqlite3 *db, const char *sql) {
  char *error = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &error);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "%s: %s\n", sql, error);
    sqlite3_free(error);
    exit(1);
  }
}

static void expect(sqlite3 *db, const char *sql, const char *value) {
  sqlite3_stmt *stmt;
  CHECK(sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK);
  CHECK(sqlite3_step(stmt) == SQLITE_ROW);
  CHECK(sqlite3_stricmp((const char *)sqlite3_column_text(stmt, 0), value) == 0);
  CHECK(sqlite3_step(stmt) == SQLITE_DONE);
  CHECK(sqlite3_finalize(stmt) == SQLITE_OK);
}

int main(void) {
  sqlite3 *writer, *reader;
  CHECK(sqlite3_open("test.db", &writer) == SQLITE_OK);
  expect(writer, "PRAGMA journal_mode=WAL", "wal");
  exec(writer, "CREATE TABLE items(value INTEGER);"
               "INSERT INTO items VALUES(9223372036854775807);");
  CHECK(sqlite3_open("test.db", &reader) == SQLITE_OK);
  exec(writer, "BEGIN IMMEDIATE; INSERT INTO items VALUES(42);");
  expect(reader, "SELECT count(*) FROM items", "1");
  CHECK(sqlite3_exec(reader, "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_BUSY);
  exec(writer, "ROLLBACK");
  exec(reader, "BEGIN IMMEDIATE; INSERT INTO items VALUES(7); COMMIT;");
  CHECK(sqlite3_close(reader) == SQLITE_OK);
  CHECK(sqlite3_close(writer) == SQLITE_OK);

  CHECK(sqlite3_open("test.db", &reader) == SQLITE_OK);
  expect(reader, "SELECT count(*) FROM items", "2");
  expect(reader, "SELECT max(value) FROM items", "9223372036854775807");
  expect(reader, "SELECT json_extract('{\"answer\":42}', '$.answer')", "42");
  exec(reader, "CREATE VIRTUAL TABLE words USING fts5(content);"
               "INSERT INTO words VALUES('native OpenBSD packages');");
  expect(reader, "SELECT count(*) FROM words WHERE words MATCH 'OpenBSD'", "1");
  expect(reader, "PRAGMA integrity_check", "ok");
  CHECK(sqlite3_close(reader) == SQLITE_OK);
  puts("PASS SQLite: WAL, concurrent connections, rollback, persistence, JSON and FTS5");
  return 0;
}
